# Privacy

Dex Notch runs on your Mac. It has no server and no account, and the project collects nothing about you.

## Gmail (optional add-on)

If you connect Gmail:

- **What it asks Google for:** read-only access to your mail (`gmail.readonly`). It cannot send, delete or change anything.
- **What it reads:** for unread inbox mail from the last two days, the sender, subject, a short snippet and a few labels. It never downloads message bodies or attachments.
- **Where that goes:** the sender, subject and snippet are given to the AI model you chose (Claude or Codex through their own command-line apps on your Mac, or the model on your own server) so it can decide which mail needs you. Those models run without tools, and their sessions are not saved to the shared memory. What each provider does with that text is covered by your account with them.
- **What is stored on your Mac:** a sign-in token in your login Keychain, the ids of mail already looked at, senders you muted, and the few alerts waiting to be shown, in `~/Library/Application Support/NotchApp/addons.json` (readable only by you). Nothing is uploaded anywhere else.
- **Disconnecting:** remove Dex Notch at <https://myaccount.google.com/permissions>, and delete the Keychain item `dex-notch.gmail`. Deleting `addons.json` clears the rest.

Dex Notch's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## Updates

Once a day Dex Notch asks `github.com` for the list of releases (a small file named `appcast.xml`) to see whether a newer version exists. That is an ordinary HTTPS request, so GitHub sees your IP address and the app's version like it would for any download. Nothing else is sent: no system profile, no account, no mail, no chats. A new version is only installed if it carries a signature that matches the key built into the app, and it only restarts the app after you say so. You can turn automatic checks off in Settings → Updates.

## Everything else

Your questions go to the model you pick, through its own app or your own server. The shared memory (the recorder) is a folder of notes on your Mac; it is only reachable from outside if you set up the optional remote connector yourself.

Questions: open an issue at <https://github.com/Dextron04/dex-notch/issues>.
