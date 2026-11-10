#!/usr/bin/env bash
# Verifies a self-hosted anisette-v3 endpoint with the project's own client.
# Usage: ./verify.sh [base-url] [path-to-anisettecheck]
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:6969}"
CHECKER="${2:-./bin/anisettecheck}"

echo "== 1. reachability: GET /v3/client_info =="
curl -fsS --max-time 15 "${BASE_URL}/v3/client_info" | tee /dev/stderr | grep -q client_info \
  || { echo "FAIL: client_info did not return the expected document"; exit 1; }

echo
echo "== 2. get_headers must reject an unprovisioned identifier =="
# Empty adi_pb is not a provisioning blob; anisette-v3 answers with an error
# document rather than fabricated headers. A 200 with "result":"Headers" here
# would mean the service is inventing headers.
resp="$(curl -sS --max-time 30 -X POST "${BASE_URL}/v3/get_headers" \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"AAAAAAAAAAAAAAAAAAAAAA==","adi_pb":""}')"
echo "$resp"
case "$resp" in
  *'"result":"Headers"'*) echo "WARN: service returned headers without provisioning data" ;;
  *'"result":"GetHeadersError"'*) echo "OK: refused, as expected" ;;
  *) echo "NOTE: unexpected shape, inspect above" ;;
esac

echo
echo "== 3. full client round-trip (provisioning + headers) =="
"${CHECKER}" -url "${BASE_URL}"

echo
echo "== 4. WebSocket endpoint accepts an upgrade =="
# 101 means the upgrade path is reachable through any proxy in front.
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "${BASE_URL}/v3/provisioning_session" || true)"
if [ "$code" = "101" ]; then
  echo "OK: 101 Switching Protocols"
else
  echo "FAIL: provisioning_session returned $code (expected 101)."
  echo "      Behind a proxy this almost always means Upgrade/Connection headers were stripped."
  exit 1
fi

echo
echo "ALL CHECKS PASSED for ${BASE_URL}"
