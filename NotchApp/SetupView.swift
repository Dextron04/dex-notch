import SwiftUI
import AppKit

/// What the Settings window edits. Saving goes through `Settings.update`, which keeps any keys it doesn't know about.
@Observable @MainActor
final class SetupModel {
    let assistant: Assistant
    var start: Backend?
    var workspace: String?
    var folders: [String] = []
    var host = ""
    var model = ""
    var token = ""
    var keychainService: String?
    var keychainAccount: String?
    var localOpen = false
    var gmailID = ""
    var gmailSecret = ""
    var message: String?

    private let url = Settings.defaultURL
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }

    init(assistant: Assistant) {
        self.assistant = assistant
        let a: AppSettings
        if case .ok(let loaded) = Settings.load(from: url) { a = loaded } else { a = AppSettings(gemma: nil, gemmaProblem: nil, defaultBackend: nil) }
        start = a.defaultBackend; workspace = a.workspaceDefault
        // Show the folder list the app will actually use, so nothing is allowed that the user hasn't seen
        folders = a.folders ?? AgentStream.folderChoices(configured: nil, defaultFolder: nil, home: FileManager.default.homeDirectoryForCurrentUser)
            .compactMap { Settings.normalizeFolder($0, home: FileManager.default.homeDirectoryForCurrentUser, exists: { p in var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }) }
        if let g = AddonSettings.load(from: url).gmail { gmailID = g.clientID; gmailSecret = g.clientSecret }
        if let g = a.gemma { host = g.host; model = g.model; keychainService = g.keychainService; keychainAccount = g.keychainAccount; localOpen = true }
    }

    var projectsSuggestion: String? {
        let p = home.appendingPathComponent("Projects").path
        return workspace == nil && isDir(p) ? p : nil
    }

    private func pick(_ prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = home; panel.prompt = prompt
        guard panel.runModal() == .OK, let u = panel.url else { return nil }
        guard let ok = Settings.normalizeFolder(u.path, home: home, exists: isDir) else {
            message = "That folder isn't allowed. Choose one inside your home folder (not the home folder itself, a hidden folder, or Library)."
            return nil
        }
        message = nil
        return ok
    }

    func chooseWorkspace() { if let p = pick("Use as workspace") { workspace = p; if !folders.contains(p) { folders.append(p) } } }
    func addFolder() { if let p = pick("Allow"), !folders.contains(p) { folders.append(p) } }
    func useProjects() { if let p = projectsSuggestion { workspace = p; if !folders.contains(p) { folders.append(p) } } }
    func remove(_ f: String) { folders.removeAll { $0 == f }; if workspace == f { workspace = nil } }

    func save() -> Bool {
        message = nil
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines), m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsLocal = !h.isEmpty || !m.isEmpty
        var gemma: GemmaSettings?
        if wantsLocal {
            guard let nh = Settings.normalizeHost(h) else { message = "The host should look like ai.example.com (no path, no username)."; return false }
            guard !m.isEmpty else { message = "Add the model name your server uses, for example gemma3:12b."; return false }
            gemma = GemmaSettings(host: nh, model: m, keychainService: keychainService ?? nh, keychainAccount: keychainAccount ?? "notchapp")
        }
        do { try Settings.update(at: url, defaultBackend: start, workspaceDefault: workspace, folders: folders, gemma: gemma, removeGemma: !wantsLocal) }
        catch { message = "Couldn't save settings.json: \(error.localizedDescription)"; return false }
        if let g = gemma, !t.isEmpty, !KeychainStore.set(token: t, service: g.keychainService, account: g.keychainAccount) {
            message = "Saved, but the token couldn't be stored. Tokens must be plain letters, digits and symbols, with no line breaks."; return false
        }
        assistant.connect()      // re-reads settings, looks for the CLIs again, checks the local model
        return true
    }
}

struct SetupView: View {
    @Bindable var m: SetupModel
    var height: CGFloat = 860
    var done: () -> Void
    private var a: Assistant { m.assistant }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    section("Pick your model", note: "One is enough to start.") { modelSection }
                    section("Where it may work", note: "Edit runs are sandboxed. They can only change folders you allow here.") { workspaceSection }
                    section("Mail", note: "Gmail is read-only. dex-notch checks every few hours and only interrupts you for mail that needs you.") { mailSection }
                    section("A model on your own server", note: "Optional. You can add it any time from the menu bar.") { localSection }
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: 580, height: height)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Ink.ember)
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up dex-notch").font(.system(size: 31, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
            HStack(alignment: .firstTextBaseline) {
                Text("Three quick choices, all changeable later.").font(.system(size: 16, design: .serif)).italic().foregroundStyle(Ink.dim)
                Spacer(minLength: 12)
                Button { a.openSettings() } label: { Text("Edit settings.json").font(.system(size: 13, design: .serif)).foregroundStyle(Ink.dim).underline() }
                    .buttonStyle(.plain).help("Open the raw file in your text editor")
            }
        }
    }

    private func section<C: View>(_ title: String, note: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Ink.text.opacity(0.09)).frame(height: 1)
            Text(title).font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(Ink.text).padding(.top, 4)
            Text(note).font(.system(size: 13.5, design: .serif)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            content().padding(.top, 4)
        }
    }

    // models
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([Backend.claude, .codex], id: \.self) { b in cliRow(b) }
            if a.cliFound.count > 1 {
                HStack(spacing: 12) {
                    Text("Start with").font(.system(size: 14, design: .serif)).foregroundStyle(Ink.dim)
                    ForEach(a.cliFound.sorted { $0.rawValue < $1.rawValue }, id: \.self) { b in
                        Button { m.start = b } label: {
                            HStack(spacing: 6) { ModelMark(backend: b, size: 16, active: m.start == b); Text(b.displayName) }
                                .font(.system(size: 14, weight: m.start == b ? .semibold : .regular, design: .serif))
                                .foregroundStyle(m.start == b ? Ink.ember : Ink.dim)
                                .padding(.vertical, 4).overlay(alignment: .bottom) { if m.start == b { Rectangle().fill(Ink.ember).frame(height: 1) } }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if a.detected && a.cliFound.isEmpty {
                Button("Check again") { a.refreshAvailability() }.buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember)
            }
        }
    }

    private func cliRow(_ b: Backend) -> some View {
        let found = a.cliFound.contains(b)
        let cmd = b == .claude ? "npm install -g @anthropic-ai/claude-code" : "npm install -g @openai/codex"
        return HStack(alignment: .top, spacing: 14) {
            ModelMark(backend: b, size: 24, active: found).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(b.displayName).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
                    if !a.detected { Text("looking…").font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim) }
                    else if found { Label("found", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ember) }
                    else { Text("not installed").font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim) }
                }
                if a.detected && !found {
                    HStack(spacing: 8) {
                        Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text.opacity(0.85)).textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Ink.dim)
                        }.buttonStyle(.plain).help("Copy")
                    }
                    Text("then run \(b.rawValue) once to log in").font(.system(size: 12.5, design: .serif)).foregroundStyle(Ink.dim)
                }
            }
        }
    }

    // workspace
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Default workspace").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
                HStack(spacing: 12) {
                    Text(m.workspace.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Scratch folder only")
                        .font(.system(size: 13, design: m.workspace == nil ? .serif : .monospaced)).italic(m.workspace == nil)
                        .foregroundStyle(m.workspace == nil ? Ink.dim : Ink.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if m.workspace != nil { link("Clear") { m.workspace = nil } }
                    link("Choose…") { m.chooseWorkspace() }
                }
                if let p = m.projectsSuggestion {
                    link("Use ~/Projects") { m.useProjects() }.help(p)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Folders you can switch to with ⌘F").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
                if m.folders.isEmpty {
                    Text("None. Edit runs stay in the scratch folder.").font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim)
                }
                ForEach(m.folders, id: \.self) { f in
                    HStack(spacing: 10) {
                        Text((f as NSString).abbreviatingWithTildeInPath).font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button { m.remove(f) } label: { Image(systemName: "minus.circle").foregroundStyle(Ink.dim) }.buttonStyle(.plain).help("Remove")
                    }
                }
                link("Add folder…") { m.addFolder() }.padding(.top, 2)
            }
        }
    }

    // local model
    private var localSection: some View {
        DisclosureGroup(isExpanded: $m.localOpen) {
            VStack(alignment: .leading, spacing: 16) {
                field("Host", "ai.example.com", text: $m.host)
                field("Model", "gemma3:12b", text: $m.model)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access token").font(.system(size: 13, design: .serif)).foregroundStyle(Ink.dim)
                    SecureField("", text: $m.token, prompt: Text("paste once").foregroundStyle(Ink.dim)).textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced)).foregroundStyle(Ink.text)
                    Rectangle().fill(Ink.text.opacity(0.18)).frame(height: 1)
                    Text("Stored in your Keychain, never in settings.json. Leave it blank to keep the saved one.")
                        .font(.system(size: 12, design: .serif)).italic().foregroundStyle(Ink.dim)
                }
            }.padding(.top, 14)
        } label: {
            HStack(spacing: 8) {
                ModelMark(backend: .gemma, size: 20, active: m.localOpen)
                Text("Add a model from Ollama").font(.system(size: 16, design: .serif)).foregroundStyle(Ink.text)
            }.contentShape(Rectangle())
        }
        .tint(Ink.dim)
    }

    // mail
    private var mailSection: some View {
        let center = AddonCenter.shared
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AddonMark(addon: "gmail", size: 24).opacity(center.connected ? 1 : 0.6)
                Text("Gmail").font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
                if center.connected { Label("connected", systemImage: "checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ember) }
            }
            field("Google client ID", "1234-abc.apps.googleusercontent.com", text: $m.gmailID)
            field("Client secret", "GOCSPX-…", text: $m.gmailSecret)
            Text("Create a free OAuth client of type Desktop app in the Google Cloud console, with the Gmail API enabled, and paste it here. It stays on this Mac.")
                .font(.system(size: 12, design: .serif)).italic().foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                link(center.connected ? "Reconnect Gmail" : "Connect Gmail") { center.connectGmail(clientID: m.gmailID, clientSecret: m.gmailSecret) }
                if center.connected { link("Check now") { center.checkNow() } }
                Text(center.status).font(.system(size: 13, design: .serif)).foregroundStyle(Ink.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, design: .serif)).foregroundStyle(Ink.dim)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Ink.dim)).textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced)).foregroundStyle(Ink.text).autocorrectionDisabled()
            Rectangle().fill(Ink.text.opacity(0.18)).frame(height: 1)
        }
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember) }.buttonStyle(.plain)
    }

    // footer
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Ink.text.opacity(0.09)).frame(height: 1)
            HStack(spacing: 18) {
                if let msg = m.message {
                    Text(msg).font(.system(size: 13, design: .serif)).foregroundStyle(Ink.emberDeep).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Press ⌥ Space any time to ask.").font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button("Cancel") { done() }.buttonStyle(.plain).font(.system(size: 15, design: .serif)).foregroundStyle(Ink.dim)
                    .keyboardShortcut(.cancelAction)
                Button { if m.save() { done() } } label: {
                    Text("Save and start").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(.black).lineLimit(1).fixedSize()
                        .padding(.horizontal, 20).padding(.vertical, 9).background(Capsule().fill(Ink.ember))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40).padding(.vertical, 16)
        }
        .background(Color.black)
    }
}

/// The window itself. Opens on first launch (no settings.json yet) and from the menu bar.
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show(assistant: Assistant) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        assistant.refreshAvailability()
        let model = SetupModel(assistant: assistant)
        let h = min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: h), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "dex-notch"
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: SetupView(m: model, height: h) { [weak self] in self?.window?.close() })
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        window = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}
