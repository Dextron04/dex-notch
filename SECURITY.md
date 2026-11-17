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

## Scope

The hosted service at `vault.dextron04.in`, the Mac app in this repository, and the website. Reports about third-party services (Cloudflare, Resend, Google, Microsoft, Anthropic, OpenAI) belong with them.
