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
    private(set) var connected = false
    private(set) var settings = AddonSettings()

    /// The window listens so it can let clicks through everywhere except the card.
    var onPresenting: ((Bool) -> Void)?

    private var state = AddonState()
    private var assistant: Assistant?
    private var gmail: GmailClient?
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
        let dn = DistributedNotificationCenter.default(), ws = NSWorkspace.shared.notificationCenter
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = false; self?.welcomeBack() } }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = true } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = false; self?.welcomeBack() } }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.tick(); self?.presentIfPossible() }
        if ProcessInfo.processInfo.environment["NOTCH_ALERT_DEMO"] != nil { demo() }
    }

    func reload() {
        settings = AddonSettings.load(from: settingsURL)
        gmail = settings.gmail.map(GmailClient.init)
        let configured = settings.gmail != nil
        Task { let has = await Task.detached { GmailClient.isConnected() }.value
               connected = configured && has
               if status == "Not connected." || status.hasPrefix("Add ") { status = connected ? "Connected. Checks every \(Int(settings.intervalHours)) hours." : (settings.gmail == nil ? "Add a Google client ID to begin." : "Not connected.") } }
    }

    // MARK: schedule

    private func tick() {
        guard settings.gmail != nil, connected, state.isDue(now: Date(), hours: settings.intervalHours) else { return }
        checkNow()
    }

    /// Menu → Check mail now, and the scheduled run.
    func checkNow() {
        guard !checking, let gmail, let assistant else { return }
        checking = true; status = "Checking mail…"
        Task {
            defer { checking = false }
            state.lastTry = Date()
            do {
                let items = try await gmail.fetchUnread()
                let fresh = Triage.prefilter(items, seen: Set(state.seen), muted: Set(state.muted))
                var found: [AddonAlert] = [], via = ""
                if !fresh.isEmpty {
                    let order = settings.order.filter { assistant.choices.contains($0) }
                    guard let r = await Triage.run(items: fresh, importance: settings.importance, order: order, ask: { [self] b, s, u in try await ask(b, s, u) }) else {
                        state.lastOK = false; state.save(to: stateURL)
                        status = order.isEmpty ? "No model is set up to read your mail." : "No model could answer. Trying again in 30 minutes."
                        return
                    }
                    let have = Set(state.pending.map(\.id))
                    found = r.alerts.filter { !have.contains($0.id) }; via = " with " + r.backend.displayName
                }
                state.markSeen(items.map(\.id)); state.pending += found
                state.lastOK = true; state.save(to: stateURL)
                status = "Checked \(Date().formatted(date: .omitted, time: .shortened))\(via). " + (found.isEmpty ? "Nothing needs you." : "\(found.count) worth your attention.")
                presentIfPossible()
            } catch {
                state.lastOK = false; state.save(to: stateURL)
                status = error.localizedDescription
            }
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

    func connectGmail(clientID: String, clientSecret: String) {
        let cfg = GmailConfig(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cfg.clientID.isEmpty, !cfg.clientSecret.isEmpty else { status = "Add the client ID and secret first."; return }
        do { try AddonSettings.saveGmail(at: settingsURL, cfg) } catch { status = "Couldn't save settings.json: \(error.localizedDescription)"; return }
        status = "Finish signing in in your browser…"
        Task {
            do {
                try await GmailClient.connect(cfg)
                reload(); status = "Connected."
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
        state.pending.removeAll { $0.address == c.address }     // and anything else already queued from them
        retire(c.id)
    }

    private func retire(_ id: String) {
        guard current?.id == id, !retiring else { return }
        retiring = true; countdown?.cancel(); cardKeys = []      // the keys go back to whatever you were typing in
        Task {
            shown = false
            try? await Task.sleep(for: .milliseconds(200))      // words leave first, then the shell folds back into the hardware
            presenting = false; onPresenting?(false)
            try? await Task.sleep(for: .milliseconds(650))
            state.pending.removeAll { $0.id == id }; state.save(to: stateURL)
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
