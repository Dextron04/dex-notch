#!/bin/bash
# Read-only check of a live Dex Notch hosted service: pages up, security headers on, doors that must be shut are shut, new code is what is served.
#   scripts/verify-hosted.sh [https://vault.dextron04.in]
# It creates no account and changes nothing (its one POST asks for a passkey challenge, which expires by itself). Exit status 1 if anything fails.
H="${1:-https://vault.dextron04.in}"; H="${H%/}"; fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@"; }
expect() { local want="$1" label="$2"; shift 2; local got; got=$(code "$@"); [ "$got" = "$want" ] && ok "$label ($got)" || bad "$label: wanted $want, got $got"; }

echo "Pages"
for p in / /about /connect /privacy /terms /login /waitlist /healthz /.well-known/security.txt; do expect 200 "GET $p" "$H$p"; done
echo "Doors that must be shut"
expect 302 "/account without a session redirects" "$H/account"
expect 401 "/v1/me without a key" "$H/v1/me"
expect 401 "/mcp without a token" -X POST -H 'Content-Type: application/json' -d '{}' "$H/mcp"
expect 401 "/v1/ingest without a key" -X POST -H 'Content-Type: application/json' -d '{}' "$H/v1/ingest"
expect 404 "/admin is invisible to strangers" "$H/admin"
expect 404 "/hooks/stripe is off" -X POST "$H/hooks/stripe"
expect 404 "static path traversal" "$H/static/..%2fstore.py"
expect 415 "passkey endpoints refuse form posts" -X POST -d 'a=1' "$H/webauthn/login/options"
expect 401 "passkey registration needs a session" -X POST -H 'Content-Type: application/json' -d '{}' "$H/webauthn/register/options"
echo "Transport and headers"
r=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "http://${H#https://}/healthz"); [ "${r%% *}" = "308" ] && ok "http redirects to https ($r)" || bad "http does not redirect: $r"
h=$(curl -sI -m 15 "$H/"); for want in "strict-transport-security" "content-security-policy" "x-content-type-options"; do echo "$h" | grep -qi "^$want" && ok "header $want" || bad "missing header $want"; done
echo "$h" | grep -qi "script-src 'self'" && ok "CSP allows only own scripts" || bad "CSP does not restrict scripts to 'self'"
echo "What is served is current"
js=$(curl -s -m 15 "$H/login" | grep -o '/static/passkey.js?v=[a-f0-9]*' | head -1)
[ -n "$js" ] && ok "login page loads $js" || bad "login page has no passkey script"
[ -n "$js" ] && [ "$(curl -s -m 15 "$H$js" | grep -c 'webauthn/login/options')" -ge 1 ] && ok "passkey script is the current one" || bad "passkey script missing or old"
curl -s -m 15 "$H/connect" | grep -q "add-custom-connector" && ok "Connect page has the Claude add link" || bad "Connect page is missing the Claude add link"
curl -s -m 15 "$H/privacy" | grep -qi "not end-to-end" && ok "privacy page states the encryption limits" || bad "privacy page does not state the limits"
curl -s -m 15 "$H/.well-known/security.txt" | grep -q "^Contact:" && ok "security.txt has a contact" || bad "security.txt has no contact"
c=$(curl -s -m 15 -X POST -H 'Content-Type: application/json' -d '{}' "$H/webauthn/login/options")
echo "$c" | grep -q '"userVerification": "required"' && echo "$c" | grep -q "\"rpId\": \"${H#https://}\"" && ok "passkey options: this site only, touch required" || bad "passkey options look wrong: $c"
echo
[ $fail = 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit $fail
