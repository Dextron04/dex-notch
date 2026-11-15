# Privacy

Dex Notch runs on your Mac. It has no server and no account, and the project collects nothing about you.

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

## Updates

Once a day Dex Notch asks `github.com` for the list of releases (a small file named `appcast.xml`) to see whether a newer version exists. That is an ordinary HTTPS request, so GitHub sees your IP address and the app's version like it would for any download. Nothing else is sent: no system profile, no account, no mail, no chats. A new version is only installed if it carries a signature that matches the key built into the app, and it only restarts the app after you say so. You can turn automatic checks off in Settings → Updates.

## Everything else

Your questions go to the model you pick, through its own app or your own server. The shared memory (the recorder) is a folder of notes on your Mac; it is only reachable from outside if you set up the optional remote connector yourself.

Questions: open an issue at <https://github.com/Dextron04/dex-notch/issues>.
