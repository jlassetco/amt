# Deploying the activation demo to EC2

The end state of the demo: one EC2 instance serving the activation web app (Sources, Map, Build, Products, Ask) on
the DuckDB runtime, with Claude through the Anthropic API behind the mapping assistant and the question router. The
API key lives in SSM Parameter Store and is read by the instance role at service start; it is never in the package,
the template, the environment file or the logs. nginx fronts the app with HTTP basic authentication.

| File | What |
|---|---|
| `make_package.sh` | Builds `cg-activation-<sha>.tar.gz` from the repo's tracked files (the tooling and the Data Domain content; no deliverables, no git history, no generated output) and optionally uploads it to S3 |
| `cloudformation.yaml` | One stack: instance role (read the key parameter, read the package), security group, instance with user data that runs `install.sh`; signals CloudFormation when the service answers |
| `install.sh` | On the instance, as root: Python 3.10+ venv with `requirements.txt`, the package under `/opt/cg-activation/app`, the DuckDB build (about a minute), the systemd service, nginx with basic auth; optional Claude precompute of the proposals. Idempotent; re-run with a new package to upgrade |
| `start.sh` | The service's entry point: fetches the key from SSM into the process environment, execs `app/server.py` on `127.0.0.1:8765` |
| `cg-activation.service` | The systemd unit (system user, read-only app tree except `out/`) |
| `nginx-cg-activation.conf` | The site: basic auth, 300 s proxy timeouts for the assistant's calls, `/healthz` without auth |
| `smoke.sh` | State, metrics, a certified query and a demo question against a deployment |
| `requirements.txt` | Pinned: duckdb, PyYAML, anthropic, mcp, openpyxl |

## Deploy

```bash
# 1. The key, once, in the target account and region (SecureString; the default parameter name is below)
aws ssm put-parameter --name /cg-activation/anthropic-api-key --type SecureString --value "$ANTHROPIC_API_KEY"

# 2. The package, to a bucket the account owns
_tools/activation/deploy/make_package.sh --s3 s3://my-bucket/cg-activation/
#    -> wrote _tools/activation/out/package/cg-activation-<sha>.tar.gz; uploaded

# 3. The stack (a public subnet; the password is the basic-auth password, 12+ characters)
aws cloudformation deploy --stack-name cg-activation-demo --capabilities CAPABILITY_IAM \
  --template-file _tools/activation/deploy/cloudformation.yaml \
  --parameter-overrides PackageS3Uri=s3://my-bucket/cg-activation/cg-activation-<sha>.tar.gz \
      VpcId=vpc-... SubnetId=subnet-... AllowedCidr=203.0.113.0/24 AuthUser=demo AuthPassword='...'
aws cloudformation describe-stacks --stack-name cg-activation-demo --query 'Stacks[0].Outputs'

# 4. Check it
_tools/activation/deploy/smoke.sh http://<public dns>/ demo:'...'
```

The stack takes 10 to 20 minutes: packages and the venv, the build (about a minute on a t3.large), and the proposal
precompute with Claude (eight sources; `PrecomputeProposals=false` skips it and the page proposes live, 30 to 90
seconds per source). The user data log is `/var/log/cg-activation-install.log`; the service log is
`journalctl -u cg-activation`. Shell access is Session Manager (`aws ssm start-session --target <instance id>`), so
no key pair or port 22 is needed.

## Without CloudFormation

Any EC2 instance (Amazon Linux 2023 or Ubuntu 22.04/24.04) with an instance role that may `ssm:GetParameter` the key
and `s3:GetObject` the package:

```bash
sudo bash install.sh --package s3://my-bucket/cg-activation/cg-activation-<sha>.tar.gz \
  --key-parameter /cg-activation/anthropic-api-key --auth-user demo --auth-password '...' --precompute
```

Without SSM, `--key-file /root/key.txt` stores the key root-only in `/etc/cg-activation/secret.env` (mode 640, group
`cg-activation`) and deletes the file. Without a key at all the app runs: the demo questions keep their verified plans,
and the mapping assistant falls back to the deterministic baseline, which the page says.

## Upgrade, model, TLS

- **New release:** `make_package.sh --s3 ...`, then on the instance `install.sh --package s3://.../cg-activation-<newsha>.tar.gz`
  (the key, the basic-auth file and the proposal cache are kept; the app tree is replaced and rebuilt). Or update the
  stack's `PackageS3Uri`; the instance is replaced only if the template changes it to.
- **Model:** `ACTIVATION_ANTHROPIC_MODEL` and `ACTIVATION_ANTHROPIC_EFFORT` in `/etc/cg-activation/env`
  (`install.sh --model claude-sonnet-5-5` sets it), then `systemctl restart cg-activation`. The proposal cache is keyed
  by model, so a model change re-proposes live until `start.sh --precompute claude` is run again as the service user.
- **TLS:** point a DNS name at the instance and run `certbot --nginx -d demo.example.com` (install `certbot
  python3-certbot-nginx`), or terminate TLS on an ALB in front of port 80. Basic auth over plain HTTP sends the
  password in clear; use TLS or a tight `AllowedCidr` for anything beyond a rehearsal.
- **Spark instead of DuckDB:** the DuckDB runtime is the deployment default (no Java, a one-minute build). The Spark
  path needs a JDK and `pyspark==3.5.3 delta-spark==3.2.1` on Python 3.11 or 3.12; see `../README.md`.

## What the service may touch

The unit runs as the `cg-activation` system user with `ProtectSystem=strict`: the app tree is read-only except
`_tools/activation/out/` (the DuckDB file, the reports, the proposal cache). The key is in the service process's
environment only. Outbound traffic: the Anthropic API, SSM and S3 at start. Inbound: nginx on 80 (and 443 with TLS);
the app itself listens on localhost.
