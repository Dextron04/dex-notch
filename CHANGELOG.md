<p align="center">
  <img src="docs/assets/dex-notch-logo.svg" alt="Dex Notch" width="360">
</p>

# What's new

The newest version is at the top. Every release is on the [Releases page](https://github.com/Dextron04/dex-notch/releases), where you can download it.

## v0.3.2: Reply from the notch, and alerts that wait for you

*15 November 2026*

<p align="center">
  <img src="docs/assets/shot-reply.png" alt="The reply panel: a drafted answer to Priya Nair that can be edited, tabs for Draft and Ask about this email, and Send, Save draft and Discard" width="62%">
</p>

<p align="center">
  <img src="docs/assets/reply-send.gif" alt="Press Send: the edge of the panel drains over five seconds, the draft folds into an envelope, a seal is pressed, and the envelope flies out of the notch" width="62%">
</p>

- **Nothing gets lost.** Alerts line up in the order the emails arrived, and the line is saved, so it survives a restart.
- **They wait until you are there.** If you have not touched the keyboard or mouse for two minutes, the alerts hold and show the moment you are back. If you walk away while a card is up, it goes back in the line instead of disappearing.
- **Reply from the notch.** **Reply** on a card (`⌥R`) grows it into a reply panel. An AI agent of your choice (Claude, Codex or your local model) drafts an answer you can edit directly or ask it to change ("make it shorter", "say Thursday doesn't work").
- **Ask about the email.** A second tab lets you ask what an email means or what it wants from you, without opening Gmail.
- **Sending is a small ceremony.** The edge of the panel is the clock: it drains over the five seconds you have to Undo, a comet circles it while the email goes out, then your draft folds into an envelope, a seal is pressed on, and the envelope flies out of the notch as a comet lights the edge again. (With Reduce Motion on, it just fades in sealed.)
- **Send or save, with a safety net.** **Send** waits five seconds so you can Undo; **Save draft** puts the reply in your Gmail drafts, in the same thread, to finish later. Replies thread correctly under the original.
- **The AI only writes the words.** Who it goes to and the subject come from the original email, a hostile email can't add recipients, and nothing leaves until you press Send.
- **Everyone signs in again once.** This version asks Google for a new permission, so every account connected before it has to be reconnected. Nothing is deleted: alerts for those accounts pause until you do. The next time you unlock your Mac, a card says "Reconnect Gmail to keep your alerts going" (**Reconnect** or **Later**, and it comes back daily until you have), the menu bar shows **Reconnect Gmail** and a dot, and Settings → Mail has a banner and a **Reconnect** link on each account.
- **One extra permission, and you stay in charge.** Connecting an account now also asks Google to let Dex Notch create drafts and send mail, and it only does either when you press Send or Save draft. Already connected? Settings → Mail shows which accounts can reply, with an **Allow replies** link on the rest. Prefer read-only? Turn **Allow replies** off and new accounts stay read-only. There is also a field for your name so replies are signed properly.
- **Opening the notch no longer throws a card away.** If you press `⌥ Space` to ask something while a card is up, the card steps aside and comes back after.
- **Lid closed?** With a monitor attached the Mac stays awake, and the alert appears in a notch-shaped pill at the top centre of that monitor. With no monitor the Mac sleeps, so nothing can show; your mail waits in Gmail and is read the moment you open the lid.
- **See what is waiting.** The menu shows **Show 3 waiting alerts** when some are queued, and **Settings → Mail → Recent alerts** keeps the last few you were shown, each with an **Open** link, in case you dismissed one by accident.

## v0.3.1: Updates tell you when they last looked

*15 November 2026*

- **Settings → Updates shows when Dex Notch last checked for a new version**, so you can see it is working without pressing anything.
- **What's new** now opens the notes for the version you are running, not the list of every release.
- This is the first version delivered by the new updater, which makes it the test of it.

## v0.3.0: Dex Notch updates itself

*15 November 2026*

- **No more trips to GitHub.** Once a day Dex Notch looks for a newer version and downloads it quietly in the background.
- **It always asks before restarting.** A small dot appears beside the menu bar mark, the menu offers **Restart to update**, and **Settings → Updates** has a **Restart now** link. If you just quit, the update installs on the way out.
- **It can't be tampered with.** Every update is signed, and the app refuses anything that was changed or not signed by this project.
- **Easy to turn off.** Settings → Updates has a switch, and **Check for Updates…** is in the menu bar.
- **Install this version by hand one last time.** Versions before it can't update themselves. From here on, updates arrive on their own.

## v0.2.1: Mail that comes to you

*15 November 2026*

<p align="center">
  <img src="docs/assets/alert.gif" alt="The notch opens, a thin line of light runs round its edge, and a card appears: Interview moved to Thursday 3:00 PM, with the reason underneath" width="62%">
</p>

**Dex Notch now watches your Gmail and tells you at the notch about the few emails that actually need you.** When you wake or unlock your Mac, the notch opens with two lines: what the email is, and why it matters. Everything else stays out of your way.

- **Two lines, one reason.** "Interview moved to Thursday 3:00 PM. A real person is waiting on your reply." No spam, no newsletters, no promotions.
- **Smart about what matters.** Promotions, social and forum mail are dropped first. An AI then judges what is left and only passes on what really needs you: a person waiting on you, a deadline, a meeting change, a failed payment, a delivery today. At most three at a time.
- **Tell it what you care about.** One line in Settings ("recruiters and my landlord") shapes what counts.
- **Claude first, then Codex, then your own model.** If one is out of messages or offline, the next takes over.
- **Several Gmail accounts.** Add as many as you like. The card says which one the mail came to, and **Open** goes to the right inbox.
- **New mail within minutes.** It looks every 5 minutes while your Mac is awake, and you can choose 2 minutes to 4 hours. Looking is light and free; the AI only reads mail that is new, waits a minute so a burst of mail becomes one reading, and is capped at 8 readings an hour so it never uses up your plan.
- **Three keys on the card.** `⌥↩` opens the email, `⌥⌫` says **Not important** (that sender is never shown again), `⌥esc` dismisses. They exist only while a card is on screen, so they never get in the way of typing.
- **Private by design.** Read-only access. Only the sender, subject and a short preview are read, never the message or attachments. The AI runs with no tools and leaves no record, and a hostile email can't make it do anything. See [PRIVACY.md](PRIVACY.md).

<p align="center">
  <img src="docs/assets/shot-mail.png" alt="Settings, Mail page: two Gmail accounts, how often to look, and what matters to you" width="70%">
</p>

**A cleaner Settings window.** One page at a time (**Models**, **Folders**, **Mail**) instead of one long scroll, in the same black and ember as the notch.

<p align="center">
  <img src="docs/assets/shot-settings.png" alt="Settings, Models page: Claude and Codex found, a local model optional" width="70%">
</p>

**A new name and a new look.** The app is now **Dex Notch**, with a new icon and a matching mark in the menu bar.

<p align="center">
  <img src="docs/assets/dex-notch-icon-v3.png" alt="The Dex Notch icon: three paths converging into one amber bar" width="120">
</p>

Also:

- The card's arrival is one smooth motion: the notch opens, a line of light runs round its edge, and that edge then drains over twelve seconds as the timer. Resting the pointer on the card holds it.
- The card now closes smoothly, folding back into the notch, instead of vanishing.
- Gmail's own error is shown when it says "slow down", instead of a guess.

**Coming from v0.1.0?** The app file is now `Dex Notch.app`, so delete the old `dex-notch.app` from Applications after you install this one. Your settings, chats and memory carry over.

*Version 0.2.0 was never published: its build failed on GitHub, so this release has its changes.*

## v0.1.0: The first release

*14 November 2026*

<p align="center">
  <img src="docs/assets/demo.gif" alt="Typing a question, sliding the model dial between the three models, then paging through recall" width="62%">
</p>

- **Press `⌥ Space` and the notch opens.** Ask Claude, Codex, or a model on your own server, with a dial to switch between them.
- **No API keys.** Claude and Codex run through their official command-line apps on your own subscriptions.
- **Recall** (`⌥⇧ Space`): your last chats, a heatmap of what you and your agents did, and your busiest projects.
- **One shared memory.** Every conversation with any AI lands in a searchable vault that all your agents can read, including ChatGPT and Claude.ai through an optional connector.
- **Sandboxed edits.** Claude and Codex can edit files only in folders you allow.
