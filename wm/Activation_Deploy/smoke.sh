#!/usr/bin/env bash
# Smoke test of a deployed activation demo: the app answers, the build states are present, a certified metric runs,
# the assistant is Claude, and a demo question answers. Run on the instance, or from anywhere with the URL and the
# basic-auth credentials.
#
#   smoke.sh [http://host/] [user:password]        default http://127.0.0.1:8765/ with no auth (on the instance)
set -euo pipefail
BASE=${1:-http://127.0.0.1:8765/}; BASE=${BASE%/}
AUTH=${2:-}
c() { curl -fsS -m 300 ${AUTH:+-u "$AUTH"} "$@"; }
PY=${PYTHON:-}; [ -n "$PY" ] || { [ -x /opt/cg-activation/venv/bin/python ] && PY=/opt/cg-activation/venv/bin/python || PY=python3; }
py() { "$PY" -c "$1"; }

echo "== state"
c "$BASE/api/state" | py 'import json,sys
d=json.load(sys.stdin); a=d.get("assistant") or {}; s=d.get("summary") or {}
print("runtime %s; as of %s; assistant: %s (available: %s)" % (d.get("runtime"), d.get("as_of"), a.get("label"), a.get("available")))
print("states: metrics %s; questions %s; tests %s (%s with failing rows); %s declined" % (s.get("metrics"), s.get("questions"), s.get("tests"), s.get("test_failures"), s.get("cannot_answer")))'

echo "== metrics"
c "$BASE/api/metrics" | py 'import json,sys
m=json.load(sys.stdin)["metrics"]; ins=[x for x in m if x.get("in_scope") and not x.get("ref")]
print("%d of %d in-scope metrics answer" % (sum(1 for x in ins if x.get("state")=="enabled"), len(ins)))'

echo "== query: Client Assets by channel (certified; the total must match the proof)"
c "$BASE/api/query" -H 'Content-Type: application/json' -d '{"metric":"Client Assets","by":["distribution_channel.channel_name"]}' | py 'import json,sys
d=json.load(sys.stdin); rows=d.get("rows") or []
vals=[(r[-1] if isinstance(r,list) else (r.get("Client Assets") if "Client Assets" in r else list(r.values())[-1])) for r in rows]
print("%d rows; total %s; lineage: %s" % (len(rows), format(sum(float(v or 0) for v in vals), ",.2f"), bool(d.get("lineage"))))'

echo "== ask: a demo question (verified plan; no model call)"
c "$BASE/api/ask" -H 'Content-Type: application/json' -d '{"question":"How many funded accounts does each channel have?"}' | py 'import json,sys
d=json.load(sys.stdin)
if d.get("error"): print("error:", d["error"])
else:
    rs=d.get("results") or []
    print("assistant: %s; router: %s; matched: %s; results: %s" % (d.get("assistant"), d.get("router"), (d.get("matched_question") or "")[:70], "; ".join("%s (%d rows)" % (r.get("metric"), len(r.get("rows") or [])) for r in rs)))'
echo "== done"
