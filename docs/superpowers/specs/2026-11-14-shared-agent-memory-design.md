# Shared agent memory — design

Status: approved by Dextron 2026-11-14 · Date: 2026-11-14

Decisions from Dextron: **import all existing history** (Claude Code, Codex, Gemini) on first run; **no exclusions** (no ignore list). Redaction still applies to everything, including the backfill. The first-run backfill must be resumable and run at low priority (it is ~1GB of input).

## Intent and why

Dextron uses several agents (Claude Code in terminal and inside Claude Desktop, Codex, Gemini/Antigravity, later phone apps). Each starts every session knowing nothing about what he decided in the others. Goal: every agent conversation is recorded as a markdown note in one Obsidian vault, so any agent can look up what was discussed elsewhere, Claude Code starts each session already briefed on recent activity, and the notch app can show "what was recorded and what my last conversation with each agent was", looking great.

## Goals

- Every Claude Code, Codex and Gemini session on the laptop becomes a note in the vault within about a minute of activity, with no manual step.
- Vault is a normal Obsidian vault (opens natively in Obsidian.app, which is installed).
- Vault is mirrored to the mac-mini; the mini's existing RAG indexes it for semantic search.
- **A (on demand):** any agent can search/read the vault through an MCP server.
- **B (automatic, Claude Code only):** a SessionStart hook injects a short digest of recent activity.
- Notch app "recall" view (own hotkey): counters, last conversation per agent, open a note, ask Gemma about a note, search.
- Secrets are redacted before anything is written.

## Non-goals

- No network interception / TLS-decrypting proxy. Source is each agent's own local session files or hooks.
- No phone capture in this phase (see Phase 2). No Claude/ChatGPT app chat import yet.
- No rewriting of the mini's RAG. It is used as is (to be inspected during planning).
- No cloud sync or third-party services.

## Anti-goals (a failure even if it "works")

- A secret (API key, token, password, private key) lands in the vault or the mini mirror.
- Every Claude Code session burns thousands of tokens on a digest it didn't need.
- The recorder double-writes or corrupts notes when a session is appended to (idempotence).
- Recording silently stops and nobody notices. The notch must show recorder health.

## Constraints

- macOS laptop is the capture point; mini (Tailscale, user `mac-brain`, reachable as `mac-mini`, also via `hc`) is the mirror and indexer.
- Python 3.9 only on the mini (Command Line Tools). Laptop tooling free to choose.
- Installing anything on the mini (Syncthing) needs explicit approval at implementation time; the mini's gateway token is already in the laptop Keychain.
- Session files observed: Claude Code `~/.claude/projects/<proj>/<session>.jsonl` (types `user`, `assistant`, `system`, `ai-title`, plus many internal record types to ignore); Codex `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`session_meta`, `response_item` with role `user`/`assistant`, others to ignore); Gemini data under `~/.gemini` (format not yet inspected).

## Approaches considered

- **A. Local vault mirrored to mini — chosen by Dextron.** Recorder writes into `~/Vault`; Syncthing mirrors to the mini; RAG indexes the mirror; MCP search and the CC digest read the local copy (fast, offline).
- B. Vault only on mini, recorder POSTs over the gateway. Single source of truth, but logging fails offline and Obsidian can't open it cleanly.
- C. Local only, add mini later. Fastest, but no semantic search. Rejected as the end state, but its pieces are step one of A.

## Design

**Layout** (my call): `~/Vault/{Sessions/<agent>/<YYYY-MM>/<date>-<project>-<slug>.md, Agents/<agent>.md, Index.md}`. A note has frontmatter (`agent`, `project`, `cwd`, `session_id`, `started`, `updated`, `turns`, `source_path`) then a `## Turn` per exchange.

**Recorder** (laptop, launchd agent, my call: Python 3 stdlib only):
- Polls known session directories every ~30s (my call: polling, not fsevents; simpler, good enough) and keeps a byte-offset checkpoint per file, so each tick only parses appended lines and rewriting a note is idempotent (notes keyed by `session_id`).
- One small adapter per agent turns raw lines into `(role, text, ts)`. Adding an agent = adding an adapter.
- What is recorded (my call): user prompts and assistant text. Tool calls become one-line summaries (`ran: <tool> <short arg>`). Tool output bodies and model "thinking" are skipped.
- Redaction pass before write: known key patterns (OpenAI/Anthropic/AWS/GitHub/Google keys, JWTs, `Bearer …`, private-key blocks, `password=`/`token=` assignments, high-entropy strings next to key-like names). Redacted spans become `[redacted:<kind>]`.
- Writes a heartbeat file (`~/Vault/.recorder/status.json`: last run, sessions seen, per-agent counts, errors) read by the notch.

**Sync**: Syncthing between laptop `~/Vault` and mini `~/Vault`, excluding `.recorder/`. The mini side is read-only in practice (my call: configured as receive-only so a bad mini process can't corrupt the laptop copy).

**Mini index**: point the existing RAG ingest at the mirrored vault. Details depend on inspecting `~/server/rag` (listed as an open item for the builder).

**MCP server** (laptop, local, stdio, my call): tools `vault_search(query, agent?, since?)`, `vault_recent(agent?, n)`, `vault_read(path)`. Search is text matching first; semantic search via the mini's RAG (`/rag/*` through the gateway, bearer from Keychain) when reachable. Registered for Claude Code, Codex and Gemini config.

**Claude Code digest (B)**: SessionStart hook runs a script printing a digest of at most ~400 tokens (my call): per agent, last 3 sessions with title and date, plus sessions for the current project. Hook failures must never block session start (timeout, silent on error).

**Notch recall view**: second global hotkey (my call: ⌥⇧Space). Reads `status.json` and the vault locally. Shows counters (sessions, agents, +today), recorder health dot, one row per agent with its last conversation title, project and age; keyboard navigation; Return opens the note in Obsidian (`obsidian://open?...`); ⌘Return asks Gemma for a short summary of that note through the existing gateway; `/` searches. Same ink-and-ember visual language as the prompt view; exact motion and layout left to the builder within it.

## Phase 2 (separate design later)

Phone: Claude Code sessions run on a machine we control are captured for free. Regular Claude/ChatGPT app chats come in via scheduled import of their data exports. Optional chat page on the mini that logs live. Claude Desktop's own chat history needs inspection; only its embedded Claude Code sessions (`~/Library/Application Support/Claude/claude-code-sessions`) are known so far.

## Left to the builder

Exact regex set and entropy threshold for redaction; note slug rules; polling vs fsevents if latency matters; Gemini adapter format; how the mini's RAG ingests markdown (and whether it needs a small endpoint or a watched folder); MCP registration syntax per agent; visual detail of the recall view; tests (redaction and idempotence must have them).
