# Privacy

Dex Notch runs on your Mac. By default it has no server and no account, and the project collects nothing about you. The one exception is the optional hosted memory service, described below, which exists only if you connect it.

## Gmail (optional add-on)

If you connect Gmail:

- **What it asks Google for:** read-only access to your mail (`gmail.readonly`). On its own it cannot send, delete or change anything.
- **What it reads in the background:** for unread inbox mail from the last three days, the sender, subject, a short snippet and a few labels. It does not download message bodies or attachments to look for mail that needs you.
- **Replying needs one more permission, which you can decline.** When you connect an account, Dex Notch also asks Google for `gmail.compose`, which lets it create drafts and send mail. It only does either when you press **Save draft** or **Send**. Turn **Allow replies** off in Settings → Mail and new accounts stay read-only; you can allow replies for an account later.
- **When you ask for a reply or a question about one email,** that one email is read in full (the text, not attachments) and given to the AI agent you picked so it can write a draft or answer. Nothing else in your mailbox is read for this. Nothing is sent until you press **Send**, and you get a few seconds to Undo; **Save draft** puts it in your Gmail drafts instead. The recipient and subject come from the original email, never from the AI.
- **Where that goes:** the sender, subject and snippet are given to the AI model you chose (Claude or Codex through their own command-line apps on your Mac, or the model on your own server) so it can decide which mail needs you. Those models run without tools, and their sessions are not saved to the shared memory. What each provider does with that text is covered by your account with them.
- **What is stored on your Mac:** a sign-in token in your login Keychain, the ids of mail already looked at, senders you muted, and the few alerts waiting to be shown, in `~/Library/Application Support/NotchApp/addons.json` (readable only by you). Nothing is uploaded anywhere else.
- **Disconnecting:** remove Dex Notch at <https://myaccount.google.com/permissions>, and delete the Keychain item `dex-notch.gmail`. Deleting `addons.json` clears the rest.

Dex Notch's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## Outlook and Microsoft 365 (optional add-on)

Works like Gmail, with Microsoft instead of Google:

- **What it asks Microsoft for:** `Mail.Read` to see new mail, plus `Mail.ReadWrite` and `Mail.Send` so it can create drafts and send a reply, but only when you press **Save draft** or **Send** (turn **Allow replies** off in Settings → Mail and new accounts ask for read access only). `offline_access` keeps you signed in, and `User.Read` tells it which address you signed in as.
- **What it reads in the background:** for unread inbox mail from the last three days, the sender, subject and a short preview, and whether Outlook filed it under *Other* or marked it as a mailing list. Message bodies and attachments are not downloaded to look for mail that needs you.
- **Everything else is as for Gmail:** one email is read in full only when you ask to reply to it or ask about it, the sender, subject and preview go to the AI model you chose, and nothing is sent without your Send. Replies are sent from the original message, so the recipient and subject come from it, never from the AI.
- **What is stored on your Mac:** a sign-in token in your login Keychain (`dex-notch.outlook`), and the same small file as for Gmail.
- **Disconnecting:** remove Dex Notch at <https://account.live.com/consent/Manage> (personal accounts) or <https://myapps.microsoft.com> (work or school), and delete the Keychain item `dex-notch.outlook`.

## iPhone notifications (optional, off by default)

If you switch it on:

- **What it reads:** Notification Center's own database on your Mac (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), read-only, to find new notifications that your iPhone sent to the Mac through iPhone Mirroring. macOS only allows that with **Full Disk Access**, which you grant yourself in System Settings. That permission is broad, so it is asked for only when you switch this on, and you can withdraw it at any time.
- **What it keeps:** only a bookmark (the number of the newest notification already seen), and the few cards waiting to be shown, in `addons.json`. Old notifications are never shown, and the text of notifications is not kept after you dismiss a card, apart from the short recent-alerts list.
- **Where it goes:** nowhere. There is no AI model and no network request involved. Notification text stays on your Mac.
- **Turning it off:** the switch in Settings → iPhone. Remove Full Disk Access for Dex Notch in System Settings if you no longer want the permission at all.

## Hosted memory (optional, off until you connect it)

An optional Dex account keeps your recorded AI conversations on a server so Claude and ChatGPT can search them from anywhere. Nothing is uploaded unless you sign in to a Dex account in the welcome window and leave **Keep my AI conversations in my account** on (change it in Settings → Memory).

- **What is uploaded:** the conversations the recorder has written on your Mac (Claude Code, Codex, Gemini and any other agent it records): the text of your messages, the assistant's replies, tool-use lines, project names and folder paths. The recorder removes passwords and API keys when it writes a note, and the server removes them again before storing. That is pattern-based and cannot catch everything, so don't rely on it for secrets. The first connection uploads your whole history; after that, only new turns.
- **What we keep about you:** your email address; for each passkey, its public key and a name (never the passkey itself, which stays in your device); (and, if you asked for an invite, your waitlist entry with the optional note you wrote; deleting your account erases it); when you signed in; the names you gave your Macs; a hashed copy of each device token (the token itself is shown once and kept only in your Keychain); and your plan status. When paid plans open, payments are handled by Stripe: we store Stripe's customer and subscription ids, never card numbers.
- **Who can read your notes:** you lock your vault as the first step after signing up, with a passkey (or a passphrase), and nothing else on your account works until you have. Your notes are encrypted on the operator's disk with a key that only your passphrase, your passkey (Touch ID) or your recovery code can open, so a copy of the disk, a backup or the database cannot be read without one of them. They are protected in transit by HTTPS. They are **not end-to-end encrypted**: while a Mac or an assistant you approved is using your memory, the service opens the notes for that request, as it has to in order to search them, so whoever controls the running service could capture them at that moment. The names of notes (the assistant, the month, the project and a short id) are not encrypted. If you lose both your passphrase and your recovery code, nobody can recover your notes. Other users cannot see them. Claude or ChatGPT can search and add to them only after you approve the connector, and what those apps do with what they read is covered by your account with them.
- **Services involved:** the network provider that carries traffic to the server (Cloudflare), the email provider that delivers your sign-in, invitation and welcome emails (Resend), and Stripe for payments (once paid plans open). No analytics or advertising of any kind.
- **Your controls:** on your account page you can see your Macs and remove one (it stops uploading at once), sign out everywhere, **Download my data** (a zip of every note), and **Delete my account**, which cancels your subscription first and then permanently erases your notes, devices and sign-ins. Backups made before a deletion are overwritten within 14 days. Disconnecting in Settings → Memory stops uploads from this Mac but does not delete what was uploaded.
- **If you stop paying:** your notes stay available for export. Canceled accounts are erased periodically, no sooner than 30 days after the subscription ended; download your data before then.
- **Limits:** 100 MB of notes per free account (500 MB on a paid plan, when those open).

## Updates

Once a day Dex Notch asks `github.com` for the list of releases (a small file named `appcast.xml`) to see whether a newer version exists. That is an ordinary HTTPS request, so GitHub sees your IP address and the app's version like it would for any download. Nothing else is sent: no system profile, no account, no mail, no chats. A new version is only installed if it carries a signature that matches the key built into the app, and it only restarts the app after you say so. You can turn automatic checks off in Settings → Updates.

## Everything else

Your questions go to the model you pick, through its own app or your own server. The shared memory (the recorder) is a folder of notes on your Mac; it is only reachable from outside if you set up the optional remote connector yourself, or connect the hosted memory service above.

Questions: open an issue at <https://github.com/Dextron04/dex-notch/issues>.
