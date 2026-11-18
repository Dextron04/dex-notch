
---

### Install

1. Download **`dex-notch-@TAG@.dmg`** below and drag **Dex Notch** into Applications.
2. **Open it once.** This build is ad-hoc signed but not notarized (that needs a paid Apple Developer ID), so macOS says it can't verify the app. To allow it:
   - **macOS 15 and later:** open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Dex Notch.
   - **macOS 14:** right-click the app and choose **Open**.
   - **Any version, from Terminal:** `xattr -dr com.apple.quarantine "/Applications/Dex Notch.app"`
3. A welcome window asks you to create an account (it needs an invitation during the closed beta). Follow it: sign in in your browser, lock your vault, and Dex Notch starts recording by itself. A short setup window then picks your AI and the folders it may use.
4. Press **`⌥ Space`** to ask a question, and see **Settings → Memory → Get started** for what to do next.

Requires macOS 14 or later, Apple silicon or Intel. `SHA256SUMS.txt` has the checksums. The [install guide](https://github.com/Dextron04/dex-notch/blob/master/docs/install.md) walks through sign-up, locking your vault, connecting Claude and ChatGPT, and your first conversation; the [README](https://github.com/Dextron04/dex-notch#readme) covers the rest, and [PRIVACY.md](https://github.com/Dextron04/dex-notch/blob/master/PRIVACY.md) says exactly what is read and what is not.
