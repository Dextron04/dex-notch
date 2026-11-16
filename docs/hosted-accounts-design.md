# Hosted accounts: design draft

Status: draft, nothing built. Goal: other people sign up, pay, and use the hosted memory connector (vault_search / vault_read / vault_recent / remember / remind) from ChatGPT and Claude, with their data isolated from everyone else's.

## Decisions to confirm first

1. **What is paid.** Assumed: the hosted connector (memory + reminders). The notch app stays free; it just signs in. Change if the app itself is paid.
2. **Where data comes from.** Assumed: customers run the Mac recorder and it uploads to the server. If customers only ever use `remember`/`remind` from chat, skip section 5.
3. **Host.** Assumed: a new small VPS, not the home mini. The mini keeps serving the personal single-owner connector unchanged.

## Non-goals (v1)

Teams/orgs, sharing a vault between users, a web UI for browsing notes, mobile app, usage-based billing, SSO.

## Architecture

New service `hosted/` (Python, same stdlib/light-deps style as `memory/agentvault/remote`), reusing `notes.py`, `redact.py`, `search.py`, `mcp_server.handle`. The single-owner `remote/` code is not modified.

```
ChatGPT / Claude --OAuth+MCP--> /mcp  ┐
Mac recorder ------device token--> /v1/ingest ├─> hosted service ─> SQLite (users, billing, tokens)
Notch app ---------device token--> /v1/reminders/wait ┘             └> data/<user_id>/Vault/...
Stripe ----signed webhook--------> /hooks/stripe
```

Every request resolves to a `user_id` first; nothing below that layer ever sees a path or query not scoped to it.

## 1. Accounts

SQLite (WAL mode). Move to Postgres only if write contention shows up.

```
users(id, email UNIQUE, created_at, status)          -- status: pending|active|past_due|canceled|deleted
billing(user_id, stripe_customer_id, stripe_sub_id, plan, period_end)
login_links(token_hash, user_id, exp, used)          -- magic link, 15 min, single use
clients(client_id, redirect_uris, name)              -- dynamic registration, as today
codes / access / refresh(token_hash, user_id, client_id, exp)   -- same hashing as today, plus user_id
devices(id, user_id, name, token_hash, created_at, last_seen, revoked)
```

Login: email magic link (no passwords to store or leak). Session cookie only on the sign-in/billing pages.

## 2. Billing (Stripe)

- Signup: email -> Stripe Checkout (subscription) -> webhook creates/activates the user.
- `/hooks/stripe`: verify signature, handle `checkout.session.completed`, `customer.subscription.updated|deleted`, `invoice.payment_failed`. Idempotent on event id.
- Entitlement = `status == active` (or `past_due` within a 7-day grace). Checked on **every** `/mcp`, `/v1/*` call, not only at login.
- Customer portal link for cancel/update card; no billing UI of our own.
- Cancelled: read-only for 30 days (export allowed), then deleted.

## 3. OAuth changes (vs `remote/oauth.py`)

- `/authorize`: replace the passphrase with sign-in. Not signed in -> magic link; signed in but unpaid -> Checkout; active -> consent button.
- `issue_code`/`_tokens` store `user_id`; `check()` returns the user, and the caller rejects non-active users.
- Keep: PKCE S256, hashed tokens, rotating refresh, redirect-host allowlist (chatgpt.com, claude.ai, claude.com), failed-login lockout (now per account and IP).
- Revocation: `devices.revoked` and a "sign out everywhere" that deletes the user's tokens.

## 4. Tenant isolation

- Layout: `data/<user_id>/Vault/Sessions/...`, `data/<user_id>/Vault/Reminders/`. `user_id` is a random 128-bit id, never the email.
- One function `user_vault(user_id) -> Path`. All tool handlers receive that Path as `vault`, which is how `mcp_server.call` already works, so the existing handlers are reused as is.
- `search.read` already confines paths to the vault; add a test that `../` and symlinks cannot escape, and that user A's token can't read user B's note path.
- Semantic search (`rag_push`): separate index per user, or skip semantic search in v1 and ship the grep search (fine at per-user scale).
- Quotas: 500 MB vault, 100 MB per ingest request cap lowered to 5 MB, `remember` 200k chars (as today), 60 req/min per user.

## 5. Ingest (replaces rsync)

- `POST /v1/ingest` with `Authorization: Bearer <device token>`, body = a note (frontmatter + turns) or a batch. Server re-runs `redact()` and `add_turns` (idempotent, same as `remember`), so client trust is not required.
- Device token: issued from the signed-in web page ("Add this Mac"), copied/pasted into the notch app once and stored in Keychain. Per-device, revocable.
- `GET /v1/reminders/wait`: same held-connection protocol as today, but authenticated with the device token and scoped to that user's `Reminders/`.
- The recorder gets a `--hosted` mode that posts instead of rsync; existing personal setups are untouched.

## 6. Notch app changes

- Settings: "Hosted memory" section: sign in (opens browser), "Add this Mac", status/plan, sign out.
- Keychain item for the device token; recorder reads it.
- No change to local-only operation; hosted is opt-in.

## 7. Ops

- VPS (2 vCPU/2 GB is plenty to start), Caddy/Cloudflare in front, systemd unit, non-root user.
- Backups: nightly encrypted snapshot of SQLite + `data/` to object storage; restore tested before launch.
- Encryption at rest: full-disk on the VPS (v1). Per-user keys are a later option.
- Logs: request id, user id, route, status; never bodies or URLs with codes. Alerts on 5xx rate and webhook failures.
- Deploy: reuse the CI-green -> signed webhook -> backup/health-check/rollback pattern from `connector-deploy.sh`.

## 8. Legal / privacy (before first paying user)

Terms, privacy policy listing exactly what is stored (private AI conversations), data export + delete endpoints (`/v1/export`, `/v1/account DELETE` purging `data/<user_id>` and DB rows), a named retention period, and a breach contact. Update `PRIVACY.md` (currently describes the local-only app).

## 9. Threat model (short)

| Threat | Mitigation |
|---|---|
| Cross-tenant read | user-scoped vault Path, path-escape tests, user_id in every token |
| Stolen device token | per-device, revocable, hashed at rest |
| Webhook forgery | Stripe signature + event-id dedupe |
| Login brute force / email flooding | per-IP and per-email rate limits, single-use short-lived links |
| Secrets in notes | redact on ingest server-side |
| One tenant starving the rest | quotas, rate limits, request size caps |
| Operator access to private chats | document it honestly; admin access is break-glass and logged |

## Build order

1. `hosted/` skeleton + users/tokens schema + `user_vault()` + isolation tests.
2. OAuth with real users (magic link), entitlement check on `/mcp`; test with a hand-made active user.
3. Stripe Checkout + webhook; flip entitlement from real payments in test mode.
4. `remember`/`remind`/search end to end from Claude and ChatGPT against the new service.
5. Device tokens + `/v1/ingest` + reminders wait; recorder `--hosted`; notch Settings UI.
6. Quotas, export/delete, backups, monitoring, legal pages.
7. Closed beta with 3-5 people, then open.

## Open questions

- Price and plan shape (flat monthly? free trial?)
- Magic link only, or also "Sign in with Google/Apple"?
- Domain: new (e.g. `dex.<yourdomain>`) vs a subdomain of `dextron04.in`?
- Is semantic search needed for v1?
