
---

### Install

1. Download **`dex-notch-@TAG@.dmg`** below and drag **Dex Notch** into Applications.
2. **Open it once.** This build is ad-hoc signed but not notarized (that needs a paid Apple Developer ID), so macOS says it can't verify the app. To allow it:
   - **macOS 15 and later:** open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Dex Notch.
   - **macOS 14:** right-click the app and choose **Open**.
   - **Any version, from Terminal:** `xattr -dr com.apple.quarantine "/Applications/Dex Notch.app"`
3. A setup window opens. Pick Claude or Codex (install one first if you have neither), choose where it may work, and press **Save**.
4. Press **`⌥ Space`**.

Requires macOS 14 or later, Apple silicon or Intel. `SHA256SUMS.txt` has the checksums. The [README](https://github.com/Dextron04/dex-notch#readme) has the full guide, and [PRIVACY.md](https://github.com/Dextron04/dex-notch/blob/master/PRIVACY.md) says exactly what is read and what is not.
