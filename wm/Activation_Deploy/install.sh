#!/usr/bin/env bash
# Installs the activation demo on an EC2 instance (Amazon Linux 2023 or Ubuntu 22.04/24.04), as root:
# a system user, the package under /opt/cg-activation/app, a Python venv with pinned dependencies, the DuckDB build
# of the slice, a systemd service bound to localhost, and nginx in front of it with HTTP basic authentication.
#
#   sudo install.sh --package <cg-activation-*.tar.gz | s3://bucket/key> \
#        [--key-parameter /cg-activation/anthropic-api-key]   # SSM SecureString holding the Claude API key (preferred)
#        [--key-file <path>]                                   # or a file whose first line is the key (deleted after use)
#        [--auth-user demo --auth-password '<password>']       # nginx basic auth (required unless --no-auth)
#        [--no-auth]                                           # only behind a security group you trust
#        [--server-name demo.example.com]                      # nginx server_name; default: any
#        [--model claude-opus-5-5] [--effort high]             # the Claude model and effort for the assistant
#        [--precompute]                                        # cache the mapping proposals with Claude after the build
#
# Idempotent: re-running with a new package replaces the app and rebuilds; the service, nginx and the key are kept.
set -euo pipefail

PACKAGE="" KEY_PARAM="" KEY_FILE="" AUTH_USER="" AUTH_PASS="" NO_AUTH=0 SERVER_NAME="_" MODEL="claude-opus-5-5" EFFORT="high" PRECOMPUTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --package) PACKAGE=$2; shift 2 ;;
    --key-parameter) KEY_PARAM=$2; shift 2 ;;
    --key-file) KEY_FILE=$2; shift 2 ;;
    --auth-user) AUTH_USER=$2; shift 2 ;;
    --auth-password) AUTH_PASS=$2; shift 2 ;;
    --no-auth) NO_AUTH=1; shift ;;
    --server-name) SERVER_NAME=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --effort) EFFORT=$2; shift 2 ;;
    --precompute) PRECOMPUTE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PACKAGE" ] || { echo "--package is required" >&2; exit 2; }
if [ "$NO_AUTH" != 1 ] && [ ! -f /etc/nginx/cg-activation.htpasswd ] && { [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; }; then
  echo "--auth-user and --auth-password are required the first time (or --no-auth)" >&2; exit 2
fi
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }

APP_ROOT=/opt/cg-activation
APP=$APP_ROOT/app
VENV=$APP_ROOT/venv
SVC=cg-activation
log() { echo "== $*"; }

# ---------------------------------------------------------------------------------------------------- 1. system packages
if [ -f /etc/os-release ]; then . /etc/os-release; fi
if command -v dnf >/dev/null; then
  log "packages (dnf)"
  dnf install -y -q nginx tar gzip openssl
  PY=""
  for c in python3.12 python3.11 python3.10; do
    if dnf install -y -q "$c" >/dev/null 2>&1 && command -v "$c" >/dev/null; then
      dnf install -y -q "$c-pip" >/dev/null 2>&1 || true
      PY=$(command -v "$c"); break
    fi
  done
  command -v aws >/dev/null || dnf install -y -q awscli-2 || dnf install -y -q awscli   # Amazon Linux 2023 ships the CLI
elif command -v apt-get >/dev/null; then
  log "packages (apt)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q nginx tar gzip python3 python3-venv python3-pip curl unzip openssl
  PY=$(command -v python3)
  if ! command -v aws >/dev/null; then
    curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip && unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install >/dev/null && rm -rf /tmp/aws /tmp/awscli.zip
  fi
else
  echo "unsupported distribution" >&2; exit 1
fi
[ -n "${PY:-}" ] || { echo "no Python 3.10+ interpreter found" >&2; exit 1; }
"$PY" -c 'import sys; assert sys.version_info >= (3, 10), sys.version' || { echo "Python 3.10+ is required; found $("$PY" --version)" >&2; exit 1; }
log "python: $("$PY" --version) at $PY"

# ---------------------------------------------------------------------------------------------------- 2. user and layout
id -u $SVC >/dev/null 2>&1 || useradd --system --home-dir $APP_ROOT --shell /sbin/nologin $SVC
mkdir -p $APP_ROOT /etc/cg-activation

# ---------------------------------------------------------------------------------------------------- 3. the package
log "package: $PACKAGE"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
case "$PACKAGE" in
  s3://*) aws s3 cp "$PACKAGE" "$TMP/pkg.tar.gz" ;;
  http://*|https://*) curl -sSL "$PACKAGE" -o "$TMP/pkg.tar.gz" ;;
  *) cp "$PACKAGE" "$TMP/pkg.tar.gz" ;;
esac
mkdir -p "$TMP/x" && tar -xzf "$TMP/pkg.tar.gz" -C "$TMP/x"
NEW=$(find "$TMP/x" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -f "$NEW/_tools/activation/compile/build_all.py" ] || { echo "not an activation package: $PACKAGE" >&2; exit 1; }
systemctl stop $SVC 2>/dev/null || true
if [ -d "$APP" ]; then
  # keep the proposal cache across releases; everything else under out/ is rebuilt
  [ -d "$APP/_tools/activation/out/proposals" ] && cp -r "$APP/_tools/activation/out/proposals" "$TMP/proposals" || true
  rm -rf "$APP.prev"; mv "$APP" "$APP.prev"
fi
mv "$NEW" "$APP"
[ -d "$TMP/proposals" ] && mkdir -p "$APP/_tools/activation/out" && mv "$TMP/proposals" "$APP/_tools/activation/out/proposals" || true
cat "$APP/VERSION"

# ---------------------------------------------------------------------------------------------------- 4. the venv
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null; then
  log "venv"
  rm -rf "$VENV"; "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$APP/_tools/activation/deploy/requirements.txt"
log "installed: $("$VENV/bin/pip" freeze | grep -i -E '^(duckdb|anthropic|mcp|PyYAML|openpyxl)=' | tr '\n' ' ')"

# ---------------------------------------------------------------------------------------------------- 5. the key
install -m 755 "$APP/_tools/activation/deploy/start.sh" $APP_ROOT/start.sh
if [ -n "$KEY_FILE" ]; then
  log "api key from file (stored root-only in /etc/cg-activation/secret.env)"
  umask 077; printf 'ANTHROPIC_API_KEY=%s\n' "$(head -1 "$KEY_FILE" | tr -d '[:space:]')" > /etc/cg-activation/secret.env; umask 022
  chown root:$SVC /etc/cg-activation/secret.env; chmod 640 /etc/cg-activation/secret.env
  shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
fi
if [ ! -f /etc/cg-activation/env ] || [ -n "$KEY_PARAM" ] || [ "$MODEL" != "claude-opus-5-5" ] || [ "$EFFORT" != "high" ]; then
  log "environment"
  OLD_PARAM=$(grep -s '^ANTHROPIC_API_KEY_PARAMETER=' /etc/cg-activation/env | cut -d= -f2- || true)
  cat > /etc/cg-activation/env <<EOF
# The activation demo's service environment (read by systemd; the key itself never sits in this file).
ACTIVATION_RUNTIME=duckdb
ACTIVATION_LLM=anthropic
ACTIVATION_ANTHROPIC_MODEL=$MODEL
ACTIVATION_ANTHROPIC_EFFORT=$EFFORT
# the question router plans with Sonnet by default; ACTIVATION_ROUTER_MODEL overrides it
ACTIVATION_LLM_TIMEOUT=240
# SSM Parameter Store SecureString with the Claude API key; start.sh fetches it at every start through the instance role.
ANTHROPIC_API_KEY_PARAMETER=${KEY_PARAM:-$OLD_PARAM}
PYTHONUNBUFFERED=1
EOF
  chmod 644 /etc/cg-activation/env
fi
[ -f /etc/cg-activation/secret.env ] || [ -n "$(grep -s '^ANTHROPIC_API_KEY_PARAMETER=.\+' /etc/cg-activation/env)" ] \
  || echo "warning: no Claude key configured (--key-parameter or --key-file); the assistant will run its deterministic paths" >&2

# ---------------------------------------------------------------------------------------------------- 6. the build
log "build (DuckDB): sources, slice, mappings, physical, derivations, proof, semantic, tests, states"
chown -R $SVC:$SVC "$APP"
cd "$APP/_tools"
sudo -u $SVC ACTIVATION_RUNTIME=duckdb "$VENV/bin/python" activation/compile/build_all.py 2>&1 | tail -n 12
test -f activation/out/activation.json || { echo "build did not write activation.json" >&2; exit 1; }
sudo -u $SVC "$VENV/bin/python" - <<'EOF'
import json; a = json.load(open("activation/out/activation.json"))["summary"]; t = json.load(open("activation/out/test_results.json"))
print(f"states: metrics {a['metrics']}, questions {a['questions']}; tests {a['tests']} ({a['test_failures']} with failing rows); expectations met: {t['expectations_met']}")
EOF

# ---------------------------------------------------------------------------------------------------- 7. the service
log "service"
sed "s#@APP_ROOT@#$APP_ROOT#g" "$APP/_tools/activation/deploy/cg-activation.service" > /etc/systemd/system/$SVC.service
systemctl daemon-reload
systemctl enable -q $SVC
systemctl restart $SVC
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8765/api/state >/dev/null 2>&1; then break; fi; sleep 1
done
curl -fsS http://127.0.0.1:8765/api/state >/dev/null || { journalctl -u $SVC -n 40 --no-pager; echo "the service did not answer on 8765" >&2; exit 1; }
MODEL_LABEL=$(curl -fsS http://127.0.0.1:8765/api/state | "$VENV/bin/python" -c 'import json,sys; print((json.load(sys.stdin).get("assistant") or {}).get("label", ""))' 2>/dev/null || true)
log "service up; assistant: ${MODEL_LABEL:-see /api/state}"

# ---------------------------------------------------------------------------------------------------- 8. nginx
log "nginx"
if [ "$NO_AUTH" = 1 ]; then
  rm -f /etc/nginx/cg-activation.htpasswd
  AUTH_LINES="        auth_basic off;"
else
  if [ -n "$AUTH_USER" ]; then
    HASH=$(openssl passwd -apr1 "$AUTH_PASS")
    printf '%s:%s\n' "$AUTH_USER" "$HASH" > /etc/nginx/cg-activation.htpasswd
    chmod 640 /etc/nginx/cg-activation.htpasswd
    chown root:"$(id -gn nginx 2>/dev/null || id -gn www-data)" /etc/nginx/cg-activation.htpasswd
  fi
  AUTH_LINES=$(printf '        auth_basic "Activation demo";\n        auth_basic_user_file /etc/nginx/cg-activation.htpasswd;')
fi
CONF=$(sed -e "s#@SERVER_NAME@#$SERVER_NAME#g" "$APP/_tools/activation/deploy/nginx-cg-activation.conf")
CONF=${CONF//@AUTH@/$AUTH_LINES}
if [ -d /etc/nginx/conf.d ]; then
  printf '%s\n' "$CONF" > /etc/nginx/conf.d/cg-activation.conf
  # Amazon Linux's default server block also listens on 80; keep ours first by disabling its default site.
  [ -f /etc/nginx/nginx.conf ] && grep -q 'listen       80;' /etc/nginx/nginx.conf && sed -i 's/listen       80;/listen       8080;/; s/listen       \[::\]:80;/listen       [::]:8080;/' /etc/nginx/nginx.conf || true
fi
if [ -d /etc/nginx/sites-enabled ]; then
  printf '%s\n' "$CONF" > /etc/nginx/sites-available/cg-activation
  ln -sf /etc/nginx/sites-available/cg-activation /etc/nginx/sites-enabled/cg-activation
  rm -f /etc/nginx/sites-enabled/default
fi
nginx -t
systemctl enable -q nginx; systemctl restart nginx

# ---------------------------------------------------------------------------------------------------- 9. proposals cache
if [ "$PRECOMPUTE" = 1 ]; then
  log "precompute the mapping proposals with Claude (eight sources; a few minutes and a few hundred thousand tokens)"
  sudo -u $SVC "$APP_ROOT/start.sh" --precompute claude 2>&1 | tail -n 10 || echo "precompute failed; the page will propose live" >&2
  systemctl restart $SVC
fi

log "done: $(cat "$APP/VERSION" | head -1); open http://$(curl -s -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')/"
