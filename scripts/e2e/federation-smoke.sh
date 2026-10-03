#!/usr/bin/env bash
# Live proof of Journey 13b (bash port of federation-smoke.ps1): a person signs in through an OpenID Connect provider and ends up with
# the SAME kind of session a password login gives, with the refresh token in an HttpOnly cookie that page scripts can never read.
# Plays the BROWSER itself (no automatic redirects). Needs the stack up with the OIDC provider double (docker compose --profile sso-test):
# the federation service reaches it as IDP_ISSUER (http://mock-oidc:9000), this script as IDP_URL (http://localhost:9000).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
idp_issuer="${IDP_ISSUER:-http://mock-oidc:9000}"
idp_url="${IDP_URL:-http://localhost:9000}"
exec_hdr='X-Executor: federation-smoke'
checks=0
failed=0
tmp=$(mktemp -d)

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
jwt_claim() { python3 -c "
import base64,json,sys
p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p))[sys.argv[2]])" "$1" "$2"; }

# req METHOD URL [BODY] [HEADER...] -> sets status, body, location, setcookie; never exits on a non-2xx and never follows a redirect.
req() {
  local method=$1 url=$2 data=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
  status=$(curl "${args[@]}" "$url")
  body=$(cat "$tmp/body")
  location=$(grep -i '^location:' "$tmp/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
  setcookie=$(grep -i '^set-cookie:' "$tmp/headers" | tr -d '\r' | tr '\n' '|')
}

check_status() {
  local name=$1 expected=$2
  checks=$((checks + 1))
  if [[ "$status" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected $expected, got $status: $body"; fi
}

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

cookie_value() { sed -n 's/.*thinklab_rt=\([^;|]*\).*/\1/p' <<<"$1"; }
truth() { if "$@"; then echo true; else echo false; fi; }

set_person() { curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d "$1" "$idp_url/__mock/identity"; }

# sign_in ORG -> sets init_status, init_location, cb_status, cb_location, cb_cookie, cb_body, last_code, last_state
sign_in() {
  req GET "$gateway/identity-federation/v1/login/initiate?organisationId=$1" ""
  init_status=$status; init_location=$location
  [[ "$status" == 302 ]] || { cb_status=; cb_location=; cb_cookie=; return; }
  req GET "$(sed -E "s#^https?://[^/]+#$idp_url#" <<<"$init_location")" ""
  last_code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  last_state=$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$location")
  req GET "$gateway/identity-federation/v1/login/callback?code=$last_code&state=$last_state" ""
  cb_status=$status; cb_location=$location; cb_cookie=$setcookie; cb_body=$body
}

# 1. An organisation with a user, and its provider.
tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
req POST "$gateway/party-reference-data-directory/v1/initiate" "{\"corporateName\":\"Federation Corp\",\"tradeName\":\"FED\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@fed.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" "$exec_hdr"
check_status 'organisation created' 201
org_id=$(json "['id']" <<<"$body")
tenant="X-Tenant-Id: $org_id"
email="fed.smoke.$(uuid | tr -d '-' | cut -c1-8)@example.com"
req POST "$gateway/party-authentication/v1/initiate" "{\"fullName\":\"Fed Smoke\",\"email\":\"$email\",\"role\":\"OPERATOR\"}" "$exec_hdr" "$tenant"
check_status 'user created' 201
user_id=$(json "['id']" <<<"$body")
req PUT "$gateway/party-authentication/v1/$user_id/control/activate" "" "$exec_hdr" "$tenant"
check_status 'user activated' 204

req POST "$gateway/identity-federation/v1/initiate" "{\"issuer\":\"$idp_issuer\",\"clientId\":\"thinklab-mock\",\"clientSecretRef\":\"THINKLAB_MOCK_OIDC_SECRET\",\"autoProvision\":false}" "$exec_hdr" "$tenant"
check_status 'provider registered through the gateway' 201
provider_id=$(json "['id']" <<<"$body")
check_equal 'it starts DISABLED' DISABLED "$(json "['status']" <<<"$body")"
check_equal 'the answer names the secret variable and never holds the secret' true "$(truth bash -c '[[ "$1" != *mock-client-secret* && "$1" == *THINKLAB_MOCK_OIDC_SECRET* ]]' _ "$body")"
req GET "$gateway/identity-federation/v1/login/initiate?organisationId=$org_id" ""
check_status 'a DISABLED provider refuses sign-in (409)' 409
req PUT "$gateway/identity-federation/v1/$provider_id/control/enable" "" "$exec_hdr" "$tenant"
check_status 'provider enabled' 204

# 2. Sign-in starts with a redirect to the provider, carrying PKCE, a state and a nonce.
set_person "{\"sub\":\"smoke-subject-1\",\"email\":\"$email\",\"email_verified\":true,\"name\":\"Fed Smoke\"}"
sign_in "$org_id"
check_equal 'login/initiate answers a redirect to the provider' 302 "$init_status"
check_equal 'it points at the provider authorize endpoint' true "$(truth bash -c '[[ "$1" == "$2/authorize?"* ]]' _ "$init_location" "$idp_issuer")"
check_equal 'with the code flow, PKCE S256, a state and a nonce' true "$(truth bash -c '[[ "$1" == *response_type=code* && "$1" == *code_challenge_method=S256* && "$1" == *state=* && "$1" == *nonce=* ]]' _ "$init_location")"

# 3. A person nobody linked is refused: redirected to the login page with the error code only, and no cookie.
check_equal 'an unlinked identity is sent back to the login page' 302 "$cb_status"
check_equal 'with the error code only' '/login?sso_error=ERR-FED-00403' "$cb_location"
check_equal 'and no cookie' '' "$cb_cookie"

# 4. An administrator links the provider's subject to the user; the sign-in now ends with a cookie.
req POST "$gateway/identity-federation/v1/link/initiate" "{\"userId\":\"$user_id\",\"subject\":\"smoke-subject-1\"}" "$exec_hdr" "$tenant"
check_status 'identity linked to the user' 201
link_id=$(json "['id']" <<<"$body")
sign_in "$org_id"
check_equal 'a linked identity is sent on to the web app' 302 "$cb_status"
check_equal 'to the sign-in completion page' '/sso/complete' "$cb_location"
check_equal 'the refresh token is in an HttpOnly cookie' true "$(truth bash -c '[[ "$1" == *thinklab_rt=* && "${1,,}" == *httponly* ]]' _ "$cb_cookie")"
check_equal 'which is SameSite=Strict' true "$(truth bash -c '[[ "${1,,}" == *samesite=strict* ]]' _ "$cb_cookie")"
check_equal 'and scoped to the gateway session endpoints' true "$(truth bash -c '[[ "${1,,}" == *path=/api/gateway/v1/session* ]]' _ "$cb_cookie")"
check_equal 'the redirect carries no token in the URL or the body' true "$(truth bash -c '[[ "$1" != *token* && -z "$2" ]]' _ "$cb_location" "$cb_body")"
cookie1=$(cookie_value "$cb_cookie")
req GET "$gateway/identity-federation/v1/login/callback?code=$last_code&state=$last_state" ""
check_equal 'replaying the same code and state is refused (single-use state)' '/login?sso_error=ERR-FED-00400' "$location"

# 5. The cookie buys an access token for that user and tenant; the refresh token never reaches the body; the cookie rotates.
web='X-Requested-With: thinklab-web'
req POST "$gateway/gateway/v1/session/refresh" "" "Cookie: thinklab_rt=$cookie1"
check_status 'refresh without the web app header is refused (403)' 403
req POST "$gateway/gateway/v1/session/refresh" "" "$web"
check_status 'refresh without a cookie is refused (401)' 401
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$cookie1"
check_status 'refresh exchanges the cookie for an access token' 200
access=$(json "['accessToken']" <<<"$body")
check_equal 'the access token is for the linked user' "$user_id" "$(jwt_claim "$access" sub)"
check_equal 'in the organisation' "$org_id" "$(jwt_claim "$access" tid)"
check_equal 'with the role of the platform user, not of the provider' OPERATOR "$(jwt_claim "$access" role)"
check_equal 'the answer never contains the refresh token' true "$(truth bash -c '[[ "$1" != *refresh* ]]' _ "$body")"
cookie2=$(cookie_value "$setcookie")
check_equal 'the cookie rotated' true "$(truth bash -c '[[ -n "$1" && "$1" != "$2" ]]' _ "$cookie2" "$cookie1")"
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$cookie2"
check_status 'the rotated cookie works' 200
cookie3=$(cookie_value "$setcookie")
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$cookie1"
check_status 'a replay of the OLD cookie is refused (401)' 401
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$cookie3"
check_status 'and the replay revoked the whole session (theft detection): even the newest cookie is refused (401)' 401

# 6. Logout revokes the session and clears the cookie.
sign_in "$org_id"
cookie4=$(cookie_value "$cb_cookie")
req POST "$gateway/gateway/v1/session/logout" "" "$web" "Cookie: thinklab_rt=$cookie4"
check_status 'logout answers 204' 204
check_equal 'and clears the cookie' true "$(truth bash -c '[[ "$1" == *"thinklab_rt=;"* && "$1" == *Max-Age=0* ]]' _ "$setcookie")"
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$cookie4"
check_status 'the logged-out cookie no longer refreshes (401)' 401

# 7. Automatic provisioning (off by default): a first-time identity with a verified email gets a VIEWER; an unverified one does not.
req PUT "$gateway/identity-federation/v1/$provider_id/control/disable" "" "$exec_hdr" "$tenant"
check_status 'provider disabled to change its settings' 204
req GET "$gateway/identity-federation/v1/login/initiate?organisationId=$org_id" ""
check_status 'disabled again, it refuses sign-in (409)' 409
req PUT "$gateway/identity-federation/v1/$provider_id/update" "{\"issuer\":\"$idp_issuer\",\"clientId\":\"thinklab-mock\",\"clientSecretRef\":\"THINKLAB_MOCK_OIDC_SECRET\",\"autoProvision\":true}" "$exec_hdr" "$tenant"
check_status 'settings updated: automatic provisioning on' 204
req PUT "$gateway/identity-federation/v1/$provider_id/control/enable" "" "$exec_hdr" "$tenant"
check_status 'provider enabled again' 204
newcomer="newcomer.$(uuid | tr -d '-' | cut -c1-8)@example.com"
set_person "{\"sub\":\"smoke-subject-new\",\"email\":\"$newcomer\",\"email_verified\":true,\"name\":\"New Comer\"}"
sign_in "$org_id"
check_equal 'a first-time identity with a verified email is signed in' '/sso/complete' "$cb_location"
new_token=$(cookie_value "$cb_cookie")
req POST "$gateway/gateway/v1/session/refresh" "" "$web" "Cookie: thinklab_rt=$new_token"
check_equal 'as a VIEWER, the least privileged role' VIEWER "$(jwt_claim "$(json "['accessToken']" <<<"$body")" role)"
req GET "$gateway/identity-federation/v1/link/retrieve?status=ACTIVE" "" "$tenant"
check_equal 'a link was created for it' 2 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$body")"
set_person "{\"sub\":\"smoke-subject-unverified\",\"email\":\"unverified.$(uuid | tr -d '-' | cut -c1-8)@example.com\",\"email_verified\":false,\"name\":\"Unverified\"}"
sign_in "$org_id"
check_equal 'an UNVERIFIED email is never provisioned' '/login?sso_error=ERR-FED-00403' "$cb_location"

# 8. A revoked link ends the sign-in for that person.
req PUT "$gateway/identity-federation/v1/link/$link_id/control/revoke" "" "$exec_hdr" "$tenant"
check_status 'the first link revoked' 204
set_person "{\"sub\":\"smoke-subject-1\",\"email\":\"$email\",\"email_verified\":false,\"name\":\"Fed Smoke\"}"
sign_in "$org_id"
check_equal 'a revoked link no longer signs the person in' '/login?sso_error=ERR-FED-00403' "$cb_location"

# 9. The secret never appears in what the platform answers.
req GET "$gateway/identity-federation/v1/retrieve" "" "$tenant"
everything=$body
req GET "$gateway/identity-federation/v1/$provider_id/audit-log/retrieve" "" "$tenant"
everything="$everything$body"
check_equal 'the client secret appears in no answer' true "$(truth bash -c '[[ "$1" != *mock-client-secret* ]]' _ "$everything")"

rm -rf "$tmp"
echo
echo "Federation smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
