#!/usr/bin/env bash
# Verifies every model in Config/Models.json against the live Workers AI catalogue and runs a
# one-line completion on each. Needs CF_ACCOUNT_ID and CF_API_TOKEN (Workers AI Read + Edit).
# Never prints the token.
set -euo pipefail
: "${CF_ACCOUNT_ID:?set CF_ACCOUNT_ID}"; : "${CF_API_TOKEN:?set CF_API_TOKEN}"
api="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/ai"
fail=0
for id in $(python3 -c 'import json;[print(m["id"]) for m in json.load(open("Config/Models.json"))["models"]]'); do
  name=${id##*/}
  listed=$(curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" "$api/models/search?search=$name" \
    | python3 -c "import json,sys;print(any(m.get('name')=='$id' for m in json.load(sys.stdin).get('result',[])))")
  if [ "$listed" != "True" ]; then echo "MISSING  $id"; fail=1; continue; fi
  code=$(curl -sS -o /tmp/kage-model.json -w '%{http_code}' -H "Authorization: Bearer $CF_API_TOKEN" \
    -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":16}' "$api/run/$id")
  if [ "$code" = "200" ]; then echo "OK       $id"; else echo "HTTP $code $id"; fail=1; fi
done
exit $fail
