# Shared Agent Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every agent conversation on the laptop (Claude Code, Codex, Gemini) as redacted markdown notes in an Obsidian vault, mirror it to the mac-mini for RAG, expose it to agents (MCP search; Claude Code startup digest), and show it in the notch app's recall view.

**Architecture:** A stdlib-Python recorder polls each agent's local session files, parses them with per-agent adapters, redacts secrets, and appends to notes in `~/Vault`. Syncthing mirrors the vault to the mini (receive-only), where the existing RAG indexes it. A local MCP server and a SessionStart hook read the vault; the Swift notch app reads it for a recall view.

**Tech Stack:** Python 3 (stdlib only, 3.9-compatible syntax), launchd, Syncthing (already at `/opt/homebrew/bin/syncthing` on the laptop), Swift 6 / SwiftUI (existing app), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-14-shared-agent-memory-design.md`

## Global Constraints

- Python code: stdlib only, no `match`, no `X | Y` type unions, no `list[str]` at runtime outside annotations with `from __future__ import annotations`.
- Tests: `python3 -m unittest discover -s memory/tests -v` from the repo root.
- Vault is `~/Vault`; sessions at `Sessions/<agent>/<YYYY-MM>/<date>-<project>-<slug>.md`; recorder state/heartbeat in `~/Vault/.recorder/` (state.json, status.json), never synced.
- Recorder polls every 30 seconds; first run imports ALL existing history (resumable, `os.nice(15)`).
- Recorded: user prompts and assistant text; tool calls as one-line `ran: <tool> <short arg>`; no tool output bodies, no model reasoning.
- Redaction runs on every string before it is written, including backfill. No ignore list.
- Digest injected at Claude Code session start is at most ~400 tokens (≈1600 characters).
- Notch recall hotkey: ⌥⇧Space. Prompt hotkey stays ⌥Space.
- No TLS interception or traffic proxying anywhere.
- The mini's vault copy is Syncthing receive-only. Installing software on the mini requires Dextron's explicit go-ahead at that step.
- Commits: never add Claude as co-author or any "Generated with Claude" line (user's global rule). The repo has no commits yet; Task 1's commit also creates the first commit containing the existing app.
- Existing app facts: Swift 6, macOS 14+, XcodeGen (`project.yml`, rerun `xcodegen generate` after adding files); gateway `https://ai.example.com`, bearer token in Keychain (service `ai.example.com`, account `notchapp`).

## Review Focus

1. A session file whose last line is half-written when polled: no crash, no lost turn, parsed fully next tick.
2. A multi-hundred-MB session file: memory stays bounded (stream lines, never `read()` the file).
3. False positives: git SHAs, UUIDs and normal prose must not be redacted; real keys inside fenced code, JSON and URLs must be.
4. Odd project paths, emoji/unicode titles, two sessions with the same slug on the same day: valid unique filenames, no overwrite.
5. A session file replaced or truncated (smaller than saved offset): note is rebuilt, no duplicated turns.
6. Syncthing conflict files (`*.sync-conflict-*`) in the vault: ignored by search, digest and recall.
7. `vault_read` given `../../etc/passwd` or an absolute path: refused.

---

### Task 1: Redaction

**Files:**
- Create: `memory/agentvault/__init__.py` (empty), `memory/agentvault/redact.py`
- Test: `memory/tests/test_redact.py`

**Interfaces:**
- Produces: `redact(text: str) -> str`. Replaces each secret span with `[redacted:<kind>]`; `<kind>` in `openai`, `anthropic`, `aws`, `github`, `google`, `jwt`, `bearer`, `private-key`, `assignment`.

- [ ] **Step 1: Write failing tests** in `test_redact.py`: `test_known_key_formats` (one sample per kind, assert output contains `[redacted:<kind>]` and not the sample); `test_assignment` (`password=hunter2xyz`, `"api_key": "abc123def456ghi789"` → redacted values, key names kept); `test_private_key_block` (multi-line PEM → single marker); `test_keeps_non_secrets` (a 40-hex git SHA, a UUID, `sk-` inside the word `task-list`, ordinary prose are unchanged); `test_key_inside_url_and_code_fence`; `test_idempotent` (`redact(redact(x)) == redact(x)`).
- [ ] **Step 2:** Run `python3 -m unittest memory.tests.test_redact -v`. Expected: FAIL (ImportError).
- [ ] **Step 3: Implement `redact(text: str) -> str`** with an ordered list of compiled regexes (private-key block first, then provider prefixes, JWT, `Bearer <token>`, then `(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*["']?<8+ chars>`). Provider patterns need word boundaries and minimum lengths so SHAs/UUIDs/`task-list` do not match.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Commit** (`git add -A && git commit -m "feat(memory): secret redaction"`).

### Task 2: Data model, note writer, indexes

**Files:**
- Create: `memory/agentvault/model.py`, `memory/agentvault/notes.py`, `memory/agentvault/index.py`
- Test: `memory/tests/test_notes.py`

**Interfaces:**
- Consumes: `redact(text) -> str` (Task 1).
- Produces:
  - `model.Turn(role: str, text: str, ts: str)` dataclass; `role` in `"user"|"assistant"|"tool"`, `ts` ISO-8601 UTC.
  - `model.SessionMeta(agent: str, session_id: str, project: str, cwd: str, started: str, title: str, source_path: str)` dataclass.
  - `notes.note_path(vault: Path, meta: SessionMeta) -> Path` (deterministic per `(agent, session_id)`; slug collisions resolved by appending `-<first 6 of session_id>`).
  - `notes.append_turns(vault: Path, meta: SessionMeta, turns: List[Turn]) -> Path` (creates note with frontmatter `agent, project, cwd, session_id, started, updated, turns, source_path`; appends `## <role> · <ts>` sections; updates `updated` and `turns`; redacts every text; writes atomically via temp file + rename).
  - `notes.reset_note(vault, meta) -> None` (deletes note so a rebuild starts clean).
  - `index.rebuild_indexes(vault: Path) -> None` (writes `Index.md` and `Agents/<agent>.md` with wikilinks to the 50 most recent sessions each, newest first; skips `*.sync-conflict-*`).

- [ ] **Step 1: Write failing tests**: `test_creates_note_with_frontmatter`; `test_append_is_additive_and_updates_counts`; `test_redacts_on_write` (secret in a turn never appears in the file); `test_slug_safe_for_emoji_and_slashes` and `test_same_slug_same_day_gets_unique_files`; `test_atomic_write_leaves_no_temp_files`; `test_indexes_list_newest_first_and_skip_conflicts`.
- [ ] **Step 2:** Run `python3 -m unittest memory.tests.test_notes -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. Frontmatter is hand-written YAML (values quoted via `json.dumps`).
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5: Commit** (`feat(memory): note writer and indexes`).

### Task 3: Agent adapters

**Files:**
- Create: `memory/agentvault/adapters/__init__.py`, `base.py`, `claude_code.py`, `codex.py`, `gemini.py`
- Test: `memory/tests/test_adapters.py`, fixtures in `memory/tests/fixtures/` (small hand-made jsonl copies of the real shapes)

**Interfaces:**
- Consumes: `Turn`, `SessionMeta` (Task 2).
- Produces: `class Adapter` with `name: str`, `discover(self) -> Iterator[Path]` (session files, oldest first), and `parse(self, path: Path, offset: int) -> Tuple[Optional[SessionMeta], List[Turn], int]` returning the new byte offset just past the last COMPLETE line (a trailing partial line is not consumed). `ADAPTERS: List[Adapter]` in `adapters/__init__.py`. Constructors take an optional root path so tests can point at fixtures.

- [ ] **Step 1: Inspect formats.** Claude Code: `~/.claude/projects/*/*.jsonl`, records with `type` in `user`/`assistant` (ignore `attachment`, `api-request*`, `system`, `mode`, etc.; `ai-title` gives the title; `message.content` is a string or list of blocks with `text`/`tool_use`/`tool_result`). Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, `session_meta` then `response_item` with `payload.type == "message"` and role `user`/`assistant` (skip `developer`, `reasoning`). Gemini: look under `~/.gemini/antigravity*` for conversation/history files; if no readable transcript format exists, `GeminiAdapter.discover()` returns nothing and `status.json` (Task 4) reports it as `unsupported`. Write the finding into the adapter docstring.
- [ ] **Step 2: Write failing tests** per adapter: `test_extracts_user_and_assistant_text`; `test_tool_use_becomes_one_line_summary` (Claude Code); `test_skips_tool_output_and_reasoning`; `test_partial_last_line_not_consumed` (offset stops before it; re-parse after the line is completed yields the turn); `test_offset_resumes_without_duplicates`; `test_tolerates_garbage_lines`; `test_meta_has_project_cwd_title`.
- [ ] **Step 3:** Run `python3 -m unittest memory.tests.test_adapters -v`. Expected: FAIL.
- [ ] **Step 4: Implement** adapters; read files in binary, iterate lines (streaming), decode with `errors="replace"`, stop before an unterminated final line. Project name = last path component of `cwd`.
- [ ] **Step 5:** Run tests. Expected: PASS.
- [ ] **Step 6: Commit** (`feat(memory): claude code, codex, gemini adapters`).

### Task 4: Recorder engine, backfill, CLI, launchd

**Files:**
- Create: `memory/agentvault/recorder.py`, `memory/agentvault/__main__.py`, `memory/launchd/in.dextron04.agentvault.plist.template`, `memory/install.sh`
- Test: `memory/tests/test_recorder.py`

**Interfaces:**
- Consumes: `ADAPTERS`, `Adapter.parse`, `append_turns`, `reset_note`, `rebuild_indexes`.
- Produces:
  - `recorder.tick(vault: Path, adapters: List[Adapter], state_path: Path) -> Dict` stats `{"new_turns": int, "files": int, "errors": List[str]}`; state file maps source path to `{"offset": int, "size": int, "meta": {...}}`; saved after EACH file so backfill is resumable; writes `~/Vault/.recorder/status.json` with `{"last_run", "agents": {name: {"sessions": int, "turns": int, "state": "ok"|"unsupported"|"error"}}, "errors": [...]}`; if a file's size is smaller than its saved offset it is re-parsed from 0 after `reset_note`; per-file exceptions are recorded, never fatal.
  - CLI: `python3 -m agentvault once` (one tick), `run` (loop every 30s), `backfill` (tick with `os.nice(15)` until nothing new), all with `--vault` defaulting to `~/Vault`.
  - `install.sh`: renders the plist template with absolute paths into `~/Library/LaunchAgents/` and runs `launchctl bootstrap gui/$(id -u) ...`.

- [ ] **Step 1: Write failing tests** using fixture adapters on a temp dir: `test_tick_records_new_turns_once` (second tick adds nothing); `test_resumes_after_interruption` (kill mid-backfill by raising in the third file, rerun, no duplicates); `test_truncated_source_rebuilds_note`; `test_one_bad_file_does_not_stop_others`; `test_status_json_written_with_per_agent_counts`; `test_large_file_streamed` (generate a 50MB jsonl, assert peak memory growth under 100MB via `tracemalloc`).
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3: Implement** `tick`, CLI, `install.sh`, and the plist (`RunAtLoad`, `KeepAlive`, `ProgramArguments` = python3 `-m agentvault run`, `WorkingDirectory` = `memory/`).
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Backfill for real.** Run `cd memory && python3 -m agentvault backfill` (low priority; ~1GB). Expected: `~/Vault/Sessions/claude-code/...` populated; `rg -c "sk-ant-|AKIA" ~/Vault` returns nothing; spot-open one note in Obsidian.
- [ ] **Step 6: Install** `memory/install.sh`; verify `launchctl list | grep agentvault` and that a new Claude Code message appears in a note within ~60s.
- [ ] **Step 7: Commit** (`feat(memory): recorder, backfill, launchd agent`).

### Task 5: Vault search library and MCP server

**Files:**
- Create: `memory/agentvault/search.py`, `memory/agentvault/mcp_server.py`
- Test: `memory/tests/test_search.py`, `memory/tests/test_mcp.py`

**Interfaces:**
- Consumes: vault layout from Task 2.
- Produces:
  - `search.Hit(path: str, agent: str, project: str, title: str, updated: str, snippet: str)`.
  - `search.search(vault: Path, query: str, agent: Optional[str] = None, since: Optional[str] = None, limit: int = 10) -> List[Hit]` (case-insensitive multi-term match scored by term hits; paths relative to the vault; skips `.recorder/` and `*.sync-conflict-*`).
  - `search.recent(vault: Path, agent: Optional[str] = None, n: int = 5) -> List[Hit]`.
  - `search.read(vault: Path, rel_path: str) -> str` (raises `ValueError` if the resolved path is outside the vault or not a `.md` file).
  - MCP stdio server (JSON-RPC 2.0, newline-delimited): `initialize`, `tools/list`, `tools/call` for `vault_search(query, agent?, since?)`, `vault_recent(agent?, n?)`, `vault_read(path)`; run as `python3 -m agentvault.mcp_server --vault ~/Vault`.

- [ ] **Step 1: Write failing tests**: `test_search_ranks_by_term_hits`; `test_filters_by_agent_and_since`; `test_ignores_conflict_files_and_recorder_dir`; `test_read_rejects_traversal_and_absolute_paths` (`../../etc/passwd`, `/etc/passwd`, symlink escape); `test_mcp_initialize_list_call_roundtrip` (spawn server subprocess, send three requests, assert tool names and a search result).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement** search with `os.scandir`/frontmatter parsing only (no index); MCP server with `json` over stdin/stdout, errors as JSON-RPC errors.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Register** the server for each agent (show Dextron each config change before writing it): Claude Code via `claude mcp add agentvault -- python3 -m agentvault.mcp_server` (with `cwd`/`PYTHONPATH` = `memory/`), Codex in `~/.codex/config.toml` `[mcp_servers.agentvault]`, Gemini per its settings file. Verify by asking each agent to call `vault_recent`.
- [ ] **Step 6: Commit** (`feat(memory): vault search and MCP server`).

### Task 6: Claude Code startup digest (B)

**Files:**
- Create: `memory/agentvault/digest.py`, `memory/hooks/session_start.py`
- Test: `memory/tests/test_digest.py`
- Modify: `~/.claude/settings.json` (outside repo; requires Dextron's approval of the exact diff)

**Interfaces:**
- Consumes: `search.recent`.
- Produces: `digest.build_digest(vault: Path, cwd: str, max_chars: int = 1600) -> str` (heading, then per agent the last 3 sessions as `- <date> <title> (<project>)`, then up to 3 sessions whose project matches `cwd`'s last component; returns `""` when the vault is empty; never exceeds `max_chars`). `hooks/session_start.py` prints `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": <digest>}}`, exits 0 on ANY error, and self-terminates after 2 seconds.

- [ ] **Step 1: Write failing tests**: `test_digest_under_budget_with_many_sessions`; `test_empty_vault_gives_empty_digest`; `test_project_matches_listed_first`; `test_hook_prints_valid_json_and_exits_zero_on_missing_vault`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Install the hook**: show the exact `hooks.SessionStart` entry for `~/.claude/settings.json`, get approval, add it. Verify by starting a new Claude Code session and confirming the digest appears in context.
- [ ] **Step 6: Commit** (`feat(memory): claude code startup digest`).

### Task 7: Mirror to the mini and index with RAG

**Files:**
- Modify: mini's `~/server/rag` ingest configuration (inspect `~/server/rag/rag/ingest.py` and `collector/` first); Syncthing config on both machines.
- Create: `memory/docs/sync.md` (what was installed and how to undo it)

**Interfaces:**
- Consumes: the vault on disk.
- Produces: `~/Vault` on the mini containing the same notes (receive-only), indexed by the RAG so that `POST https://ai.example.com/rag/...` (path discovered while inspecting) returns vault hits.

- [ ] **Step 1: Get Dextron's explicit go-ahead** to install Syncthing on the mini (`brew install syncthing` over `hc exec --on mac-mini`) and to change the mini's RAG ingest settings. Stop here without it.
- [ ] **Step 2:** On the mini install Syncthing; on both machines set a `.stignore` of `.recorder` and `*.sync-conflict-*`; share folder `~/Vault` laptop → mini over Tailscale addresses; set the mini's folder type to **Receive Only**.
- [ ] **Step 3: Verify sync:** append a line to a test note on the laptop; within 60s `hc exec --on mac-mini 'rg -c <marker> ~/Vault'` finds it. Delete the test note.
- [ ] **Step 4: Inspect RAG ingest** (read-only) to learn how documents enter (`documents`/`chunks` tables, chunker, embedding via `nomic-embed-text`); add the mirrored vault as a source with the least change (watched folder or a small ingest script run by launchd on the mini).
- [ ] **Step 5: Verify retrieval:** query the RAG endpoint through the gateway with a phrase from a known session; expect a hit pointing at that note.
- [ ] **Step 6:** Extend `search.search` with an optional semantic pass: when the gateway is reachable (2s timeout, token from Keychain via `/usr/bin/security`), merge RAG hits after local hits; unit-test with a stub server (`test_search_falls_back_when_rag_unreachable`).
- [ ] **Step 7: Commit** (`feat(memory): mini mirror and rag search`).

### Task 8: Notch recall view

**Files:**
- Create: `NotchApp/VaultReader.swift`, `NotchApp/RecallView.swift`, `NotchAppTests/VaultReaderTests.swift`
- Modify: `NotchApp/Hotkey.swift` (support several hotkeys), `NotchApp/NotchApp.swift` (register ⌥⇧Space), `NotchApp/Assistant.swift` (add `mode`), `NotchApp/NotchView.swift` (switch on mode), `project.yml` (XCTest target)

**Interfaces:**
- Consumes: `~/Vault/.recorder/status.json`, `Sessions/**/*.md` frontmatter (Task 2/4 formats), gateway chat endpoint (existing `Assistant`).
- Produces:
  - `struct AgentSummary { name: String; sessions: Int; lastTitle: String; lastProject: String; lastUpdated: Date; notePath: URL; state: String }`; `struct VaultSnapshot { totalSessions: Int; todayCount: Int; recorderOK: Bool; agents: [AgentSummary] }`.
  - `enum VaultReader { static func snapshot(vault: URL) -> VaultSnapshot; static func search(vault: URL, query: String) -> [AgentSummary] }` (ignores `*.sync-conflict-*`; recorder counts as not OK when `last_run` is older than 3 minutes).
  - `Hotkey` becomes `Hotkey.register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void)` keeping the single-hotkey call sites working.
  - `Assistant.Mode { case prompt, recall }` and `Assistant.openRecall()`.

- [ ] **Step 1: Write failing XCTests** against a temp vault fixture: `testSnapshotCountsAndLastPerAgent`; `testStaleHeartbeatMarksRecorderDown`; `testIgnoresConflictFiles`; `testEmptyVaultGivesZeroSnapshot`; `testSearchMatchesTitleAndProject`.
- [ ] **Step 2:** Run `xcodegen generate && xcodebuild test -project NotchApp.xcodeproj -scheme NotchApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. Expected: FAIL.
- [ ] **Step 3: Implement `VaultReader`** (parse only the first 30 lines of each note for frontmatter).
- [ ] **Step 4:** Rerun the tests. Expected: PASS.
- [ ] **Step 5: Implement the UI** in the existing ink-and-ember language: left wing shows recorder health dot and "recorder ok/down"; header counters (sessions · agents · +today) that count up on open; one row per agent (name, last title, project, relative age); ↑/↓ select; Return opens `obsidian://open?path=<url-encoded note path>`; ⌘Return sends the note's text to Gemma via the existing gateway path and streams a three-line summary into the panel; `/` switches the field to search using `VaultReader.search`. Same pill-open animation as the prompt view; rows stagger in (one authored motion, ease-out). Esc / click-away close as in the prompt view.
- [ ] **Step 6: Visual check:** relaunch, press ⌥⇧Space, capture one batched screenshot round (empty vault state and populated state), fix everything found in one batch.
- [ ] **Step 7: Commit** (`feat(notch): recall view`).

---

## Self-review notes

- Spec coverage: recorder/backfill (T3-4), redaction (T1), vault layout and indexes (T2), mirror and RAG (T7), MCP (T5), digest (T6), notch recall incl. health, last-per-agent, ask Gemma, search (T8), phase 2 explicitly out of scope.
- Types consistent across tasks: `Turn`, `SessionMeta`, `Adapter.parse` return shape, `Hit`, `VaultSnapshot`.
- Review Focus items 1-7 each have a named test in the owning task (1→T3, 2→T4, 3→T1, 4→T2, 5→T4, 6→T5/T8, 7→T5).
