# Security

Dex Notch keeps your conversations. This file says how to report a problem, and what we do and don't promise.

## Report a problem

Use **private vulnerability reporting**: <https://github.com/Dextron04/dex-notch/security/advisories/new>. Please don't open a public issue for a security problem, and don't test against other people's accounts or data. Use your own account.

We will answer within three days, tell you what we found, and credit you if you want. There is no bounty yet.

## What is protected, and how

- **Notes are encrypted on the server's disk** with a key made for each account. The key is never stored as is: it is kept wrapped under your passphrase, your passkey, your recovery code, and the tokens of the Macs and assistants you approved. A copy of the disk, the database or a backup can't be read without one of them.
- **Sign-in** is by emailed one-time link or by passkey (Touch ID). Passkey sign-in checks a signature from your device over a fresh challenge, for this site only.
- **Tokens** (device, assistant, session) are random and stored only as hashes. Assistants use OAuth with PKCE and rotating refresh tokens.
- **The website** sends a strict content-security policy (no inline scripts, no third-party scripts), HSTS, and no analytics or advertising.
- **Isolation:** the service runs as its own macOS account on its own data folder; one account can't reach another's notes.

## What is not protected

- **Not end-to-end encrypted.** To search your notes the service opens the key for the length of a request, so whoever controls the running service could read notes then. See [PRIVACY.md](PRIVACY.md).
- Note names (which assistant, which month, which project) are readable on disk.
- Secrets in conversations are removed by pattern matching, which can't catch everything.
- The service runs on one machine run by one person. It has had no independent security audit.

## Local secrets

On your Mac, Dex Notch keeps the mail and device tokens it needs (Gmail and Outlook sign-in, the token that links the Mac to your vault) through the `/usr/bin/security` command, in your login Keychain. It does that so a new build, which is ad-hoc signed and so has a different identity every time, doesn't ask for your Keychain password after each update. The cost: **any program running as you can read those tokens the same way.** The Keychain isn't protecting them from other software on your account.

Per-app Keychain protection, where only Dex Notch itself can open its items, is planned for when the app is signed with an Apple Developer ID. Until then, treat a Mac where you run untrusted software as able to read your mail tokens, and revoke them from the Google or Microsoft account page, or Settings, if you suspect it.

## What the AI models can reach

Questions you type run the `claude` or `codex` command-line tools on your Mac, signed in as you. They can also read web pages and, when a page or an email is hostile, be told to misbehave (prompt injection). So the notch limits them:

- **Ask mode** (`@claude`, the default): can read only Dex Notch's own scratch folder, search the web and fetch pages, and use your memory vault if you have set it up. It can't run commands or edit anything. Reading anywhere else, and in particular `~/.ssh`, `~/.aws`, `~/.config`, `~/.gnupg`, `~/Library/Keychains`, `~/.netrc`, `~/.claude.json` and `~/.codex/auth.json`, is refused. Your own Claude settings, hooks and other connected tools (a mail sender, say) are not loaded for these runs.
- **Work mode** (`@claude+`, `@codex+`): reads and edits inside the scratch folder and the one folder you choose, and shell commands inside the operating system's sandbox (writes only there, no network). Claude's Work mode has **no web tools**: fetching a page runs outside that sandbox and could carry out whatever a shell had read, so lookups belong to Ask mode. The sandbox refuses reads of a fixed list only: `~/.ssh`, `~/.aws`, `~/.config` (which covers `gh`), `~/.gnupg`, `~/.netrc`, `~/.npmrc`, `~/.git-credentials`, `~/.pypirc`, `~/.docker`, `~/.kube`, `~/.cargo/credentials`, `~/.zsh_history`, `~/.bash_history`, `~/Library/Keychains`, `~/Library/Messages`, `~/Library/Mail`, `~/Library/Cookies`, `~/Library/Safari`, the Chrome and Brave profiles under `~/Library/Application Support`, `~/.claude.json`, `~/.claude/.credentials.json` and `~/.codex/auth.json`. Anything else your account can read, a Work-mode shell can read; it just can't send it anywhere. The scratch folder is also cleaned before each run (symlinks and planted instruction files removed).
- **Codex** runs in its own read-only or workspace-write sandbox, which can still read files anywhere your account can; Codex has no path rules like the above, so its reads are not narrowed. Prefer Claude for questions that touch untrusted pages.
- **Background mail triage** runs with no tools at all, in a new empty folder each time, and for Codex with a throwaway config that has no connected tools. Replies are always written for you to read and send yourself, to exactly one address that is shown in full.
- **Still possible:** fetching a web page can carry what the model has already read (your question, notes it looked up from your vault) to a site, because web access can't be limited to chosen sites. Don't ask it to look up something secret while it is reading pages you don't trust.
- Links in answers open only if they are `http` or `https`, with the real site name shown next to the text.

## Scope

The hosted service at `vault.dextron04.in`, the Mac app in this repository, and the website. Reports about third-party services (Cloudflare, Resend, Google, Microsoft, Anthropic, OpenAI) belong with them.
