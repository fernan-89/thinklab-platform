#!/usr/bin/env bash
# Live proof of Journey 12, fourth service (bash port of knowledge-base-smoke.ps1; knowledge-base ADR-030..033): the knowledge base
# through the platform gateway - an article linked to a real problem and found by problem, keyword and free text, the review (nobody
# publishes their own article), versions (a new one is a draft of the same key, publishing it retires the older), the two audiences,
# a race between two reviewers, and every mutation (the refused ones too) recorded on the ledger.
# Needs the stack up (docker-compose.yml starts it, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
knb="$gateway/it-knowledge-base/v1"
prb="$gateway/it-problem-management/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# api METHOD URL BODY HEADER... -> prints "<status>\n<body>", never exits on a non-2xx.
api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out; out=$(curl "${args[@]}" "$url")
  local code=${out##*$'\n'}; local content=${out%$'\n'*}
  printf '%s\n%s' "$code" "$content"
}
api_status() { head -1 <<<"$1"; }
api_body() { tail -n +2 <<<"$1"; }

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

tenant_id=$(uuid)
author="author-$(uuid)"; reviewer="reviewer-$(uuid)"; reviewer2="reviewer-$(uuid)"
user=$(uuid)
tenant="X-Tenant-Id: $tenant_id"

# as WHO METHOD URL [BODY] -> a call as that person; status / body of it
as_s() { api_status "$(api "$2" "$3" "${4:-}" "$tenant" "X-Executor: $1")"; }
as_b() { api_body "$(api "$2" "$3" "${4:-}" "$tenant" "X-Executor: $1")"; }
# rq METHOD URL [BODY] -> as a REQUESTER (response "<status>\n<body>")
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $user" 'X-Role: REQUESTER'; }
get_article() { as_b "$author" GET "$knb/$1/retrieve"; }
ids() { python3 -c "import json,sys; print(','.join(a['id'] for a in json.load(sys.stdin)))"; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
actions() { python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))"; }
# draft TITLE BODY VISIBILITY KEYWORDS_JSON [PROBLEMS_JSON] -> the response of initiate
draft() { api POST "$knb/initiate" "{\"title\":\"$1\",\"body\":\"$2\",\"category\":\"NETWORK\",\"keywords\":$4,\"visibility\":\"$3\",\"relatedProblemIds\":${5:-[]}}" "$tenant" "X-Executor: $author"; }
update_body() { echo "{\"title\":\"Switch drops packets\",\"body\":\"$1\",\"category\":\"NETWORK\",\"keywords\":[\"switch\",\"firmware\"],\"visibility\":\"PUBLIC\",\"relatedProblemIds\":[\"$problem_id\"]}"; }

# 1. An article that explains a real problem, and finding it.
problem=$(api POST "$prb/initiate" '{"title":"Switch drops packets","description":"Intermittent loss on floor 3","priority":"P2"}' "$tenant" "X-Executor: $author")
problem_id=$(api_body "$problem" | json "['id']")
check_equal 'a problem is opened on the problem service' 201 "$(api_status "$problem")"
drafted=$(draft 'Switch drops packets' 'Reboot the switch every Sunday' PUBLIC '["Switch"," Firmware "]' "[\"$problem_id\"]")
id=$(api_body "$drafted" | json "['id']")
key=$(api_body "$drafted" | json "['articleKey']")
check_equal 'an author drafts an article: 201, DRAFT, version 1, the key is its own id' "201/DRAFT/1/True" "$(api_status "$drafted")/$(api_body "$drafted" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['version'], d['articleKey']==d['id']))")"
check_equal 'keywords are normalised (trimmed, lower-cased) and the author is the caller' "firmware,switch/True" "$(api_body "$drafted" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (','.join(sorted(d['keywords'])), d['authorId']=='$author'))")"
check_equal 'a blank title is refused (400)' 400 "$(as_s "$author" POST "$knb/initiate" '{"title":"","body":"b","visibility":"PUBLIC"}')"
check_equal 'a missing visibility is refused (400)' 400 "$(as_s "$author" POST "$knb/initiate" '{"title":"t","body":"b"}')"
check_equal 'the tenant is mandatory on every route (400)' 400 "$(api_status "$(api GET "$knb/$id/retrieve" "" "X-Executor: $author")")"
check_equal 'what do we know about this problem is answered from the article side' "$id" "$(as_b "$author" GET "$knb/retrieve?problemId=$problem_id" | ids)"
check_equal 'the problem service is untouched by the link (still NEW)' NEW "$(as_b "$author" GET "$prb/$problem_id/retrieve" | json "['status']")"
check_equal 'a keyword finds it whatever its case' "$id" "$(as_b "$author" GET "$knb/retrieve?keyword=FIRMWARE" | ids)"
check_equal 'the text search finds it by a word of its body' "$id" "$(as_b "$author" GET "$knb/retrieve?q=Sunday" | ids)"
check_equal 'and by a word of its title' "$id" "$(as_b "$author" GET "$knb/retrieve?q=packets" | ids)"
check_equal 'a word that is nowhere finds nothing' 0 "$(as_b "$author" GET "$knb/retrieve?q=nonexistentterm" | count)"
check_equal 'another tenant finds nothing by the same word' 0 "$(api_body "$(api GET "$knb/retrieve?q=Sunday" "" "X-Tenant-Id: $(uuid)" "X-Executor: $author")" | count)"

# 2. The review.
check_equal 'update the draft' 204 "$(as_s "$author" PUT "$knb/$id/update" "$(update_body 'Reboot the switch every Sunday after the firmware leak')")"
check_equal 'submit for review' 204 "$(as_s "$author" PUT "$knb/$id/control/submit")"
check_equal 'an article in review takes no edit (409)' 409 "$(as_s "$author" PUT "$knb/$id/update" '{"title":"t","body":"b","visibility":"PUBLIC"}')"
self=$(api PUT "$knb/$id/control/publish" "" "$tenant" "X-Executor: $author")
check_equal 'the author cannot publish their own article (409 ERR-KNB-00409)' '409/ERR-KNB-00409' "$(api_status "$self")/$(api_body "$self" | json "['error_code']")"
check_equal 'nor return it (409)' 409 "$(as_s "$author" PUT "$knb/$id/control/return" '{"comment":"fine"}')"
check_equal 'a return needs a comment (400)' 400 "$(as_s "$reviewer" PUT "$knb/$id/control/return" '{"comment":""}')"
check_equal 'the reviewer returns it with a comment' 204 "$(as_s "$reviewer" PUT "$knb/$id/control/return" '{"comment":"Say which firmware version leaks"}')"
check_equal 'it is a DRAFT again, with the comment and the reviewer' "DRAFT/Say which firmware version leaks/True" \
  "$(get_article "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['reviewComment'], d['reviewerId']=='$reviewer'))")"
check_equal 'the author fixes it' 204 "$(as_s "$author" PUT "$knb/$id/update" "$(update_body 'Firmware 2.1 leaks buffers: reboot the switch every Sunday')")"
check_equal 'submits again' 204 "$(as_s "$author" PUT "$knb/$id/control/submit")"
check_equal 'a different reviewer publishes it' 204 "$(as_s "$reviewer" PUT "$knb/$id/control/publish")"
check_equal 'PUBLISHED, with its date, the old comment cleared' 'PUBLISHED/True/True' "$(get_article "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], 'publishedAt' in d, 'reviewComment' not in d))")"

# 3. Versions.
v2=$(api POST "$knb/$id/version/initiate" "" "$tenant" "X-Executor: $reviewer")
v2_id=$(api_body "$v2" | json "['id']")
check_equal 'a new version is a new draft of the same key, authored by who asked' '201/2/DRAFT/True/True' \
  "$(api_status "$v2")/$(api_body "$v2" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s' % (d['version'], d['status'], d['articleKey']=='$key', d['authorId']=='$reviewer'))")"
check_equal 'the published version keeps serving meanwhile' PUBLISHED "$(get_article "$id" | json "['status']")"
check_equal 'a second new version of the same article at the same time is refused (409)' 409 "$(as_s "$author" POST "$knb/$id/version/initiate")"
check_equal 'a DRAFT has no new version (409)' 409 "$(as_s "$author" POST "$knb/$v2_id/version/initiate")"
check_equal 'the author of version 2 submits it' 204 "$(as_s "$reviewer" PUT "$knb/$v2_id/control/submit")"
check_equal 'the author of version 1 publishes version 2 (allowed: they did not write it)' 204 "$(as_s "$author" PUT "$knb/$v2_id/control/publish")"
check_equal 'version 1 is retired and version 2 serves, oldest first' '1,2/RETIRED,PUBLISHED' \
  "$(as_b "$author" GET "$knb/$id/versions/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (','.join(str(a['version']) for a in d), ','.join(a['status'] for a in d)))")"
check_equal 'version 1 trail tells the story, ending as SUPERSEDED' 'INITIATED,UPDATED,SUBMITTED,RETURNED,UPDATED,SUBMITTED,PUBLISHED,SUPERSEDED' "$(as_b "$author" GET "$knb/$id/audit-log/retrieve" | actions)"
check_equal 'a search finds only the serving version' "$v2_id" "$(as_b "$author" GET "$knb/retrieve?q=Sunday&status=PUBLISHED" | ids)"

# 4. The two audiences.
internal=$(draft 'Core router credentials rotation' 'Rotate through the vault, never by email' INTERNAL '["router"]')
internal_id=$(api_body "$internal" | json "['id']")
as_s "$author" PUT "$knb/$internal_id/control/submit" > /dev/null
check_equal 'an INTERNAL article is published' 204 "$(as_s "$reviewer" PUT "$knb/$internal_id/control/publish")"
seen=$(rq GET "$knb/$v2_id/retrieve")
check_equal 'a REQUESTER reads the published public article' '200/PUBLISHED' "$(api_status "$seen")/$(api_body "$seen" | json "['status']")"
check_equal 'without the people, the review comment and the links' 'True' "$(api_body "$seen" | python3 -c "import json,sys; d=json.load(sys.stdin); print(all(k not in d for k in ('authorId','reviewerId','reviewComment','relatedProblemIds','relatedIncidentIds')))")"
check_equal 'a REQUESTER cannot read an INTERNAL article even published (404)' 404 "$(api_status "$(rq GET "$knb/$internal_id/retrieve")")"
check_equal 'nor a retired version (404)' 404 "$(api_status "$(rq GET "$knb/$id/retrieve")")"
draft_only=$(api_body "$(draft 'Not ready' 'Still a draft' PUBLIC '[]')" | json "['id']")
check_equal 'nor a draft (404)' 404 "$(api_status "$(rq GET "$knb/$draft_only/retrieve")")"
check_equal 'a REQUESTER searches only inside the published public set, whatever they ask' "$v2_id" "$(api_body "$(rq GET "$knb/retrieve?status=DRAFT&visibility=INTERNAL&authorId=$author")" | ids)"
staff_count=$(as_b "$author" GET "$knb/retrieve" | count)
requester_count=$(api_body "$(rq GET "$knb/retrieve")" | count)
check_equal 'staff see more than a REQUESTER does' True "$([[ "$staff_count" -gt "$requester_count" ]] && echo True || echo False)"
denied=$(rq POST "$knb/initiate" '{"title":"t","body":"b","visibility":"PUBLIC"}')
check_equal 'a REQUESTER cannot write (403 ERR-KNB-00403)' '403/ERR-KNB-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'cannot publish (403)' 403 "$(api_status "$(rq PUT "$knb/$v2_id/control/publish")")"
check_equal 'cannot retire (403)' 403 "$(api_status "$(rq PUT "$knb/$v2_id/control/retire")")"
check_equal 'cannot start a version (403)' 403 "$(api_status "$(rq POST "$knb/$v2_id/version/initiate")")"
check_equal 'cannot read the versions (403)' 403 "$(api_status "$(rq GET "$knb/$v2_id/versions/retrieve")")"
check_equal 'cannot read the audit trail (403)' 403 "$(api_status "$(rq GET "$knb/$v2_id/audit-log/retrieve")")"
check_equal 'staff retire the internal article' 204 "$(as_s "$author" PUT "$knb/$internal_id/control/retire")"
check_equal 'a retired article takes no new version (409)' 409 "$(as_s "$author" POST "$knb/$internal_id/version/initiate")"
check_equal 'another tenant gets a 404 for the article' 404 "$(api_status "$(api GET "$knb/$v2_id/retrieve" "" "X-Tenant-Id: $(uuid)" "X-Executor: $author")")"

# 5. A race: two reviewers decide the same article at the same instant.
raced=$(api_body "$(draft 'Race' 'Two reviewers' PUBLIC '[]')" | json "['id']")
check_equal 'the racing article is in review' 204 "$(as_s "$author" PUT "$knb/$raced/control/submit")"
tmp=$(mktemp -d)
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $reviewer" "$knb/$raced/control/publish" > "$tmp/a" ) &
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $reviewer2" -H 'Content-Type: application/json' -d '{"comment":"Not yet"}' "$knb/$raced/control/return" > "$tmp/b" ) &
wait
codes=$(printf '%s\n%s\n' "$(cat "$tmp/a")" "$(cat "$tmp/b")" | sort | paste -sd, -)
check_equal 'exactly one reviewer wins and the other is told 409, never both and never an error' '204,409' "$codes"
final=$(get_article "$raced" | json "['status']")
check_equal 'the article ends in the state of the winner' True "$([[ "$final" == PUBLISHED || "$final" == DRAFT ]] && echo True || echo False)"
check_equal 'the audit trail holds the opening, the submission and exactly the winning move' 3 "$(as_b "$author" GET "$knb/$raced/audit-log/retrieve" | count)"
rm -rf "$tmp"
delete_status=$(as_s "$author" DELETE "$knb/$id")
check_equal 'a delete is not a thing (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 6. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-knowledge-base'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-knowledge-base'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Knowledge base smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
