# Remote memory connector (ChatGPT + Claude.ai) — design

**Why.** ChatGPT and Claude.ai (web, desktop, phone) can call a *remote* MCP server but neither exposes chat history to apps.
Goal: those apps can read the shared vault and, when the user asks ("save this chat"), push context into it.

**Non-goals.** Automatic capture of every turn (MCP is model-initiated, so impossible). Fetching old chats (export importer, separate).
Anti-goal: a public endpoint onto the vault that is weaker than the data it guards.

## Approaches
1. Server on the laptop — vault is local, but the laptop sleeps. Rejected.
2. Server on `mac-agent` (24/7, python 3.15, cloudflared, ssh over tailscale) with a synced vault copy — **chosen** (user's pick).
3. Server on the mini via its RAG — extra hop, no whole-note reads. Rejected.

## Design
- `agentvault/remote/` stdlib-only (python 3.9+ compatible): `oauth.py` (store + PKCE), `server.py` (HTTP), tool glue in `mcp_server.handle(extra=…)`.
- Streamable HTTP, plain-JSON responses (no SSE). `POST /mcp`, bearer required; 401 carries `WWW-Authenticate: Bearer resource_metadata=…`.
- OAuth 2.1 single owner: discovery (`/.well-known/oauth-protected-resource`, `…/oauth-authorization-server`), dynamic client registration
  (public clients, redirect host allow-list: chatgpt.com, claude.ai, claude.com), `/authorize` consent page gated by an owner passphrase
  (constant-time compare, 5 failures → 10 min lock), PKCE S256 only, auth code 5 min single-use, access token 1 h, refresh 30 d rotating.
  Token and code values are stored only as SHA-256 hashes; state file mode 0600.
- Tools: `vault_search`, `vault_recent`, `vault_read` (keyword only on this host) + `remember(title, content, source)` →
  note `Sessions/<chatgpt|claude-web|other-ai>/…` via the existing idempotent redacting writer. Content cap 200k chars.
- Binds 127.0.0.1; cloudflared (already on the host) publishes it. **Publishing the hostname is outward-facing: done only after user OK.**
- Sync (later task): laptop → host `Sessions/` (excluding the three remote sources) every 5 min; host → laptop pull of those three.

## Left to builder
Port, paths, launchd plist, page styling. Judgement calls are ledgered in the plan commit messages.
