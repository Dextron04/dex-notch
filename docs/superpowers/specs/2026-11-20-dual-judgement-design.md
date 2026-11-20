# Dual judgement

## Intent
Pick "Both" on the dial: Claude and ChatGPT (`codex` CLI) each answer, judge each other, and together produce one hybrid answer holding the best of both. The user always sees which stage is running.

## Goals
- Hybrid final answer: everything one answer got right that the other missed ends up in the final, not just the winner's text.
- Live stage status in the notch status line: Answering → Judging → Drafting → Reviewing.
- A one-line verdict under the final answer.

## Non-goals / anti-goals
- No `+` (edit) mode in dual: two agents writing the same files conflict. Dual is always read-only.
- No draft file on disk. The draft lives in memory (nothing to clean up, nothing left behind on a crash).
- Not available unless both CLIs are installed.

## Approaches
- **A. One writer.** Both answer, both judge, preferred one writes the final. 5 runs. Rejected: the other agent never sees the merged result.
- **B. Writer + review (picked).** A, plus the other agent reviews the draft and returns it approved or corrected. 6 runs, ~1–2 min.
- **Shared `response.md` both edit** (user's idea). Same outcome as B, but needs write access and leaves a temp file if the app dies. Kept the idea, moved the draft into memory.

## Flow
1. **Answering** (parallel): each CLI answers the question independently.
2. **Judging** (parallel): each gets both answers, replies with `BETTER: claude|codex`, then lists what each answer has that the other lacks.
3. **Drafting**: the agent both preferred (tie → Claude) writes the hybrid: base on the better answer, fold in every strength listed for the other. Streams into the notch.
4. **Reviewing**: the other agent checks the draft against both originals; replies `APPROVED` or a full corrected hybrid, which replaces the draft.
5. Verdict line appended, e.g. "Both preferred Claude's; added ChatGPT's point on X."

## Decided
- Dial gets `Backend.both`, shown only when claude and codex are both found. Status line shows the stage names above.
- Follow-up questions pass the prior conversation as plain text in the prompt (no per-CLI session resume in dual mode).
- If one CLI fails in Answering, fall back to the other's answer alone with a note; failure in a later stage keeps the best draft so far.

## Left to the builder
- Exact prompt wording; verdict parsing (pure functions in `AgentStream`, unit-tested); how the verdict line is styled.
