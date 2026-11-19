import SwiftUI
import Observation
import Carbon.HIToolbox
import os

/// Runs the add-ons: checks on a schedule, keeps the queue of things worth your attention, and hands them to the notch
/// only when you are actually at the machine (screen awake and unlocked, notch not already in use).
@MainActor @Observable
final class AddonCenter {
    static let shared = AddonCenter()
    static let dwell: Double = 12          // seconds a card stays up

    // what the notch draws
    private(set) var current: AddonAlert?
    private(set) var streakTick = 0        // bumps once per arrival: the comet round the rim
    private(set) var presenting = false    // the shell is open
    private(set) var shown = false         // the words are visible
    private(set) var progress = 1.0        // 1 → 0 over `dwell`; paused while the pointer is on the card
    var hovering = false
    var queued: Int { max(state.pending.count - 1, 0) }

    // what Settings shows
    private(set) var status = "Not connected."
    private(set) var checking = false
    private(set) var phoneStatus = ""
    var accounts: [String] { state.accounts }
    /// Bump when a new release asks for more permission: every account then has to sign in again.
    static let consentVersion = 2
    var needsReconnect: [String] { state.stale }
    var connected: Bool { !state.accounts.isEmpty }
    private(set) var settings = AddonSettings()

    /// The window listens so it can let clicks through everywhere except the card.
    var onPresenting: ((Bool) -> Void)?
    /// The reply panel needs the keyboard: the window listens so it can take focus while it is open and let go after.
    var onReply: ((Bool) -> Void)?

    // replying
    private(set) var session: ReplySession?
    private(set) var replyOpen = false
    private(set) var sealTick = 0          // bumps once when a reply has gone: the seal lap of light round the panel
    private var resumeRequested = false
    private var sendTask: Task<Void, Never>?

    private var state = AddonState()
    private var assistant: Assistant?
    private var clients: [String: any MailProvider] = [:]
    private var locked = false
    private var forceDemo = false          // the demo ignores "are you at the keyboard"
    private var retiring = false
    private var cardKeys: [Hotkey] = []     // ⌥↩ ⌥⌫ ⌥esc, registered only while a card is up
    private var timer: Timer?
    private var countdown: Task<Void, Never>?
    private let settingsURL = Settings.defaultURL
    private let stateURL = AddonState.defaultURL

    func start(assistant: Assistant) {
        self.assistant = assistant
        state = AddonState.load(from: stateURL)
        state.applyConsent(current: Self.consentVersion); state.save(to: stateURL)
        reload()
        queueReconnectCard()
        migrateLegacyAccount()
        AppUpdater.shared.onFound = { [weak self] v in self?.updateFound(v) }
        let dn = DistributedNotificationCenter.default(), ws = NSWorkspace.shared.notificationCenter
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = false; self?.welcomeBack() } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.welcomeBack() } }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.welcomeBack() } }
        // lid closed onto an external display, or a display plugged in: the notch moves, and the queue follows it
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.welcomeBack() } }
        // alerts wait for you: this is what shows them the moment you are back at the keyboard
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchPhone(); self?.pollPhone(); self?.checkReminders(); self?.presentIfPossible() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.pollPhone(); self?.tick(); self?.presentIfPossible() }
        if ProcessInfo.processInfo.environment["NOTCH_ALERT_DEMO"] != nil { forceDemo = true; demo() }
    }

    func reload() {
        settings = AddonSettings.load(from: settingsURL)
        clients = [:]
        for e in state.accounts {
            if state.outlook.contains(e) { if let id = settings.microsoftClientID { clients[e] = OutlookClient(clientID: id, email: e) } }
            else if let cfg = settings.gmail { clients[e] = GmailClient(cfg, email: e) }
        }
        if status == "Not connected." || status.hasPrefix("Add a Google") || status.hasPrefix("Connected") { status = idleStatus }
    }
    private var idleStatus: String {
        settings.gmail == nil && settings.microsoftClientID == nil ? "Add a Google client ID to begin."
            : accounts.isEmpty ? "No account connected yet."
            : "Looks for new mail every \(settings.checkMinutes < 60 ? "\(Int(settings.checkMinutes)) minutes" : "\(Int(settings.checkMinutes / 60)) hours")."
    }

    /// Earlier versions kept one token under a fixed name. Find out whose it is and file it under that address.
    private func migrateLegacyAccount() {
        guard state.accounts.isEmpty, let cfg = settings.gmail else { return }
        Task {
            guard let email = await GmailClient.migrateLegacy(cfg) else { return }
            addAccount(email); status = "Moved your Gmail sign-in to \(email)."
        }
    }

    private func addAccount(_ email: String) {
        if !state.accounts.contains(email) { state.accounts.append(email) }
        state.save(to: stateURL); reload()
    }

    /// Settings → Remove: forget the sign-in, and drop anything of theirs still waiting to be shown.
    func removeAccount(_ email: String) {
        if state.outlook.contains(email) { OutlookClient.forget(email) } else { GmailClient.forget(email) }
        state.outlook.removeAll { $0 == email }
        state.accounts.removeAll { $0 == email }
        state.replyAccounts.removeAll { $0 == email }
        state.stale.removeAll { $0 == email }
        if session?.alert.account == email { session = nil }
        state.pending.removeAll { $0.account == email }
        state.save(to: stateURL); reload()
        status = "Removed \(email)."
    }

    // MARK: iPhone notifications

    /// Settings → iPhone notifications. Turning it on starts from now.
    func setPhoneAlerts(_ on: Bool) {
        do { try AddonSettings.savePhoneAlerts(at: settingsURL, on) } catch { phoneStatus = "Couldn't save settings.json: \(error.localizedDescription)"; return }
        state.phoneCursor = nil; phoneStatus = ""; reload(); pollPhone()
    }

    /// A cheap local query every few seconds; no model involved. New rows from apps this Mac doesn't have become cards.
    private func pollPhone() {
        guard settings.phoneAlerts else { return }
        do {
            if state.pending.contains(where: { $0.kind == "phone-access" }) { state.pending.removeAll { $0.kind == "phone-access" && $0.id != current?.id } }   // readable now
            guard let cursor = state.phoneCursor else { state.phoneCursor = try PhoneNotes.latestID(); state.save(to: stateURL); phoneStatus = "Watching for iPhone notifications."; return }
            let notes = try PhoneNotes.rows(after: cursor)
            if notes.isEmpty { if !macBuffer.isEmpty, Date().timeIntervalSince(lastJudge) > 60 { judgeMac() }; return }      // a judge that failed is tried again, not left until the next banner
            guard let last = notes.last else { return }
            let installed: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            let have = Set(state.pending.map(\.id))
            var fresh: [AddonAlert] = [], judge: [MailItem] = []
            for n in notes {
                let r = PhoneNotes.route(n, macAlerts: settings.macAlerts, urgent: settings.urgentWords, muted: Set(state.muted), installed: installed)
                Logger(subsystem: "in.dextron04.notch", category: "notes").info("\(n.app, privacy: .public) -> \(String(describing: r), privacy: .public)")   // app and decision only, never the text
                switch r {
                case .phone: fresh.append(PhoneNotes.alert(n))
                case .urgent: fresh.append(PhoneNotes.urgentAlert(n, name: appName(n.app)))
                case .judge: judge.append(PhoneNotes.asMailItem(n, name: appName(n.app)))
                case .muted, .skip: break
                }
            }
            fresh = fresh.filter { !have.contains($0.id) }
            if !judge.isEmpty { macBuffer = Array((macBuffer + judge).suffix(Triage.batch)); judgeMac() }
            state.pending += fresh.suffix(10)                                   // a burst after sleep is a few cards, not a flood
            state.phoneCursor = last.rec; state.save(to: stateURL)
            if !fresh.isEmpty { presentIfPossible() }
        } catch {
            phoneStatus = error.localizedDescription
            if phoneStatus != lastPhoneLog { lastPhoneLog = phoneStatus; Logger(subsystem: "in.dextron04.notch", category: "phone").error("iPhone poll failed: \(self.phoneStatus, privacy: .public)") }
            queuePhoneAccessCard(error)
        }
    }
    private var lastPhoneLog = ""
    private func appName(_ bundle: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// usernoted appends each banner to the database's write-ahead log, so a write there wakes the poll at once instead of waiting up to 5s.
    /// The 5s timer stays as the net: it re-arms this when the file was replaced, or couldn't be opened yet (no Full Disk Access).
    private var phoneWatch: DispatchSourceFileSystemObject?
    private func watchPhone() {
        guard settings.phoneAlerts, phoneWatch == nil else { return }
        let fd = Darwin.open(PhoneNotes.dbURL.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        w.setEventHandler { [weak self, weak w] in
            guard let w else { return }
            MainActor.assumeIsolated {
                if !w.data.isDisjoint(with: [.delete, .rename]) { w.cancel(); if self?.phoneWatch === w { self?.phoneWatch = nil } }
                self?.pollPhone()
            }
        }
        w.setCancelHandler { close(fd) }
        w.resume(); phoneWatch = w
    }

    // MARK: reminders

    /// Reminders set from another assistant: when one comes due it becomes a card, and it keeps coming back every ten minutes until you say Done.
    func checkReminders() {
        let now = Date()
        let due = Reminders.due(Reminders.load(vault: VaultReader.defaultVault), done: state.remindDone, snoozed: state.remindSnooze, now: now)
        guard !due.isEmpty else { return }
        for r in due {
            state.remindDone.append(r.id); state.remindSnooze[r.id] = nil; state.remindCount[r.id, default: 0] += 1
            if now.timeIntervalSince(r.due) > Reminders.staleAfter { continue }
            state.pending.append(AddonAlert(id: "reminder|\(r.id)", addon: "reminder", sender: r.sourceName, address: "", headline: r.text,
                reason: "Set from \(r.sourceName).", url: "", score: 10, created: now, account: nil, kind: "reminder"))
        }
        if state.remindDone.count > 2000 { state.remindDone.removeFirst(state.remindDone.count - 2000) }
        state.save(to: stateURL); presentIfPossible()
    }

    // MARK: connections

    /// One of your assistants isn't connected to your memory. The monitor decides how often this happens; the button opens the fix.
    func queueConnectCard(_ s: Surface, _ c: Conn) {
        guard !state.pending.contains(where: { $0.kind == "connect" }) else { return }
        let t = ConnectionLogic.cardText(s, c)
        state.pending.append(AddonAlert(id: "connect|\(s.rawValue)|\(Int(Date().timeIntervalSince1970))", addon: "app", sender: "Dex Notch", address: "", headline: t.headline,
            reason: t.reason, url: "", score: 10, created: Date(), account: nil, kind: "connect"))
        state.save(to: stateURL); presentIfPossible()
    }

    // MARK: updates

    /// A newer version exists: one card per version, and its notes are fetched now so "What's new" opens at once.
    func updateFound(_ v: String) {
        guard state.updateNudged != v, Changelog.newer(v, than: AppUpdater.shared.version) else { return }
        state.updateNudged = v
        state.pending.append(AddonAlert(id: "update|\(v)", addon: "app", sender: "Dex Notch", address: "", headline: "Dex Notch \(v) is available",
            reason: "Press ⌥N to see what's new.", url: "", score: 10, created: Date(), account: nil, kind: "update"))
        state.save(to: stateURL); loadNotes(v); presentIfPossible()
    }
    private func loadNotes(_ v: String) {
        notesState = .loading; notes = []
        Task {
            if let b = await Changelog.load(installed: AppUpdater.shared.version, new: v), !b.isEmpty { notes = b; notesState = .ready } else { notesState = .failed }
        }
    }
    /// ⌥N on the update card: it grows into the page of release notes.
    func openNotes() {
        guard let a = current, a.kind == "update", !notesOpen else { return }
        if notesState == .failed { loadNotes(String(a.id.dropFirst("update|".count))) }
        countdown?.cancel(); cardKeys = []
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) { notesOpen = true }
        onReply?(true)
    }
    func closeNotes() { if let c = current, notesOpen { retire(c.id) } }
    enum NotesState { case loading, ready, failed }
    private(set) var notesOpen = false
    private(set) var notes: [Changelog.Block] = []
    private(set) var notesState = NotesState.loading
    private var macBuffer: [MailItem] = []      // ponytail: memory only; a quit before the model answers drops them
    private var judging = false

    /// Mac notifications go to the same model as mail, in one batch, within the hourly model budget. Failure keeps them for the next poll.
    private var lastJudge = Date.distantPast
    private var lastJudgeLog = ""
    private func judgeNote(_ m: String) {     // said once per change, so a wait doesn't fill the log
        guard m != lastJudgeLog else { return }
        lastJudgeLog = m; Logger(subsystem: "in.dextron04.notch", category: "notes").info("judge: \(m, privacy: .public)")
    }
    private func judgeMac() {
        guard !judging, !macBuffer.isEmpty else { return }
        guard let assistant else { judgeNote("no AI connected, \(macBuffer.count) waiting"); return }
        guard state.canCallModel(now: Date(), limit: settings.maxModelCallsPerHour) else { judgeNote("hourly model limit reached, \(macBuffer.count) waiting"); return }
        judging = true; lastJudge = Date()
        let batch = macBuffer; state.noteModelCall(now: Date())
        let order = settings.order.filter { assistant.choices.contains($0) }
        Task {
            defer { judging = false }
            guard let r = await Triage.run(items: batch, importance: settings.importance, order: order, ask: { [self] b, s, u in try await ask(b, s, u) }) else {
                judgeNote("no model answered, \(batch.count) kept to retry"); return
            }
            let done = Set(batch.map(\.id)); macBuffer.removeAll { done.contains($0.id) }
            let have = Set(state.pending.map(\.id))
            let found = r.alerts.filter { !have.contains($0.id) && !state.muted.contains($0.address) }
            judgeNote("\(r.backend.rawValue) judged \(batch.count), showing \(found.count)")
            lastJudgeLog = ""
            guard !found.isEmpty else { return }
            state.pending += found; state.save(to: stateURL); presentIfPossible()
        }
    }
    func setMacAlerts(_ on: Bool) {
        do { try AddonSettings.saveMacAlerts(at: settingsURL, on) } catch { phoneStatus = "Couldn't save settings.json: \(error.localizedDescription)"; return }
        macBuffer = []; reload()
    }

    /// Reading failed: say so at the notch (once a day) instead of only in Settings.
    private func queuePhoneAccessCard(_ error: Error) {
        guard state.phoneAccessCardDue(now: Date()) else { return }
        let denied = (error as? PhoneNotes.Problem) == .denied
        state.pending.append(AddonAlert(id: "phone-access|\(Int(Date().timeIntervalSince1970))", addon: "phone", sender: "Dex Notch", address: "",
            headline: denied ? "iPhone notifications need Full Disk Access" : "Couldn't read iPhone notifications",
            reason: denied ? "Allow Dex Notch in Privacy & Security, then reopen the app." : error.localizedDescription,
            url: "", score: 10, created: Date(), account: nil, kind: "phone-access"))
        state.phoneNudged = Date(); state.save(to: stateURL); presentIfPossible()
    }

    // MARK: schedule

    /// The notch asks you to reconnect, and asks again each day until you have.
    private func queueReconnectCard() {
        guard state.reconnectCardDue(now: Date()), let first = state.stale.first else { return }
        let n = state.stale.count
        state.pending.append(AddonAlert(id: "reconnect|\(first)|\(Int(Date().timeIntervalSince1970))", addon: "gmail", sender: "Dex Notch", address: "",
            headline: "Reconnect Gmail to keep your alerts going",
            reason: n == 1 ? "One new permission lets you reply from the notch. It takes about a minute." : "\(n) accounts need one new permission, so you can reply from the notch.",
            url: "", score: 10, created: Date(), account: first, kind: "reconnect"))
        state.reconnectNudged = Date(); state.save(to: stateURL)
    }

    /// Signs the stale accounts in again, one after another. The new permission is always requested here, whatever the Allow replies switch says.
    func reconnectAll() {
        guard let cfg = settings.gmail, let first = state.stale.first else { return }
        status = "Reconnect \(first) in your browser…"
        Task {
            var next: String? = first
            while let email = next {
                do {
                    let r = try await GmailClient.connect(cfg, replies: true, loginHint: email)
                    if r.canReply, !state.replyAccounts.contains(r.email) { state.replyAccounts.append(r.email) }
                    if !state.accounts.contains(r.email) { state.accounts.append(r.email) }
                    state.reconnected(email); state.reconnected(r.email)
                    state.pending.removeAll { $0.kind == "reconnect" }
                    state.save(to: stateURL); reload()
                    next = state.stale.first
                    status = next.map { "\(r.email) is back. Now \($0)…" } ?? "All set. Alerts have resumed."
                } catch { status = error.localizedDescription; return }
            }
            state.lastTry = nil; checkNow()
        }
    }

    private func tick() {
        queueReconnectCard()
        guard !clients.isEmpty, connected, state.isDue(now: Date(), minutes: settings.checkMinutes) else { return }
        checkNow(manual: false)
    }

    /// Menu → Check mail now (`manual`), and the scheduled look. A look is cheap (a list request per account); the model only runs when
    /// there is new mail that got past the free filters. Every connected account is read; one failing doesn't hide the others.
    func checkNow(manual: Bool = true) {
        guard !checking, !clients.isEmpty, let assistant else { return }
        checking = true; status = "Checking mail…"
        let accounts = state.accounts.filter { !state.stale.contains($0) }          // accounts that must sign in again are left alone
        if accounts.isEmpty { checking = false; status = state.stale.isEmpty ? status : "Reconnect your Gmail accounts to resume alerts."; return }
        Task {
            defer { checking = false }
            state.lastTry = Date()
            var failed: [String] = [], why = ""
            @MainActor func readAll() async -> [MailItem] {
                var out: [MailItem] = []; failed = []
                for e in accounts {
                    guard let c = clients[e] else { continue }
                    do { out += try await c.fetchUnread(skipping: Set(state.seen), limit: Triage.batch) }
                    catch { failed.append(e); why = error.localizedDescription }
                }
                return out
            }
            var items = await readAll()
            if failed.count == accounts.count {                                  // nothing could be read at all
                state.lastOK = false; state.save(to: stateURL)
                status = accounts.count == 1 ? why : "Couldn't reach any account. \(why)"
                return
            }
            var fresh = Triage.prefilter(items, seen: Set(state.seen), muted: Set(state.muted))
            if !manual, fresh.contains(where: { Date().timeIntervalSince($0.date) < 90 }) {
                status = "New mail. Reading it in a minute…"                     // mail that just landed: wait a moment, so a burst becomes one model call
                try? await Task.sleep(for: .seconds(60))
                items = await readAll()
                if failed.count == accounts.count { state.lastOK = false; state.save(to: stateURL); status = why; return }
                fresh = Triage.prefilter(items, seen: Set(state.seen), muted: Set(state.muted))
            }
            var found: [AddonAlert] = [], via = ""
            if !fresh.isEmpty {
                if !manual, !state.canCallModel(now: Date(), limit: settings.maxModelCallsPerHour) {
                    state.lastOK = true; state.save(to: stateURL)               // nothing is marked read: the next look picks it up
                    status = "A lot of new mail. Pacing model use; it will be read shortly."
                    return
                }
                let order = settings.order.filter { assistant.choices.contains($0) }
                state.noteModelCall(now: Date())
                guard let r = await Triage.run(items: fresh, importance: settings.importance, order: order, ask: { [self] b, s, u in try await ask(b, s, u) }) else {
                    state.lastOK = false; state.save(to: stateURL)
                    status = order.isEmpty ? "No model is set up to read your mail." : "No model could answer. Trying again soon."
                    return
                }
                let have = Set(state.pending.map(\.id))
                found = r.alerts.filter { !have.contains($0.id) }; via = " with " + r.backend.displayName
            }
            state.markSeen(items.map(\.id)); state.pending += found
            state.lastOK = failed.isEmpty; state.save(to: stateURL)               // a failed account makes the next try come later, not sooner
            let note = failed.isEmpty ? "" : " Couldn't read \(failed.joined(separator: ", "))."
            status = "Checked \(Date().formatted(date: .omitted, time: .shortened))\(via). " + (found.isEmpty ? "Nothing needs you." : "\(found.count) worth your attention.") + note
            presentIfPossible()
        }
    }

    /// One model call. Claude and Codex run with no tools and no saved session; the local model just answers.
    private func ask(_ b: Backend, _ system: String, _ user: String) async throws -> String {
        guard let assistant else { throw GmailError("Not ready.") }
        if b == .gemma { return try await timeout(300) { try await assistant.askGemma(system: system, user: user) } }
        let route = Route(backend: b, work: false, prompt: system + "\n\n" + user, locked: true)
        return try await timeout(180) {
            var text = "", final = ""
            for try await e in AgentRunner.run(route, session: nil) {
                switch e {
                case .text(let t): text += t
                case .final(let t): final = t
                case .error(let m): throw GmailError(m)
                default: break
                }
            }
            return final.isEmpty ? text : final
        }
    }

    // MARK: Gmail connection

    /// Adds an account (or refreshes one already there). Empty fields use the built-in Google client; filled ones are your own, and are kept.
    func connectGmail(clientID: String, clientSecret: String) {
        let own = GmailConfig(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        let cfg: GmailConfig
        if !own.clientID.isEmpty || !own.clientSecret.isEmpty {
            guard !own.clientID.isEmpty, !own.clientSecret.isEmpty else { status = "Add both the client ID and the secret, or clear both to use the built-in sign-in."; return }
            do { try AddonSettings.saveGmail(at: settingsURL, own) } catch { status = "Couldn't save settings.json: \(error.localizedDescription)"; return }
            cfg = own
        } else if let b = AddonSettings.bundled() { cfg = b }
        else { status = "This build has no Google sign-in built in. Add your own client under Advanced."; return }
        status = "Finish signing in in your browser…"
        Task {
            do {
                let r = try await GmailClient.connect(cfg, replies: settings.repliesOnConnect)       // read, and (unless you turned it off) drafts and sending
                let email = r.email
                let isNew = !state.accounts.contains(email)
                if r.canReply, !state.replyAccounts.contains(email) { state.replyAccounts.append(email) }
                state.reconnected(email)
                addAccount(email)
                status = (isNew ? "Added \(email)." : "\(email) signed in again.") + (r.canReply ? " Replies are on." : " Read-only: use Allow replies to draft and send.")
                try? await Task.sleep(for: .milliseconds(300)); state.lastTry = nil; checkNow()
            } catch { status = error.localizedDescription }
        }
    }

    /// Settings → Connect Outlook. Empty field = the application ID this build carries; a filled one is yours, and is kept.
    func connectOutlook(clientID: String) {
        let own = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if !own.isEmpty {
            do { try AddonSettings.saveMicrosoft(at: settingsURL, own) } catch { status = "Couldn't save settings.json: \(error.localizedDescription)"; return }
            id = own
        } else if let b = AddonSettings.bundledMicrosoft() { id = b }
        else { status = "This build has no Microsoft sign-in built in. Add your own application ID under Use your own Microsoft application."; return }
        status = "Finish signing in in your browser…"
        Task {
            do {
                let r = try await OutlookClient.connect(clientID: id, replies: settings.repliesOnConnect)
                let isNew = !state.accounts.contains(r.email)
                if !state.outlook.contains(r.email) { state.outlook.append(r.email) }
                if r.canReply, !state.replyAccounts.contains(r.email) { state.replyAccounts.append(r.email) }
                addAccount(r.email)
                status = (isNew ? "Added \(r.email)." : "\(r.email) signed in again.") + (r.canReply ? " Replies are on." : " Read-only: use Allow replies to draft and send.")
                try? await Task.sleep(for: .milliseconds(300)); state.lastTry = nil; checkNow()
            } catch { status = error.localizedDescription }
        }
    }

    /// "gmail" or "outlook": which mark and name an account gets.
    func addon(for email: String) -> String { state.outlook.contains(email) ? "outlook" : "gmail" }

    // MARK: replying

    /// Which agent writes first: the first in your order that is actually available.
    private var firstAgent: Backend { settings.order.first { assistant?.choices.contains($0) ?? false } ?? .claude }
    var agents: [Backend] { settings.order.filter { assistant?.choices.contains($0) ?? false } }

    /// "Reply" on the card (⌥R). The card grows into the reply panel; if this account can only read, it first asks for the permission.
    func startReply() {
        guard let alert = current, alert.addon == "gmail" || alert.addon == "outlook" else { return }
        let acct = alert.account ?? state.accounts.first ?? ""
        if session?.alert.id != alert.id { session = ReplySession(alert: alert, stage: canReply(acct) ? .loading : .needsPermission, backend: firstAgent) }
        countdown?.cancel(); cardKeys = []
        withAnimation(.spring(duration: 0.5, bounce: 0.18)) { replyOpen = true }
        onReply?(true)
        if session?.stage == .loading, session?.context == nil { loadContext() }
    }

    /// The panel closed without sending or saving (esc, a click elsewhere): the draft is kept, and the alert waits in the queue.
    func collapseReply() {
        guard let c = current, replyOpen, let s = session else { return }
        if s.stage == .needsPermission && s.note != nil { return }           // Google's page is in front for a moment: that is not "closed"
        if case .undo = s.outcome { undoSend() }                              // leaving mid-countdown is an Undo, never a send
        retire(c.id, keep: true)
    }
    /// Menu: Resume reply.
    func resumeReply() { guard session != nil, current == nil else { return }; resumeRequested = true; presentIfPossible(force: true) }
    var resumable: String? { current == nil && !replyOpen ? session?.alert.sender : nil }

    /// Throws the reply away. The alert counts as dealt with.
    func discardReply() { sendTask?.cancel(); let c = current; session = nil; if let c { retire(c.id) } }

    private func finishReply() { sendTask?.cancel(); let c = current; session = nil; if let c { retire(c.id) } }

    func allowReplies() {
        guard let s = session else { return }
        let acct = s.alert.account ?? state.accounts.first ?? ""
        s.note = "Finish in your browser…"
        Task {
            do {
                let r = try await signIn(acct, replies: true)
                guard r.canReply else { throw GmailError("Google didn't allow drafts and sending. Try again and tick the box for writing email.") }
                if !state.replyAccounts.contains(r.email) { state.replyAccounts.append(r.email) }
                if !state.accounts.contains(r.email) { state.accounts.append(r.email) }
                state.reconnected(r.email)
                state.save(to: stateURL); reload()
                s.note = nil; s.stage = .loading; loadContext()
            } catch { s.note = error.localizedDescription }
        }
    }

    /// Signs one existing account in again with the right provider's page.
    private func signIn(_ email: String, replies: Bool) async throws -> (email: String, canReply: Bool) {
        if state.outlook.contains(email) {
            guard let id = settings.microsoftClientID else { throw GmailError("This build has no Microsoft sign-in. Add your application ID in Settings → Mail.") }
            return try await OutlookClient.connect(clientID: id, replies: replies, loginHint: email)
        }
        guard let cfg = settings.gmail else { throw GmailError("This build has no Google sign-in. Add your own client in Settings → Mail.") }
        return try await GmailClient.connect(cfg, replies: replies, loginHint: email)
    }

    /// From Settings: let one account draft and send.
    func allowReplies(for email: String) {
        status = "Finish in your browser…"
        Task {
            do {
                let r = try await signIn(email, replies: true)
                guard r.canReply else { throw GmailError("Google didn't allow drafts and sending. Try again and tick the box for writing email.") }
                if !state.replyAccounts.contains(r.email) { state.replyAccounts.append(r.email) }
                state.reconnected(r.email)
                state.save(to: stateURL); reload(); status = "\(r.email) can now draft and send replies."
            } catch { status = error.localizedDescription }
        }
    }

    private func loadContext() {
        guard let s = session else { return }
        let acct = s.alert.account ?? state.accounts.first ?? ""
        Task {
            do {
                guard forceDemo || clients[acct] != nil else { throw GmailError("\(acct) isn't connected.") }
                let ctx = forceDemo ? Self.demoMail : try await clients[acct]!.fullMessage(id: s.alert.messageID)
                s.context = ctx; s.stage = .ready
                await writeDraft(s)
            } catch is ReplyPermissionNeeded { s.stage = .needsPermission }
            catch { s.stage = .failed(error.localizedDescription) }
        }
    }

    /// Tries your chosen agent first, then the others in your order, so one being out of messages doesn't stop a reply.
    private func generate(_ system: String, _ user: String, preferred: Backend) async throws -> (text: String, by: Backend) {
        let order = [preferred] + agents.filter { $0 != preferred }
        for b in order {
            if let t = try? await ask(b, system, user), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (t, b) }
        }
        throw GmailError(agents.isEmpty ? "No AI agent is set up. Add one in Settings → Models." : "No agent could answer just now. Try again in a moment.")
    }

    private func writeDraft(_ s: ReplySession, instruction: String = "") async {
        guard let ctx = s.context else { return }
        s.drafting = true; s.note = nil; defer { s.drafting = false }
        let p = MailReply.draftPrompt(ctx, name: settings.name, importance: settings.importance, previous: instruction.isEmpty ? "" : s.draft, instruction: instruction)
        do {
            let r = try await generate(p.system, p.user, preferred: s.backend)
            s.draft = MailReply.cleanDraft(r.text); s.backend = r.by
            s.note = "Written by \(r.by.displayName). Read it, change it, then send."
        } catch { s.note = error.localizedDescription }
    }

    /// The input under the draft: on the Draft tab it is a change you want, on the Ask tab a question about the email.
    func submitInput() {
        guard let s = session, s.stage == .ready, !s.busy else { return }
        let text = s.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        s.input = ""
        if s.tab == .draft { Task { await writeDraft(s, instruction: text) } }
        else {
            guard let ctx = s.context else { return }
            s.asking = true
            let ex = ReplySession.Exchange(question: text, answer: "")
            s.exchanges.append(ex)
            let p = MailReply.askPrompt(ctx, history: s.exchanges.dropLast().map { ($0.question, $0.answer) }, question: text)
            Task {
                defer { s.asking = false }
                let answer: String
                do { answer = try await generate(p.system, p.user, preferred: s.backend).text.trimmingCharacters(in: .whitespacesAndNewlines) }
                catch { answer = error.localizedDescription }
                if let i = s.exchanges.firstIndex(where: { $0.id == ex.id }) { s.exchanges[i].answer = answer }
            }
        }
    }

    /// Another agent writes it again from the same email.
    func useAgent(_ b: Backend) {
        guard let s = session, !s.busy, s.backend != b else { return }
        s.backend = b
        if s.tab == .draft, s.stage == .ready { Task { await writeDraft(s) } }
    }

    /// Send, with a few seconds to change your mind. Nothing leaves before they run out.
    func beginSend() {
        guard let s = session, s.canSend, let ctx = s.context, MailReply.raw(ctx, body: s.draft) != nil else {
            session?.note = session?.context.flatMap { MailReply.recipient($0) } == nil ? MailReply.noRecipient : session?.note
            return
        }
        let acct = ctx.account
        sendTask?.cancel()
        sendTask = Task {
            // the lit rim is the Undo clock: full when you press Send, gone when it goes
            progress = 1
            let steps = Self.undoSeconds * 30
            for i in 0..<steps {
                progress = 1 - Double(i) / Double(steps)
                s.outcome = .undo(Int((progress * Double(Self.undoSeconds)).rounded(.up)))
                try? await Task.sleep(for: .milliseconds(33))
                if Task.isCancelled { return }
            }
            progress = 0
            s.outcome = .sending
            do {
                if forceDemo { try? await Task.sleep(for: .milliseconds(500)) }
                else {
                    guard let client = clients[acct] else { throw GmailError("\(acct) isn't connected.") }
                    try await client.send(ctx, body: s.draft)
                }
                s.outcome = .sent; sealTick += 1
                try? await Task.sleep(for: .milliseconds(2300))          // long enough to see the check drawn and the comet land
                finishReply()
            } catch is ReplyPermissionNeeded { s.outcome = .none; s.stage = .needsPermission }
            catch { s.outcome = .failed(error.localizedDescription) }
        }
    }
    static let undoSeconds = 5
    func undoSend() { sendTask?.cancel(); session?.outcome = .none; withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.4)) { progress = 1 } }       // the rim fills back: nothing was sent

    /// Saves it as a draft in Gmail, in the same thread, and closes. Nothing is sent.
    func saveDraft() {
        guard let s = session, s.canSend, let ctx = s.context, MailReply.raw(ctx, body: s.draft) != nil else { return }
        let acct = ctx.account
        s.outcome = .sending
        Task {
            do {
                if forceDemo { try? await Task.sleep(for: .milliseconds(500)) }
                else {
                    guard let client = clients[acct] else { throw GmailError("\(acct) isn't connected.") }
                    try await client.saveDraft(ctx, body: s.draft)
                }
                s.outcome = .saved; sealTick += 1
                try? await Task.sleep(for: .milliseconds(2300))
                finishReply()
            } catch is ReplyPermissionNeeded { s.outcome = .none; s.stage = .needsPermission }
            catch { s.outcome = .failed(error.localizedDescription) }
        }
    }

    // MARK: arriving at the notch

    /// How long without a key or a mouse movement before we decide you are away. An alert shown to an empty chair is an alert lost.
    static let awayAfter: Double = 120
    private var idleSeconds: Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    /// The display the notch is on is awake. With the lid shut and a monitor attached that is the monitor, so the alert appears there.
    private var displayAwake: Bool {
        guard let s = NotchWindow.targetScreen(), let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsAsleep(id) == 0
    }
    private func canPresent(force: Bool) -> Bool {
        !locked && displayAwake && current == nil && !(assistant?.isOpen ?? false) && (force || forceDemo || idleSeconds < Self.awayAfter)
    }
    /// Alerts waiting for you (not counting the one on screen).
    var waiting: Int { current == nil ? state.pending.count : max(state.pending.count - 1, 0) }
    var history: [AddonAlert] { state.history }
    func canReply(_ account: String) -> Bool { forceDemo || state.replyAccounts.contains(account) }
    /// The demo has no Gmail behind it: a canned email, and a send that goes nowhere.
    private static let demoMail = MailContext(account: "alex@example.com", id: "demo", threadId: "abc123", from: "Priya Nair <priya@example.com>", replyTo: "", subject: "Interview: moving to Thursday 3pm?",
        messageID: "<demo@example.com>", references: "", date: Date(timeIntervalSinceNow: -3600),
        body: "Hi Alex,\n\nThe panel can only do Thursday at 3pm now. Does that still work for you? Could you confirm by tomorrow morning?\n\nAlso, please bring a short portfolio sample, ideally the checkout redesign.\n\nThanks,\nPriya")
    /// Menu: Show waiting alerts. Same queue, same order, but without waiting for you to be at the keyboard.
    func showWaiting() { presentIfPossible(force: true) }

    /// You just woke or unlocked the Mac: give the desktop a moment to settle, then bring the news.
    private func welcomeBack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.tick(); self?.checkReminders(); self?.presentIfPossible() }
    }

    func presentIfPossible(force: Bool = false) {
        let resume = resumeRequested ? session?.alert : nil
        guard !state.pending.isEmpty, canPresent(force: force), let next = resume ?? AddonState.next(from: state.pending) else { return }
        current = next; retiring = false; progress = 1; hovering = false
        Task {
            presenting = true; onPresenting?(true)              // the shell opens first…
            try? await Task.sleep(for: .milliseconds(340))
            guard current?.id == next.id else { return }
            shown = true; streakTick += 1                       // …then the light runs its rim as the words resolve
            cardKeys = [
                Hotkey(id: 10, keyCode: kVK_Return, modifiers: optionKey) { [weak self] in self?.open() },
                Hotkey(id: 11, keyCode: kVK_Delete, modifiers: optionKey) { [weak self] in self?.notImportant() },
                Hotkey(id: 12, keyCode: kVK_Escape, modifiers: optionKey) { [weak self] in self?.dismiss() },
                Hotkey(id: 13, keyCode: kVK_ANSI_R, modifiers: optionKey) { [weak self] in self?.startReply() },
            ]
            if next.kind == "update" { cardKeys.append(Hotkey(id: 14, keyCode: kVK_ANSI_N, modifiers: optionKey) { [weak self] in self?.openNotes() }) }
            if resumeRequested { resumeRequested = false; startReply() } else { runCountdown(for: next.id) }
        }
    }

    private func runCountdown(for id: String) {
        countdown?.cancel()
        countdown = Task {
            while !Task.isCancelled, progress > 0 {
                try? await Task.sleep(for: .milliseconds(33))
                if !hovering { progress = max(progress - 0.033 / Self.dwell, 0) }
            }
            if !Task.isCancelled { retire(id, keep: idleSeconds > Self.awayAfter && !forceDemo) }       // you walked off while it was up: it stays in the queue
        }
    }

    /// The notch opened for something else: step aside, keep nothing on screen.
    func assistantOpened() { if let c = current { retire(c.id, keep: true) } }       // it goes back in the queue, not in the bin
    func assistantClosed() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.presentIfPossible() } }

    func open() {
        guard let c = current else { return }
        if c.kind == "update" { retire(c.id); if AppUpdater.shared.readyVersion != nil { AppUpdater.shared.restartNow() } else { AppUpdater.shared.checkNow() }; return }
        if c.kind == "reminder" { retire(c.id, completed: true); return }
        if c.kind == "phone-access" { retire(c.id); NSWorkspace.shared.open(PhoneNotes.privacyPane); return }
        if c.kind == "connect" { retire(c.id); ConnectionMonitor.shared.openFromCard(c.id); return }
        if c.kind == "reconnect" { retire(c.id); reconnectAll(); return }                 // this card's "Open" is "Reconnect"
        guard !c.url.isEmpty, let u = URL(string: c.url) else { retire(c.id); return }       // an iPhone card has nowhere to go: Done just closes it
        NSWorkspace.shared.open(u); retire(c.id)
    }
    func dismiss() { if let c = current { retire(c.id) } }
    /// "Not important": this sender is never shown again.
    func notImportant() {
        guard let c = current, c.kind == nil else { return }       // only mail and phone cards can be muted
        if !state.muted.contains(c.address) { state.muted.append(c.address) }
        retire(c.id, alsoDropFrom: c.address)       // their other queued alerts go once the card has closed, so "+N more" doesn't jump while it is still showing
    }

    private func retire(_ id: String, alsoDropFrom address: String? = nil, keep: Bool = false, completed: Bool = false) {
        guard let alert = current, alert.id == id, !retiring else { return }
        retiring = true; countdown?.cancel(); cardKeys = []      // the keys go back to whatever you were typing in
        if replyOpen || notesOpen { onReply?(false) }
        Task {
            withAnimation(.easeIn(duration: 0.22)) { shown = false }
            try? await Task.sleep(for: .milliseconds(140))      // the words start to leave, and the shell begins folding back into the hardware under them
            withAnimation(.smooth(duration: 0.5)) { presenting = false }     // explicit, so nothing downstream can swallow it
            onPresenting?(false)
            try? await Task.sleep(for: .milliseconds(850))      // longer than the fold (about 0.5s) so the card is never removed mid-motion
            if !keep, alert.kind == "reminder", !completed, (state.remindCount[alert.id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""] ?? 0) < Reminders.maxShows, let rid = alert.id.split(separator: "|", maxSplits: 1).last.map(String.init) {      // anything but Done: it comes back
                state.remindDone.removeAll { $0 == rid }; state.remindSnooze[rid] = Date().addingTimeInterval(Reminders.snooze)
            }
            if !keep { state.pending.removeAll { $0.id == id || ($0.address == address && !address!.isEmpty) }; if alert.kind == nil { state.recordShown(alert) } }
            state.save(to: stateURL)
            current = nil; retiring = false; replyOpen = false; notesOpen = false
            try? await Task.sleep(for: .milliseconds(500))
            presentIfPossible()
        }
    }

    private func demo() {
        let now = Date()
        state.pending = [
            PhoneNotes.alert(.init(rec: 0, app: "com.burbn.instagram", title: "Ana sent you a message", body: "are we still on for dinner tonight? i can book for 8", date: now.addingTimeInterval(-60))),
            AddonAlert(id: "demo1", addon: "gmail", sender: "Priya Nair", address: "priya@example.com", headline: "Interview moved to Thursday 3:00 PM",
                       reason: "A real person is waiting on your reply, and the slot is in two days.", url: "https://mail.google.com", score: 9, created: now),
            AddonAlert(id: "demo2", addon: "gmail", sender: "Chase", address: "alerts@example.com", headline: "Your card payment failed",
                       reason: "Payment due today; a failed one can add a late fee.", url: "https://mail.google.com", score: 8, created: now),
        ]
        // NOTCH_ALERT_DEMO=gmail | phone shows just that one card (README screenshots); any other value shows the lot
        switch ProcessInfo.processInfo.environment["NOTCH_ALERT_DEMO"] {
        case "gmail": state.pending = Array(state.pending.filter { $0.id == "demo1" })
        case "phone": state.pending = Array(state.pending.prefix(1))
        case "reminder": state.pending = [AddonAlert(id: "reminder|demo", addon: "reminder", sender: "ChatGPT", address: "", headline: "Call mum about Sunday lunch",
                                        reason: "Set from ChatGPT.", url: "", score: 10, created: now, account: nil, kind: "reminder")]
        case "update":      // NOTCH_CHANGELOG_DIR=<checkout> NOTCH_DEMO_VERSION=0.6.0
            let v = ProcessInfo.processInfo.environment["NOTCH_DEMO_VERSION"] ?? "9.9.9"
            state.pending = [AddonAlert(id: "update|\(v)", addon: "app", sender: "Dex Notch", address: "", headline: "Dex Notch \(v) is available",
                                        reason: "Press ⌥N to see what's new.", url: "", score: 10, created: now, account: nil, kind: "update")]
            loadNotes(v)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.presentIfPossible() }
    }
}
