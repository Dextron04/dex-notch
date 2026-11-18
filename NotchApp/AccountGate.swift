import SwiftUI
import AppKit

/// Dex Notch starts only after the server has confirmed this Mac is linked to a Dex account. The rules are in `Gate.decide` (Account.swift);
/// this class runs them at launch, walks a new person through signing up, and keeps checking while the app runs.
@MainActor @Observable
final class AccountGate {
    static let shared = AccountGate()
    enum Phase: Equatable { case checking, welcome, waiting(code: String), approved(email: String), problem(String) }

    private(set) var phase: Phase = .checking
    private(set) var isOpen = false
    private(set) var linkURL: URL?
    var keepConversations = true
    var onOpen: (() -> Void)?

    private var linking: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private var url: URL { Settings.defaultURL }
    var host: String { HostedAccount.host(at: url) ?? HostedAccount.defaultHost }
    var email: String? { defaults.string(forKey: HostedAPI.emailKey) }
    private var token: String? { KeychainStore.get(service: HostedAccount.keychainService, account: HostedAccount.keychainAccount) }

    /// Called once at launch. A normal launch confirms silently and starts the app; anything else shows the window.
    func launch() {
        guard let t = token, HostedAccount.host(at: url) != nil else { forget(); phase = .welcome; GateWindow.shared.show(); return }
        phase = .checking
        Task {
            let answer = await HostedAPI.me(host: host, token: t)
            switch Gate.decide(hasToken: true, answer: answer, lastConfirmed: defaults.object(forKey: HostedAPI.confirmedKey) as? Date, now: Date()) {
            case .open:
                if case .confirmed(let e) = answer { remember(e) }
                open()
            case .needsAccount:
                forget(); phase = .welcome; GateWindow.shared.show()       // removed from the account, or the account is gone
            case .locked:
                phase = .problem("Dex Notch couldn't reach its server to confirm your account. Check your connection and try again."); GateWindow.shared.show()
            }
        }
    }

    func retry() { if token != nil && HostedAccount.host(at: url) != nil { launch() } else { phase = .welcome } }

    /// "Continue": ask the server for a link, open it in the browser, wait for the approval.
    func begin() {
        linking?.cancel(); linkURL = nil; phase = .waiting(code: "")
        linking = Task { await link() }
    }

    private func link() async {
        let host = self.host
        do {
            let s = try await HostedAPI.startLink(host: host, name: Host.current().localizedName ?? "My Mac")
            linkURL = s.url; phase = .waiting(code: s.code)
            NSWorkspace.shared.open(s.url)
            let deadline = Date().addingTimeInterval(TimeInterval(s.expiresIn))
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                switch try? await HostedAPI.poll(host: host, secret: s.secret) {
                case .approved(let t, let e)?: finish(token: t, email: e, host: host); return
                case .expired?: phase = .problem("That sign-in expired before it was approved. Start again."); return
                default: continue      // still pending, or a blip: keep asking until the link runs out
                }
            }
            phase = .problem("That sign-in expired before it was approved. Start again.")
        } catch is CancellationError {
        } catch { phase = .problem("Dex Notch couldn't reach its server. Check your connection and try again.") }
    }

    private func finish(token: String, email: String, host: String) {
        guard KeychainStore.set(token: token, service: HostedAccount.keychainService, account: HostedAccount.keychainAccount) else {
            phase = .problem("The key for this Mac couldn't be stored in your keychain."); return
        }
        do { try HostedAccount.saveHost(at: url, host, upload: keepConversations) }
        catch {
            KeychainStore.delete(service: HostedAccount.keychainService, account: HostedAccount.keychainAccount)
            phase = .problem("Couldn't save settings.json: \(error.localizedDescription)"); return
        }
        remember(email); phase = .approved(email: email)
        NSApp.activate(ignoringOtherApps: true)
        Task { try? await Task.sleep(for: .seconds(1.4)); open() }
    }

    private func open() {
        guard !isOpen else { return }
        isOpen = true; GateWindow.shared.close(); onOpen?()
        Task { await watch() }
    }

    /// While running: if the server says this Mac was removed or the account deleted, go back to the sign-in screen. Unreachable is not a reason to stop.
    private func watch() async {
        while true {
            try? await Task.sleep(for: .seconds(3600))
            guard let t = token else { return }
            switch await HostedAPI.me(host: host, token: t) {
            case .rejected: Self.relaunch(); return
            case .confirmed(let e): remember(e)
            case .unreachable: break
            }
        }
    }

    /// Settings → Memory → Sign out. Forgets this Mac's key and starts again, so the app waits at the sign-in screen.
    func signOut() { forget(); Self.relaunch() }

    private func remember(_ email: String) { defaults.set(Date(), forKey: HostedAPI.confirmedKey); defaults.set(email, forKey: HostedAPI.emailKey) }
    private func forget() {
        KeychainStore.delete(service: HostedAccount.keychainService, account: HostedAccount.keychainAccount)
        try? HostedAccount.removeHost(at: url)
        defaults.removeObject(forKey: HostedAPI.confirmedKey); defaults.removeObject(forKey: HostedAPI.emailKey)
    }

    private static func relaunch() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run(); NSApp.terminate(nil)
    }
}

@MainActor
final class GateWindow {
    static let shared = GateWindow()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Dex Notch"; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.isReleasedWhenClosed = false; w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: GateView())
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.window = nil } }
        window = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close(); window = nil }
}

struct GateView: View {
    @Bindable private var g = AccountGate.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch g.phase {
                case .checking: checking
                case .welcome: welcome
                case .waiting(let code): waiting(code)
                case .approved(let email): approved(email)
                case .problem(let why): problem(why)
                }
            }
            .padding(.horizontal, 52).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 560)
        .background(Color.black).preferredColorScheme(.dark).tint(Ink.ember)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: g.phase)
    }

    private func mark() -> some View { Image("AppMark").resizable().frame(width: 56, height: 56).accessibilityHidden(true).padding(.bottom, 22) }
    private func title(_ s: String) -> some View { Text(s).font(.system(size: 27, weight: .semibold)).foregroundStyle(Ink.text).multilineTextAlignment(.center).padding(.bottom, 10) }
    private func lede(_ s: String) -> some View {
        Text(s).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    private func primary(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black).padding(.horizontal, 26).padding(.vertical, 10).background(Capsule().fill(Ink.ember))
        }.buttonStyle(.plain)
    }
    private func quiet(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(s, action: action).buttonStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Ink.dim)
    }

    private var checking: some View {
        VStack(spacing: 14) { mark(); ProgressView().controlSize(.small); Text("Confirming your account…").font(.system(size: 14)).foregroundStyle(Ink.dim) }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            mark()
            title("Welcome to Dex Notch")
            lede("Create your account, or sign in, to get started. We open your browser and email you a link. There is no password. Dex Notch starts once the server has confirmed your account.")
                .padding(.bottom, 24)
            Toggle(isOn: $g.keepConversations) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep my AI conversations in my account").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Ink.text)
                    Text("Conversations recorded on this Mac (Claude Code, Codex, Gemini) are uploaded with passwords and keys removed, so Claude and ChatGPT can search them. They are encrypted on the server's disk with a key only you can open, but not end-to-end: the service opens them to search. To do this, Dex Notch starts a small helper in the background that watches for new conversations. Change or stop it any time in Settings → Memory.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Ink.text.opacity(0.06))).padding(.bottom, 26)
            primary("Continue in browser") { g.begin() }
            HStack(spacing: 22) {
                quiet("Privacy") { NSWorkspace.shared.open(URL(string: "https://github.com/Dextron04/dex-notch/blob/master/PRIVACY.md")!) }
                quiet("Quit") { NSApp.terminate(nil) }
            }.padding(.top, 18)
        }
    }

    @ViewBuilder private func waiting(_ code: String) -> some View {
        VStack(spacing: 0) {
            mark()
            if code.isEmpty {
                ProgressView().controlSize(.small).padding(.bottom, 12); Text("Contacting Dex…").font(.system(size: 14)).foregroundStyle(Ink.dim)
            } else {
                title("Approve this Mac")
                lede("Your browser opened a page. Sign in there with your email, then make sure it shows this code before you tap Add this Mac.").padding(.bottom, 22)
                Text(code).font(.system(size: 40, weight: .semibold, design: .monospaced)).tracking(5).foregroundStyle(Ink.ember).padding(.bottom, 24)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Waiting for you…").font(.system(size: 14)).foregroundStyle(Ink.dim) }.padding(.bottom, 24)
                HStack(spacing: 22) {
                    if let u = g.linkURL { quiet("Open the page again") { NSWorkspace.shared.open(u) } }
                    quiet("Start over") { g.begin() }
                    quiet("Quit") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func approved(_ email: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Ink.ember).padding(.bottom, 20).accessibilityHidden(true)
            title("You're in"); lede("Signed in as \(email). Starting Dex Notch…")
        }
    }

    private func problem(_ why: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(Ink.emberDeep).padding(.bottom, 20).accessibilityHidden(true)
            title("Couldn't confirm your account"); lede(why).padding(.bottom, 26)
            primary("Try again") { g.retry() }
            quiet("Quit") { NSApp.terminate(nil) }.padding(.top, 18)
        }
    }
}
