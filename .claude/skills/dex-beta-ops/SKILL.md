---
name: dex-beta-ops
description: Run the Dex Notch closed beta day to day: invite people from the waitlist, check who is stuck, send the lock-your-vault reminder, and explain the tester's flow. Use when asked about testers, invitations, the waitlist, or why someone cannot sign up.
---

# Run the closed beta

Service: <https://vault.dextron04.in>, invite-only, capped by `--max-users` (20). Only the owner's account can open `/admin` (404 for everyone else).

## Inviting someone

- **From the web (normal):** the owner signs in, opens `/admin`, and presses **Invite** next to a waiting address (or **Invite everyone waiting**, or types an address). That adds the address to the allowlist and emails the download link, the sign-in link and the five setup steps.
- **From the terminal:** `sudo -u _dexhosted env PYTHONPATH=/var/dexhosted/app /opt/homebrew/bin/python3 -m agentvault.hosted invite --root /var/dexhosted/data EMAIL` (also `invites`, `uninvite`).
- Inviting is outward-facing: **never send invitations or other email yourself without the owner saying so.** Preparing the list is fine.
- See the waitlist: `/admin`, or `sudo -u _dexhosted sqlite3 -header -column /var/dexhosted/data/hosted.db "select email,note,datetime(created,'unixepoch') joined,invited_at is not null invited from waitlist order by created"`.

## What a tester goes through (so you can help them)

Invitation email -> download and **Open Anyway** (not notarized) -> welcome window -> **Continue in browser** -> sign in with the invited email by emailed link -> check the code -> **lock the vault** (Touch ID or a passphrase) and keep the recovery code -> **Add this Mac** -> Dex Notch starts the recorder and uploads history -> Settings -> Memory -> **Get started** (connect Claude, connect ChatGPT) -> first conversation: remember something in one assistant, find it from the other. Full text: `docs/install.md`. The account page checklist and the app's Get started card tick off from the server's progress marks (`uploaded`, `assistant_used`).

## When someone is stuck

| Symptom | Likely cause and fix |
|---|---|
| "closed beta" message | The email they used isn't invited. Invite that exact address. |
| No sign-in email | Check spam; `by_email` limit is 3 per 15 min; check the SMTP flags with `mail-test`. |
| Mac keeps returning to the sign-in window | It was linked before the vault was locked, or removed on the account page. Sign in again. |
| Nothing uploads | App -> Settings -> Memory -> Record my conversations must say Recording; needs Python 3.9+ (`xcode-select --install`). |
| Assistant says unauthorized | Re-add the connector; connectors from before the vault was locked need re-adding. |
| Forgot passphrase | Recovery code or passkey. Nobody, including us, can recover notes without one of them. |
| Their vault is not locked | `/admin` -> **Vaults not locked yet** -> **Email them** (once a week at most), or `remind-vaults`. |

Ask them for **Settings -> Memory -> Copy diagnostics** (setup facts only, no email or conversation text).

## Checks

- `scripts/verify-hosted.sh` after any deploy.
- `cd memory && python3 -m unittest tests.test_hosted_beta_flow` is the whole tester journey against a local server: run it after any change to sign-in, vaults, linking, the connector or the account page.

## Privacy

Never read or quote a tester's notes. Treat the waitlist and invitation lists as private. Do not put emails in commits, issues or the public repo.
