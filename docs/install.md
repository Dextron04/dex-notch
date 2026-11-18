# Install Dex Notch

This is the whole path for a closed-beta tester, from invitation to your first conversation that uses your memory. It takes about ten minutes. If something doesn't match what you see, jump to [Troubleshooting](#troubleshooting).

**What you need**

- A Mac on **macOS 14 or later** (Apple silicon or Intel).
- An **invitation**. Ask for one on the waitlist at <https://vault.dextron04.in/waitlist>; you'll get an email when there is room.
- **Python 3.9 or later**, only for recording your terminal conversations. Most developer Macs already have it. If yours doesn't, Dex Notch tells you to run `xcode-select --install`.
- A **Claude** or **ChatGPT** account to connect, and optionally Claude Code, Codex or Gemini on the Mac.

## 1. Download and open the app

1. Download `dex-notch-vX.Y.Z.dmg` from the [latest release](https://github.com/Dextron04/dex-notch/releases/latest) and drag **Dex Notch** into **Applications**.
2. Open it once. This beta isn't notarized yet (that needs a paid Apple Developer ID), so macOS says it can't verify the app. Allow it:
   - **macOS 15 or later:** System Settings → Privacy & Security → scroll down → **Open Anyway** next to Dex Notch.
   - **macOS 14:** right-click the app and choose **Open**.
   - **Any version, from Terminal:** `xattr -dr com.apple.quarantine "/Applications/Dex Notch.app"`
3. This step is only needed the first time. Updates come from inside the app and don't ask again.

## 2. Create your account

1. A **Welcome to Dex Notch** window opens. Leave **Keep my AI conversations in my account** on if you want the memory to work (it is what the service is for). Read the small print beside it: conversations are uploaded with passwords and keys removed, and encrypted on the server, but not end-to-end.
2. Press **Continue in browser**. Your browser opens a page and the window shows an 8-character code.
3. Sign in with **the email address your invitation went to**. You get a one-time link by email (no password). Open it and press the button on the page.
4. **Check that the code on the page matches the one on your Mac**, then continue.

## 3. Lock your vault

Before your Mac can be added, the page asks you to lock your vault. This encrypts your saved conversations with a key only you can open.

- **Touch ID or a passkey (easiest):** press **Use Touch ID or a passkey instead**. A touch signs you in and opens your vault from then on.
- **Passphrase:** choose one of at least 10 characters (three or four unrelated words is easy to remember).

You are then shown a **recovery code once**. Put it in your password manager or print it. It is the only way back in if you lose your passkey or passphrase, and nobody, including the person who runs the service, can recover your notes without it.

> What this does and doesn't do: your notes are encrypted on the server's disk, so a stolen backup or disk is unreadable. It is **not end-to-end encrypted**: while you or an assistant you approved is using your memory, the service opens the notes to search them. [PRIVACY.md](../PRIVACY.md) says exactly what is kept.

## 4. Add this Mac

Back on the approval page, press **Add this Mac** (it asks for your passphrase or a touch if you haven't signed in with a passkey). Go back to Dex Notch: it finishes by itself and shows **You're in**.

Within a few seconds Dex Notch starts a small helper in the background that watches for new Claude Code, Codex and Gemini conversations, saves them to `~/Vault` as plain markdown notes (with passwords and API keys removed), and uploads them to your account. It also imports your existing history once.

- See or stop it: **Settings → Memory → Record my conversations** (menu bar icon → Settings).
- If it says it needs Python, run `xcode-select --install` in Terminal and press **Start recording** again.
- Turn uploads off at any time with **Keep my conversations in my account**. Nothing is uploaded while it is off.

## 5. Connect Claude and ChatGPT

**Settings → Memory → Get started** always shows the next thing to do. You can also use the **Connections** list there, or your account page at <https://vault.dextron04.in/account>.

- **Claude (and Claude Code):** press **Add in Claude**. Claude opens with *Dex Memory* and its address already filled in; confirm it, sign in with the same email, and press **Allow**. Claude Code on your Mac uses the connectors on your Claude account, so it picks this one up too.
- **ChatGPT (and Codex):** press **Connect**. ChatGPT's steps open in your browser: Settings → Connectors → create a connector (it may ask you to turn on developer mode), paste the address from the page, choose **OAuth**, sign in, and press **Allow**. If Codex is installed, the same button adds Dex Memory to Codex and opens its sign-in in your browser, because ChatGPT on the web doesn't pass connectors on to Codex. Claude Code and Codex sign in through your own Mac, so the sign-in page says "on this Mac".

Each assistant shows a sign-in page on this site. If your vault is locked with a passphrase it asks for it; with a passkey it asks for a touch.

## 6. Have your first conversation

1. In Claude or ChatGPT, paste:

   > Remember this for me: I'm trying out Dex Memory, and my favorite color is amber.

2. Open a **new** chat, in the same assistant or the other one, and paste:

   > Search my Dex memory: what did I say my favorite color was?

If it answers "amber", everything works end to end. Your account page and **Settings → Memory → Get started** tick this step off by themselves.

Then try it with real work: have a conversation in Claude Code, Codex or Gemini, wait about a minute, and ask ChatGPT *"what did I work on in Claude Code today?"*

### Make every conversation save itself (optional)

**Settings → Memory → Save every conversation** adds a short instruction to the global files that Claude Code, Codex and Gemini read, so they save a summary when a conversation ends. For ChatGPT and Claude on the web, copy the same text from the [Connect page](https://vault.dextron04.in/connect#save) into Custom instructions or personal preferences. An assistant decides for itself when a conversation is over, so you can always say *"save this to my memory"*.

## Everyday use

- **`⌥ Space`** opens the notch to ask a question; **`⌥ ⇧ Space`** opens recall of your past conversations.
- Reminders you ask an assistant for ("remind me to call mum at 9") appear at the notch.
- Optional alerts for Gmail, Outlook and iPhone notifications are in Settings. See the [README](../README.md).
- Updates arrive in the background; the menu bar mark gets a dot when one is ready to restart into.

## Troubleshooting

| What you see | What to do |
|---|---|
| macOS says the app "can't be verified" | [Step 1](#1-download-and-open-the-app): **Open Anyway**, or right-click → Open. |
| "This address isn't on the list yet" | Use the same email your invitation went to, or ask on the waitlist again. |
| The welcome window never moves on | Check the code on the page matches, and that you pressed **Add this Mac**. The code expires after 10 minutes: press **Start over**. |
| Dex Notch returns to the sign-in window | The server no longer recognises this Mac (you removed it, or locked your vault after linking it). Sign in again; nothing is lost. |
| Nothing is uploading | Settings → Memory → **Record my conversations** must say *Recording*. Also check that **Keep my conversations in my account** is on. |
| "Needs Python" | Run `xcode-select --install`, then press **Start recording**. |
| Claude or ChatGPT says unauthorized or asks you to sign in again | Press **Connect** again in Settings → Memory, or remove the old Dex connector in the assistant first. Connectors added before you locked your vault must be re-added once. |
| Codex or Claude Code says "registration failed" or "redirect_uri not allowed" | Update to Dex Notch 0.9.1 and make sure the server is current: earlier servers refused the local sign-in these tools use. |
| The status says "couldn't check" | It couldn't reach the server or run `claude` or `codex` just then. Press **Check again**; it keeps the last good answer and tries again at the next check. |
| The old Dex connector still shows | Remove it in the assistant's Connectors list and add the new one. |
| "That passphrase isn't right" | Eight wrong tries pause sign-in for 15 minutes. Use your passkey or your recovery code instead. |
| iPhone alerts stopped after an update | macOS asks for **Full Disk Access** again after each update of this beta (a signed release will fix that). Settings → iPhone shows the steps. |

Still stuck? **Settings → Memory → Copy diagnostics**, then **Report a problem**. Diagnostics contain setup facts only (version, what is on, when the server last confirmed this Mac), never your email, passwords or conversations.

## Uninstall

1. Settings → Memory → **Record my conversations → Turn off**, then **Sign out**.
2. On your account page, **Delete my account** (this erases your notes on the server), or **Download my data** first.
3. Quit Dex Notch and drag it to the Trash.
4. Optional leftovers: `rm -rf "$HOME/Library/Application Support/Dex Notch" "$HOME/Library/Application Support/NotchApp"`, `rm ~/Library/LaunchAgents/in.dextron04.agentvault.plist`, and your local notes in `~/Vault` if you don't want them. The saved sign-in key is in Keychain Access under `dex-notch-hosted`.

## Build it from source

```bash
brew install xcodegen
git clone https://github.com/Dextron04/dex-notch && cd dex-notch
xcodegen generate
xcodebuild test -project NotchApp.xcodeproj -scheme NotchApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
open NotchApp.xcodeproj
cd memory && python3 -m unittest discover -s tests          # the recorder and the hosted service
```

The recorder is bundled into the app by a build step. Developers who already run the recorder from a checkout (`cd memory && sh install.sh`) keep it: the app notices and leaves it alone.

## Run your own server

The hosted service is plain Python (standard library only) and open source in `memory/agentvault/hosted`. A single small machine is enough for a handful of people.

- Start from [docs/hosted-operations.md](hosted-operations.md) (flags, invitations, backups, sign-in email) and [docs/hosted-isolation.md](hosted-isolation.md) (running it as its own user, which you should).
- Serve it only behind HTTPS (a tunnel such as Cloudflare Tunnel works), and point `--public-url` at that address: passkeys and the sign-in links depend on it.
- Point the app at your server in `settings.json` (`"hosted": {"host": "your.host"}`).
- `SECURITY.md` says how to report a problem and what is and isn't protected.
