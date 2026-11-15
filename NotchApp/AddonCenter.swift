import SwiftUI
import Observation
import Carbon.HIToolbox

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
    var accounts: [String] { state.accounts }
    var connected: Bool { !state.accounts.isEmpty }
    private(set) var settings = AddonSettings()

    /// The window listens so it can let clicks through everywhere except the card.
    var onPresenting: ((Bool) -> Void)?

    private var state = AddonState()
    private var assistant: Assistant?
    private var clients: [String: GmailClient] = [:]
    private var locked = false
    private var asleep = false
    private var retiring = false
    private var cardKeys: [Hotkey] = []     // ⌥↩ ⌥⌫ ⌥esc, registered only while a card is up
    private var timer: Timer?
    private var countdown: Task<Void, Never>?
    private let settingsURL = Settings.defaultURL
    private let stateURL = AddonState.defaultURL

    func start(assistant: Assistant) {
        self.assistant = assistant
        state = AddonState.load(from: stateURL)
        reload()
        migrateLegacyAccount()
        let dn = DistributedNotificationCenter.default(), ws = NSWorkspace.shared.notificationCenter
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = false; self?.welcomeBack() } }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = true } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = false; self?.welcomeBack() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.tick(); self?.presentIfPossible() }
        if ProcessInfo.processInfo.environment["NOTCH_ALERT_DEMO"] != nil { demo() }
    }

    func reload() {
        settings = AddonSettings.load(from: settingsURL)
        clients = [:]
        if let cfg = settings.gmail { for e in state.accounts { clients[e] = GmailClient(cfg, email: e) } }
        if status == "Not connected." || status.hasPrefix("Add a Google") || status.hasPrefix("Connected") { status = idleStatus }
    }
    private var idleStatus: String {
        settings.gmail == nil ? "Add a Google client ID to begin."
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
        GmailClient.forget(email)
        state.accounts.removeAll { $0 == email }
        state.pending.removeAll { $0.account == email }
        state.save(to: stateURL); reload()
        status = "Removed \(email)."
    }

    // MARK: schedule

    private func tick() {
        guard !asleep, settings.gmail != nil, connected, state.isDue(now: Date(), minutes: settings.checkMinutes) else { return }
        checkNow(manual: false)
    }

    /// Menu → Check mail now (`manual`), and the scheduled look. A look is cheap (a list request per account); the model only runs when
    /// there is new mail that got past the free filters. Every connected account is read; one failing doesn't hide the others.
    func checkNow(manual: Bool = true) {
        guard !checking, !clients.isEmpty, let assistant else { return }
        checking = true; status = "Checking mail…"
        let accounts = state.accounts
        Task {
            defer { checking = false }
            state.lastTry = Date()
            var failed: [String] = [], why = ""
            @MainActor func readAll() async -> [MailItem] {
                var out: [MailItem] = []; failed = []
                for e in accounts {
                    guard let c = clients[e] else { continue }
                    do { out += try await c.fetchUnread(skipping: Set(state.seen)) }
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
                let email = try await GmailClient.connect(cfg)
                let isNew = !state.accounts.contains(email)
                addAccount(email)
                status = isNew ? "Added \(email)." : "\(email) signed in again."
                try? await Task.sleep(for: .milliseconds(300)); state.lastTry = nil; checkNow()
            } catch { status = error.localizedDescription }
        }
    }

    // MARK: arriving at the notch

    private var canPresent: Bool { !locked && !asleep && current == nil && !(assistant?.isOpen ?? false) }

    /// You just woke or unlocked the Mac: give the desktop a moment to settle, then bring the news.
    private func welcomeBack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.tick(); self?.presentIfPossible() }
    }

    func presentIfPossible() {
        guard canPresent, let next = state.pending.first else { return }
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
            ]
            runCountdown(for: next.id)
        }
    }

    private func runCountdown(for id: String) {
        countdown?.cancel()
        countdown = Task {
            while !Task.isCancelled, progress > 0 {
                try? await Task.sleep(for: .milliseconds(33))
                if !hovering { progress = max(progress - 0.033 / Self.dwell, 0) }
            }
            if !Task.isCancelled { retire(id) }
        }
    }

    /// The notch opened for something else: step aside, keep nothing on screen.
    func assistantOpened() { if let c = current { retire(c.id) } }
    func assistantClosed() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.presentIfPossible() } }

    func open() {
        guard let c = current, let u = URL(string: c.url) else { return }
        NSWorkspace.shared.open(u); retire(c.id)
    }
    func dismiss() { if let c = current { retire(c.id) } }
    /// "Not important": this sender is never shown again.
    func notImportant() {
        guard let c = current else { return }
        if !state.muted.contains(c.address) { state.muted.append(c.address) }
        retire(c.id, alsoDropFrom: c.address)       // their other queued alerts go once the card has closed, so "+N more" doesn't jump while it is still showing
    }

    private func retire(_ id: String, alsoDropFrom address: String? = nil) {
        guard current?.id == id, !retiring else { return }
        retiring = true; countdown?.cancel(); cardKeys = []      // the keys go back to whatever you were typing in
        Task {
            withAnimation(.easeIn(duration: 0.22)) { shown = false }
            try? await Task.sleep(for: .milliseconds(140))      // the words start to leave, and the shell begins folding back into the hardware under them
            withAnimation(.smooth(duration: 0.5)) { presenting = false }     // explicit, so nothing downstream can swallow it
            onPresenting?(false)
            try? await Task.sleep(for: .milliseconds(850))      // longer than the fold (about 0.5s) so the card is never removed mid-motion
            state.pending.removeAll { $0.id == id || ($0.address == address) }; state.save(to: stateURL)
            current = nil; retiring = false
            try? await Task.sleep(for: .milliseconds(500))
            presentIfPossible()
        }
    }

    private func demo() {
        let now = Date()
        state.pending = [
            AddonAlert(id: "demo1", addon: "gmail", sender: "Priya Nair", address: "priya@example.com", headline: "Interview moved to Thursday 3:00 PM",
                       reason: "A real person is waiting on your reply, and the slot is in two days.", url: "https://mail.google.com", score: 9, created: now),
            AddonAlert(id: "demo2", addon: "gmail", sender: "Chase", address: "alerts@example.com", headline: "Your card payment failed",
                       reason: "Payment due today; a failed one can add a late fee.", url: "https://mail.google.com", score: 8, created: now),
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.presentIfPossible() }
    }
}
