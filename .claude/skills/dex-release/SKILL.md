---
name: dex-release
description: Cut a Dex Notch release (tag, build, publish). Use when asked to release, tag, or ship a version of the Mac app.
---

# Cut a release

A tag `vX.Y.Z` triggers `.github/workflows/release.yml`: it builds the universal ad-hoc-signed DMG and zip, signs the update with Sparkle, and publishes a GitHub release whose notes are that version's section of `CHANGELOG.md` (via `scripts/release-notes.sh`).

## Before tagging

1. **CHANGELOG.md has a `## vX.Y.Z: title` section with a date**, newest first. The release build fails without it. Write it for people, not for developers: what they can now do, what changes for them, anything they must redo.
2. **Screenshots and GIFs are required for every entry** (the owner's standing rule). Put them in `docs/assets/` and reference them as `docs/assets/...` (the release script rewrites them to absolute URLs pinned to the tag).
   - Website pages: record with headless Chrome and the DevTools protocol (Page.captureScreenshot / Page.startScreencast), on a throwaway profile. **Never screen-record the owner's display**: it can show other apps' private content.
   - GIFs: keep them near 2 MB (about 6 s, 7 fps, 600 px, 32 colors) and add an MP4 link beside them. Particle-heavy scenes compress badly.
   - Mac app screens need a build installed against the deployed server and a demo account, so the owner's email never appears.
3. `git status` clean except known untracked files; `CI` green on the commit you will tag (`gh run list`; `gh run watch <id> --exit-status` in the background).
4. Server changes the app depends on are **deployed first** (see the dex-deploy skill), otherwise users on the new app meet an old server.

## Tag

```
git tag vX.Y.Z && git push origin vX.Y.Z
```

Then wait for the `Release` run and confirm the assets: `gh release view vX.Y.Z --json assets -q '[.assets[].name]'` should list the `.dmg`, `.zip`, `appcast.xml` and `SHA256SUMS.txt`. Macs on older versions update within a day.

## Rules

- Commit, push and tag only when the owner asks. No Claude co-author or attribution lines.
- The build is not notarized; the install steps in `docs/release-install.md` explain Open Anyway. Full Disk Access resets after each update until there is a Developer ID.
- Update `docs/install.md` when the first-run flow changes.
