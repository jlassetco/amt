#!/usr/bin/env bash
# Builds the deployment package of the activation demo: a tarball of the repo's tracked files that the demo needs
# (the tooling and the taxonomy content; not the program deliverables, not the git history, not any generated output),
# plus a VERSION file. Optionally uploads it to S3 for the CloudFormation stack's user data to fetch.
#
#   _tools/activation/deploy/make_package.sh [--out <dir>] [--s3 s3://bucket/prefix/]
#
# The package unpacks to one folder, cg-activation-<sha>/, with _tools/ and the Data Domain folders at its root, so the
# activation modules import the taxonomy, product and semantic layers exactly as they do in the repo.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OUT_DIR=$REPO/_tools/activation/out/package
S3=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR=$2; shift 2 ;;
    --s3) S3=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO"
SHA=$(git rev-parse --short HEAD)
DIRTY=$(git status --porcelain -- _tools ':(exclude)_tools/activation/out' | grep -v '^??' | head -1 || true)
NAME=cg-activation-$SHA
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME" "$OUT_DIR"

# Tracked files only, minus the program deliverables (decks, workbooks, explorer) that the demo never reads.
git ls-files -z -- . ':(exclude)00_Program' ':(exclude).github' ':(exclude)*.pptx' ':(exclude)*.xlsx' ':(exclude)*.docx' \
  | tar --null -T - -cf - | tar -xf - -C "$STAGE/$NAME"
# The deploy folder itself travels in the package (install.sh, the unit, nginx, start.sh).
mkdir -p "$STAGE/$NAME/_tools/activation/deploy"
cp "$REPO"/_tools/activation/deploy/* "$STAGE/$NAME/_tools/activation/deploy/"
{
  echo "package=$NAME"
  echo "commit=$(git rev-parse HEAD)"
  echo "branch=$(git rev-parse --abbrev-ref HEAD)"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "dirty=$([ -n "$DIRTY" ] && echo yes || echo no)"
} > "$STAGE/$NAME/VERSION"

TAR=$OUT_DIR/$NAME.tar.gz
tar -czf "$TAR" -C "$STAGE" "$NAME"
SIZE=$(du -h "$TAR" | cut -f1)
echo "wrote $TAR ($SIZE, $(tar -tzf "$TAR" | wc -l | tr -d ' ') files)"
[ -n "$DIRTY" ] && echo "note: the working tree has uncommitted changes under _tools; the package carries them (VERSION says dirty=yes)" >&2

if [ -n "$S3" ]; then
  aws s3 cp "$TAR" "${S3%/}/$NAME.tar.gz"
  echo "uploaded to ${S3%/}/$NAME.tar.gz"
fi
