# Screen help: ask about what's on screen, get marks drawn on it

## Goal
From the notch, ask Claude or ChatGPT (Codex) about what's on screen. The answer streams in the notch as now, and the model can point at things: boxes with short labels are drawn over the real screen until dismissed.

## User flow
1. Press the screen hotkey (⌥⌘S, next to the existing notch hotkeys), or toggle the eye chip in the prompt bar.
2. The notch captures the display it lives on *before* it opens, so the notch itself is not in the shot.
3. User types a question ("where do I change the DNS here?") and sends.
4. The screenshot is passed to the chosen backend with the prompt.
5. The answer streams as usual. Any `<mark>` tags are removed from the shown text and drawn as boxes on a click-through overlay over that display.
6. Esc, closing the notch, or the next send clears the marks. Marks fade on their own after 60s.

### More ways in (added)
- Plain words: a question containing "my screen", "on screen", "look at this", "what am I looking at", "this window/page/error"... (`ScreenMarks.wantsScreen`) captures right then, when the eye is off and the backend isn't Gemma, and turns the eye on so the screenshot is visible. Only because that message was sent.
- Eye on (or hotkey) and Enter with nothing typed sends a default "look at my screen and help, point at the relevant spots" prompt.
- Implementation notes: our own windows are excluded by ScreenCaptureKit, so the notch is never hidden for a capture. Click-away keeps marks (that is how you reach the thing marked); Esc, the hotkey toggle, a new send, new chat, or 60s clear them.

## Design

### Capture (`ScreenCapture.swift`, new)
- ScreenCaptureKit `SCScreenshotManager.captureImage` for the notch's display, excluding the app's own windows.
- Downscale so the long edge is ≤ 1568 px (what vision models see anyway), write PNG into the run's scratch folder as `screen.png`.
- Return `Shot { url, pixelSize, screenFrame }` (screenFrame = the NSScreen frame in global points, used to map marks back).
- No Screen Recording permission → `CGPreflightScreenCaptureAccess()` false → `CGRequestScreenCaptureAccess()` once, show a short error in the notch pointing at System Settings. Never crash, never capture silently without the eye chip on.

### Passing the image to the backends (`AgentStream.swift`)
- **Codex:** `codex exec ... -i <path>` (native image flag).
- **Claude:** the CLI has no image flag. Put `screen.png` in the run's cwd (scratch folder, which Read already sees) and prefix the prompt with "The user's screen is in ./screen.png (W×H px). Read it first." Make sure Read is allowed in the locked/triage arg sets for that file.
- **Gemma (local):** no vision. Eye chip disabled when Gemma is selected.
- Prompt suffix (both backends) explaining marks:
  `To point at something on the screen, write <mark x="" y="" w="" h="">short label</mark> using pixel coordinates in screen.png (origin top-left). Use at most 6 marks. Only mark things you can actually see.`

### Mark parsing (`ScreenMarks.swift`, new, pure, in the test target)
- `ScreenMarks.parse(_ text: String) -> (clean: String, marks: [Mark])`, `Mark { rect: CGRect (image px), label: String }`.
- Tolerant: attribute order free, ints or floats, ignore malformed tags (strip them from text anyway), clamp to image bounds, cap at 6.
- Streaming: hide a partial `<mark` at the end of the buffer so it never flashes in the notch.
- `ScreenMarks.toScreen(_ r: CGRect, imageSize:, screenFrame:) -> CGRect` maps image px → AppKit global points (flip Y).
- Unit tests in `NotchAppTests/ScreenMarksTests.swift`; add the file to the test target's `sources` in `project.yml`.

### Overlay (`MarkOverlay.swift`, new)
- One borderless `NSPanel` per display used, level `.screenSaver` (above apps, below the notch window), `ignoresMouseEvents = true`, clear background, `collectionBehavior` joins all spaces.
- SwiftUI content: rounded rect outline in the accent color + soft fill, label pill above the box, numbered if > 1. Fade in, pulse once, fade out on clear.
- `MarkOverlay.show(marks, on: screenFrame)`, `MarkOverlay.clear()`.

### Wiring
- `Assistant`: `seeScreen: Bool`, `shot: Shot?`, `marks`. Capture in `open()` when the screen hotkey opened it or when the chip is toggled on (captured before the notch window shows; if toggled after open, briefly hide the notch window, capture, show). Pass the shot path into `Route`. On streamed text, run the parser, show `clean`, push marks to the overlay when the turn ends (and live as complete tags arrive). Clear on close/new send/Esc.
- `NotchView`: eye chip in the prompt bar (SF Symbol `eye` / `eye.fill`), small thumbnail of the shot when on.
- `NotchApp.swift`: register the ⌥⌘S hotkey.
- Follow-up turns in the same conversation reuse the same shot unless the user re-captures (chip off/on or hotkey again).

## Out of scope (for now)
- Multi-display capture in one shot, video/continuous watching, clicking or typing on the user's behalf, OCR fallback for Gemma.

## Checks
- `ScreenMarksTests` pass (parse, malformed, partial-stream hiding, coordinate mapping incl. Retina + secondary display offset).
- Full test suite and app build pass.
- Manual: hotkey → ask "where is the Wi-Fi icon" → box lands on it, with both Claude and Codex.
