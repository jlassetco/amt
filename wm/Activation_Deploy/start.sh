#!/usr/bin/env bash
# Starts the activation web app for systemd. Fetches the Claude API key from SSM Parameter Store at every start when
# ANTHROPIC_API_KEY_PARAMETER is set (through the instance role, never written to disk); otherwise uses an
# ANTHROPIC_API_KEY already in the environment (/etc/cg-activation/secret.env). Then execs the server on localhost.
#
#   start.sh                       serve on 127.0.0.1:8765 (nginx fronts it)
#   start.sh --precompute claude   cache the mapping proposals with Claude, then exit
set -euo pipefail
APP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$APP_ROOT/app
PY=$APP_ROOT/venv/bin/python
[ -f /etc/cg-activation/env ] && set -a && . /etc/cg-activation/env && set +a
[ -f /etc/cg-activation/secret.env ] && [ -r /etc/cg-activation/secret.env ] && set -a && . /etc/cg-activation/secret.env && set +a

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -n "${ANTHROPIC_API_KEY_PARAMETER:-}" ]; then
  REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
  if [ -z "$REGION" ]; then
    TOKEN=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
    REGION=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region || true)
  fi
  if KEY=$(aws ssm get-parameter --name "$ANTHROPIC_API_KEY_PARAMETER" --with-decryption --query Parameter.Value --output text ${REGION:+--region "$REGION"} 2>&1); then
    export ANTHROPIC_API_KEY=$KEY
    echo "claude key: read from SSM parameter $ANTHROPIC_API_KEY_PARAMETER"
  else
    echo "warning: could not read $ANTHROPIC_API_KEY_PARAMETER from SSM ($KEY); the assistant will run its deterministic paths" >&2
  fi
fi
unset ANTHROPIC_API_KEY_PARAMETER

cd "$APP/_tools"
export ACTIVATION_RUNTIME=${ACTIVATION_RUNTIME:-duckdb}
export ACTIVATION_LLM=${ACTIVATION_LLM:-anthropic}
if [ "${1:-}" = "--precompute" ]; then
  exec "$PY" activation/app/server.py --runtime "$ACTIVATION_RUNTIME" --precompute "${2:-claude}"
fi
exec "$PY" activation/app/server.py --runtime "$ACTIVATION_RUNTIME" --host "${ACTIVATION_HOST:-127.0.0.1}" --port "${ACTIVATION_PORT:-8765}"
