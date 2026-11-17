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
    var ownClientOpen = false
    var msID = ""
    var msOpen = false
    var importance = ""
    var myName = ""
    var repliesOnConnect = true
    var checkMinutes = 5.0
    var pane: SetupPane = .models
    var message: String?
    var hostedConnected: String?
    var keepConversations = true

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
        let ad = AddonSettings.load(from: url)
        importance = ad.importance; myName = ad.name; repliesOnConnect = ad.repliesOnConnect; checkMinutes = ad.checkMinutes
        if ad.gmailIsOwn, let g = ad.gmail { gmailID = g.clientID; gmailSecret = g.clientSecret; ownClientOpen = true }
        else if ad.gmail == nil { ownClientOpen = true }
        if ad.microsoftIsOwn, let id = ad.microsoftClientID { msID = id; msOpen = true } else if ad.microsoftClientID == nil { msOpen = true }
        hostedConnected = HostedAccount.connectedHost(at: url)
        keepConversations = HostedAccount.uploads(at: url)
        if let g = a.gemma { host = g.host; model = g.model; keychainService = g.keychainService; keychainAccount = g.keychainAccount; localOpen = true }
    }

    func copyDiagnostics(center: AddonCenter) {
        let text = Diagnostics.report(version: AppUpdater.shared.version, macOS: ProcessInfo.processInfo.operatingSystemVersionString, host: hostedConnected,
                                      uploads: keepConversations, lastConfirmed: UserDefaults.standard.object(forKey: HostedAPI.confirmedKey) as? Date,
                                      phoneAlerts: center.settings.phoneAlerts, fullDiskAccess: PhoneNotes.canRead(), macAlerts: center.settings.macAlerts, mailAccounts: center.accounts.count)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        message = "Diagnostics copied."
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

    /// Acts at once (not part of Save). The recorder re-reads settings.json every tick, so it takes effect within seconds.
    func setKeepConversations(_ on: Bool) {
        message = nil
        do { try HostedAccount.setUpload(at: url, on); keepConversations = on }
        catch { message = "Couldn't save settings.json: \(error.localizedDescription)" }
    }

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
        do { try AddonSettings.saveImportance(at: url, importance); try AddonSettings.saveName(at: url, myName); try AddonSettings.saveRepliesOnConnect(at: url, repliesOnConnect); try AddonSettings.saveCheckMinutes(at: url, checkMinutes); if !msID.trimmingCharacters(in: .whitespaces).isEmpty { try AddonSettings.saveMicrosoft(at: url, msID) } } catch { message = "Couldn't save settings.json: \(error.localizedDescription)"; return false }
        AddonCenter.shared.reload()      // the new check frequency and importance apply right away
        assistant.connect()      // re-reads settings, looks for the CLIs again, checks the local model
        return true
    }
}

enum SetupPane: String, CaseIterable, Identifiable {
    case welcome = "Welcome", models = "Models", folders = "Folders", mail = "Mail", phone = "iPhone", memory = "Memory", updates = "Updates", finish = "All set"
    var id: String { rawValue }
    static let settings: [SetupPane] = [.models, .folders, .mail, .phone, .memory, .updates]
    static let guided: [SetupPane] = [.welcome, .models, .folders, .mail, .phone, .finish]       // the first-run walk-through, in order
}

/// One quiet window: a rail to pick the pane, one pane at a time, plain rows divided by hairlines. Same ink and ember as the notch.
struct SetupView: View {
    static let width: CGFloat = 780
    @Bindable var m: SetupModel
    var height: CGFloat = 600
    var guided = false              // first run: Back / Continue through every step instead of Save / Cancel
    var done: () -> Void
    @Namespace private var railNS
    private var a: Assistant { m.assistant }
    private var center: AddonCenter { AddonCenter.shared }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Ink.text.opacity(0.09)).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    pane.padding(.horizontal, 48).padding(.top, 42).padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(m.pane).transition(.opacity)
                }
                footer
            }
        }
        .frame(width: Self.width, height: height)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Ink.ember)
    }

    // MARK: rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image("AppMark").resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                Text("Dex Notch").font(.system(size: 18, weight: .semibold)).foregroundStyle(Ink.text)
            }
            .padding(.top, 52).padding(.bottom, 36)
            ForEach(guided ? SetupPane.guided : SetupPane.settings) { p in
                let on = m.pane == p
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.12)) { m.pane = p } } label: {
                    HStack(spacing: 11) {
                        ZStack {
                            if on { Circle().fill(Ink.ember).matchedGeometryEffect(id: "dot", in: railNS) }
                        }.frame(width: 6, height: 6)
                        Text(p.rawValue).font(.system(size: 16, weight: on ? .semibold : .regular)).foregroundStyle(on ? Ink.text : Ink.dim)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            Text("Press ⌥ Space any time to ask.").font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 28).frame(width: 214, alignment: .leading)
    }

    @ViewBuilder private var pane: some View {
        switch m.pane {
        case .welcome: welcomePane
        case .models: modelsPane
        case .folders: foldersPane
        case .mail: mailPane
        case .phone: phonePane
        case .memory: memoryPane
        case .updates: updatesPane
        case .finish: finishPane
        }
    }

    // MARK: building blocks

    private func header(_ title: String, _ lede: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(Ink.text)
            Text(lede).font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    /// Plain-English reason for a permission or a choice, shown at the top of the step that asks for it.
    private func why(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Ink.ember.opacity(0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Why this is needed").font(.system(size: 12, weight: .semibold)).tracking(0.4).foregroundStyle(Ink.ember)
                Text(text).font(.system(size: 14)).foregroundStyle(Ink.text.opacity(0.85)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 20)
    }

    private func subhead(_ t: String) -> some View {
        Text(t).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text).padding(.top, 32).padding(.bottom, 4)
    }

    /// One line of the list: mark, name and a detail line, actions on the right, a hairline under it.
    private func row<L: View, T: View, E: View>(title: String, detail: String? = nil, mono: Bool = false, pad: CGFloat = 15, muted: Bool = false,
                                                @ViewBuilder lead: () -> L, @ViewBuilder trail: () -> T, @ViewBuilder extra: () -> E) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                lead().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(mono ? .system(size: 14, design: .monospaced) : muted ? .system(size: 15) : .system(size: 16, weight: .semibold)).foregroundStyle(muted ? Ink.dim : Ink.text)
                        .lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 16)
                trail()
            }
            extra()
        }
        .padding(.vertical, pad)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1) }
    }
    private func row<L: View, T: View>(title: String, detail: String? = nil, mono: Bool = false, pad: CGFloat = 15, muted: Bool = false, @ViewBuilder lead: () -> L, @ViewBuilder trail: () -> T) -> some View {
        row(title: title, detail: detail, mono: mono, pad: pad, muted: muted, lead: lead, trail: trail, extra: { EmptyView() })
    }

    private func link(_ title: String, dim: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(dim ? Ink.dim : Ink.ember).contentShape(Rectangle()) }.buttonStyle(.plain)
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13)).foregroundStyle(Ink.dim)
            Group {
                if secure { SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(Ink.dim)) }
                else { TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Ink.dim)).autocorrectionDisabled() }
            }
            .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.text)
            Rectangle().fill(Ink.text.opacity(0.18)).frame(height: 1)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Ink.dim)
        }.buttonStyle(.plain).help("Copy")
    }

    // MARK: models

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Models", "Who answers when you ask. One is enough to start. They run on your own subscriptions, so there are no keys to enter.")
            why("Dex Notch doesn't think for itself. It passes your questions to an AI you already use, such as Claude or Codex, running on this Mac. We only check that one is installed. Nothing goes through our servers.")
            VStack(spacing: 0) {
                cliRow(.claude); cliRow(.codex); localRow
            }
            if a.detected && a.cliFound.isEmpty {
                link("Check again") { a.refreshAvailability() }.padding(.top, 18)
            }
        }
    }

    private func cliRow(_ b: Backend) -> some View {
        let found = a.cliFound.contains(b)
        let cmd = b == .claude ? "npm install -g @anthropic-ai/claude-code" : "npm install -g @openai/codex"
        return row(title: b.displayName, detail: !a.detected ? "Looking…" : found ? "Installed" : "Not installed",
                   lead: { ModelMark(backend: b, size: 24, active: found) },
                   trail: {
                       if found && a.cliFound.count > 1 {
                           if m.start == b { Text("Starts here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ember) }
                           else { link("Start here", dim: true) { m.start = b } }
                       }
                   },
                   extra: {
                       if a.detected && !found {
                           VStack(alignment: .leading, spacing: 4) {
                               HStack(spacing: 8) {
                                   Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text.opacity(0.85)).textSelection(.enabled)
                                   copyButton(cmd)
                               }
                               Text("Then run \(b.rawValue) once to sign in.").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                           }.padding(.leading, 40)
                       }
                   })
    }

    private var localRow: some View {
        let set = !m.host.isEmpty && !m.model.isEmpty
        return row(title: "Local model", detail: set ? "\(m.model) on \(m.host)" : "Your own Ollama server. Optional.",
                   lead: { ModelMark(backend: .gemma, size: 24, active: set || m.localOpen) },
                   trail: { link(m.localOpen ? "Done" : set ? "Edit" : "Set up") { withAnimation(.smooth(duration: 0.3)) { m.localOpen.toggle() } } },
                   extra: {
                       if m.localOpen {
                           VStack(alignment: .leading, spacing: 18) {
                               field("Host", "ai.example.com", text: $m.host)
                               field("Model", "gemma3:12b", text: $m.model)
                               field("Access token", "paste once", text: $m.token, secure: true)
                               Text("The token goes in your Keychain, never in settings.json. Leave it blank to keep the saved one.")
                                   .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                           }.padding(.leading, 40).padding(.top, 6).padding(.bottom, 4).transition(.opacity)
                       }
                   })
    }

    // MARK: folders

    private var foldersPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Folders", "Where a model may edit files. Edit runs are sandboxed to the folders you allow here.")
            why("When you ask an AI to change files, it may only touch the folders you list here. The rest of your Mac stays off limits to it. If you skip this, it can only use a throwaway scratch folder.")
            row(title: "Default folder", detail: m.workspace.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Scratch folder only",
                lead: { Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(Ink.dim) },
                trail: {
                    HStack(spacing: 16) {
                        if m.workspace != nil { link("Clear", dim: true) { m.workspace = nil } }
                        link("Choose…") { m.chooseWorkspace() }
                    }
                },
                extra: { if let p = m.projectsSuggestion { link("Use ~/Projects") { m.useProjects() }.help(p).padding(.leading, 40) } })
            subhead("Quick switch with ⌘F")
            if m.folders.isEmpty {
                Text("None. Edit runs stay in the scratch folder.").font(.system(size: 14)).foregroundStyle(Ink.dim).padding(.vertical, 12)
            }
            ForEach(m.folders, id: \.self) { f in
                row(title: (f as NSString).abbreviatingWithTildeInPath, mono: true, pad: 11,
                    lead: { Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Ink.dim) },
                    trail: { Button { m.remove(f) } label: { Image(systemName: "minus.circle").foregroundStyle(Ink.dim) }.buttonStyle(.plain).help("Remove") })
            }
            link("Add folder…") { m.addFolder() }.padding(.top, 16)
        }
    }

    // MARK: mail

    private var mailPane: some View {
        let accounts = center.accounts
        let builtIn = AddonSettings.bundled() != nil
        return VStack(alignment: .leading, spacing: 0) {
            header("Mail", "New mail is judged as it arrives, and only the few emails that need you reach the notch. Dex Notch only reads mail until you allow replies.")
            why("To tell you about important email, Dex Notch has to read your inbox. You sign in on Google's or Microsoft's own page, so we never see your password. It starts read-only. Sending replies is a second permission that you can leave off.")
            if !center.needsReconnect.isEmpty {
                row(title: "Reconnect needed", detail: "This update asks Google for one new permission, so you can reply from the notch. Alerts for these accounts are paused until you sign in again.",
                    lead: { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.system(size: 16)).foregroundStyle(Ink.emberDeep) },
                    trail: { link("Reconnect") { center.reconnectAll() } })
            }
            VStack(spacing: 0) {
                if accounts.isEmpty {
                    row(title: "No account connected", muted: true, lead: { AddonMark(addon: "gmail", size: 24).opacity(0.45) }, trail: { EmptyView() })
                }
                ForEach(accounts, id: \.self) { e in
                    row(title: e, detail: center.needsReconnect.contains(e) ? "Reconnect needed" : center.canReply(e) ? "\(AddonMark.name(center.addon(for: e))), can draft and send replies" : "\(AddonMark.name(center.addon(for: e))), read-only", lead: { AddonMark(addon: center.addon(for: e), size: 24) },
                        trail: {
                            HStack(spacing: 16) {
                                if center.needsReconnect.contains(e) { link("Reconnect") { center.reconnectAll() } }
                                else if !center.canReply(e) { link("Allow replies") { center.allowReplies(for: e) }.help("Let Dex Notch create drafts and send mail from this account when you ask it to") }
                                link("Remove", dim: true) { center.removeAccount(e) }
                            }
                        })
                }
            }
            row(title: "Allow replies", detail: m.repliesOnConnect ? "New accounts also let Dex Notch draft and send replies, only when you press Send or Save draft." : "New accounts stay read-only. Use Allow replies on an account later if you want to reply.",
                lead: { Image(systemName: "arrowshape.turn.up.left").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                trail: { Toggle("", isOn: $m.repliesOnConnect).labelsHidden().toggleStyle(.switch) })
            HStack(spacing: 20) {
                link(accounts.isEmpty ? "Connect Gmail" : "Add a Gmail account") { center.connectGmail(clientID: m.gmailID, clientSecret: m.gmailSecret) }
                link("Connect Outlook") { center.connectOutlook(clientID: m.msID) }.help("Outlook.com, Hotmail, or a work or school Microsoft 365 account")
                if center.connected { link("Check now", dim: true) { center.checkNow() } }
            }.padding(.top, 18)
            Text(center.status).font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 8)

            DisclosureGroup(isExpanded: $m.msOpen) {
                VStack(alignment: .leading, spacing: 18) {
                    field("Application (client) ID", "00000000-0000-0000-0000-000000000000", text: $m.msID)
                    Text("A free app registration in Microsoft Entra (Azure), for any account type, with a Mobile and desktop redirect of http://localhost and the Mail.Read, Mail.ReadWrite and Mail.Send permissions. It stays on this Mac. Clear the field to use the built-in sign-in.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 14)
            } label: {
                Text(AddonSettings.bundledMicrosoft() != nil ? "Use your own Microsoft application" : "Your Microsoft application (this build has none built in)")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim).contentShape(Rectangle())
            }
            .tint(Ink.dim).padding(.top, 22)

            if !builtIn {
            DisclosureGroup(isExpanded: $m.ownClientOpen) {
                VStack(alignment: .leading, spacing: 18) {
                    field("Google client ID", "1234-abc.apps.googleusercontent.com", text: $m.gmailID)
                    field("Client secret", "GOCSPX-…", text: $m.gmailSecret)
                    Text("A free OAuth client of type Desktop app, with the Gmail API enabled, from the Google Cloud console. It stays on this Mac. Clear both fields to use the built-in sign-in again.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 14)
            } label: {
                Text(builtIn ? "Use your own Google client" : "Your Google client (this build has none built in)")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim).contentShape(Rectangle())
            }
            .tint(Ink.dim).padding(.top, builtIn ? 32 : 22)
            }

            if !center.history.isEmpty {
                subhead("Recent alerts")
                ForEach(center.history.prefix(4)) { a in
                    row(title: a.headline, detail: a.sender + (a.account.map { " · " + $0 } ?? ""), pad: 12,
                        lead: { AddonMark(addon: a.addon, size: 22) },
                        trail: { link("Open") { if let u = URL(string: a.url) { NSWorkspace.shared.open(u) } } })
                }
            }

            subhead("How often to look")
            Text("A look is light and free. The AI only reads mail that is new.").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.bottom, 12)
            frequencyPicker

            subhead("Your name")
            Text("Used to sign the replies the AI drafts. Leave it blank and they end with a short thanks.").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.bottom, 10)
            TextField("", text: $m.myName, prompt: Text("Alex").foregroundStyle(Ink.dim)).textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.text)
            Rectangle().fill(Ink.text.opacity(0.18)).frame(height: 1).padding(.top, 6)

            subhead("What matters to you")
            Text("Added to the rules that decide what interrupts you.").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.bottom, 10)
            TextField("", text: $m.importance, prompt: Text("Recruiters, my landlord, anything about payments.").foregroundStyle(Ink.dim), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...4).font(.system(size: 15)).foregroundStyle(Ink.text)
            Rectangle().fill(Ink.text.opacity(0.18)).frame(height: 1).padding(.top, 6)
            if builtIn {
            DisclosureGroup(isExpanded: $m.ownClientOpen) {
                VStack(alignment: .leading, spacing: 18) {
                    field("Google client ID", "1234-abc.apps.googleusercontent.com", text: $m.gmailID)
                    field("Client secret", "GOCSPX-…", text: $m.gmailSecret)
                    Text("A free OAuth client of type Desktop app, with the Gmail API enabled, from the Google Cloud console. It stays on this Mac. Clear both fields to use the built-in sign-in again.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 14)
            } label: {
                Text(builtIn ? "Use your own Google client" : "Your Google client (this build has none built in)")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim).contentShape(Rectangle())
            }
            .tint(Ink.dim).padding(.top, builtIn ? 32 : 22)
            }
        }
    }

    private static let frequencies: [(label: String, minutes: Double)] = [("2 min", 2), ("5 min", 5), ("15 min", 15), ("30 min", 30), ("1 hour", 60), ("4 hours", 240)]
    @Namespace private var freqNS

    /// The same underline that slides along the notch's model dial, here choosing how often to look. A hand-edited value shows up as its own choice.
    private var frequencyPicker: some View {
        var options = Self.frequencies
        if !options.contains(where: { $0.minutes == m.checkMinutes }) {
            let c = m.checkMinutes
            options.append((c < 60 ? "\(Int(c)) min" : "\(String(format: "%g", c / 60)) hours", c)); options.sort { $0.minutes < $1.minutes }
        }
        return HStack(spacing: 22) {
            ForEach(options, id: \.minutes) { o in
                let on = m.checkMinutes == o.minutes
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.1)) { m.checkMinutes = o.minutes } } label: {
                    Text(o.label).font(.system(size: 15, weight: on ? .semibold : .regular)).foregroundStyle(on ? Ink.ember : Ink.dim)
                        .padding(.vertical, 5).contentShape(Rectangle())
                        .overlay(alignment: .bottom) { if on { Rectangle().fill(Ink.ember).frame(height: 1).matchedGeometryEffect(id: "freq", in: freqNS) } }
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: welcome, iPhone, finish

    private var welcomePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Welcome to Dex Notch", "Dex Notch turns your Mac's notch into a quiet place for the few things that need you: an AI to ask, important email, and notifications from your iPhone.")
            Text("Next, a few short steps. Each one says what it needs and why, and every step can be skipped. You can change anything later in Settings.")
                .font(.system(size: 15)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            row(title: "An AI to ask", detail: "Uses Claude or Codex if they are installed here.", lead: { Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(Ink.dim) }, trail: { EmptyView() })
            row(title: "Folders the AI may edit", detail: "Only the ones you choose.", lead: { Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(Ink.dim) }, trail: { EmptyView() })
            row(title: "Gmail", detail: "Read-only unless you allow replies.", lead: { Image(systemName: "envelope").font(.system(size: 16)).foregroundStyle(Ink.dim) }, trail: { EmptyView() })
            row(title: "iPhone notifications", detail: "Needs one Mac permission, Full Disk Access.", lead: { Image(systemName: "iphone").font(.system(size: 16)).foregroundStyle(Ink.dim) }, trail: { EmptyView() })
        }
    }

    private var phonePane: some View {
        // looked at once a second, so the row turns green the moment you tick the box in System Settings
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let allowed = PhoneNotes.canRead()
            VStack(alignment: .leading, spacing: 0) {
                header("iPhone", "See your iPhone's notifications at the notch, on the Mac, without picking up your phone.")
                why("Your iPhone sends its notifications to this Mac, and macOS keeps them in a private file that apps can't open unless you say so. Full Disk Access lets Dex Notch open that one file. It only looks for new notifications and shows them at the notch. Nothing is sent anywhere, and you can switch it off at any time.")
                row(title: "Show iPhone notifications", detail: center.phoneStatus.isEmpty ? "Off until you switch it on." : center.phoneStatus,
                    lead: { Image(systemName: "iphone").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                    trail: { Toggle("", isOn: Binding(get: { center.settings.phoneAlerts }, set: { center.setPhoneAlerts($0) })).labelsHidden().toggleStyle(.switch) })
                row(title: "Full Disk Access", detail: allowed ? "Allowed." : "Not allowed yet. Open System Settings, find Dex Notch in the list (press + to add it if it isn't there) and switch it on. macOS may ask you to reopen Dex Notch.",
                    lead: { Image(systemName: allowed ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 17)).foregroundStyle(allowed ? Ink.ember : Ink.dim) },
                    trail: { if !allowed { link("Open System Settings") { _ = PhoneNotes.canRead(); NSWorkspace.shared.open(PhoneNotes.privacyPane) } } })
                row(title: "Also judge this Mac's notifications", detail: "Slack, Messages and other apps here. The AI reads each one and only the important ones come to the notch. This sends their text to the AI you picked, so it stays off until you switch it on.",
                    lead: { Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                    trail: { Toggle("", isOn: Binding(get: { center.settings.macAlerts }, set: { center.setMacAlerts($0) })).labelsHidden().toggleStyle(.switch) })
                subhead("Before this can work")
                Text("Your iPhone must be set up with iPhone Mirroring on this Mac, and System Settings → Notifications must allow notifications from your iPhone. Dex Notch can't change either of those for you.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var memoryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Memory", "Your Dex account keeps your AI conversations, so Claude and ChatGPT can search them from anywhere.")
            why("Dex Notch only runs while this Mac is linked to your account. When the switch below is on, the conversations recorded on this Mac (Claude Code, Codex, Gemini) are uploaded to your account with passwords and keys removed first. They are encrypted on the server's disk with a passphrase you choose, but not end-to-end: the service opens them to search. Turning it off stops uploads; what was already uploaded stays until you delete it on your account page.")
            if let h = m.hostedConnected {
                row(title: "Signed in", detail: [AccountGate.shared.email, h].compactMap { $0 }.joined(separator: " · "), mono: true,
                    lead: { Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Ink.ember) },
                    trail: { HStack(spacing: 18) {
                        link("Open account page") { if let u = URL(string: "https://\(h)/account") { NSWorkspace.shared.open(u) } }
                        link("Sign out", dim: true) { AccountGate.shared.signOut() }
                    } })
                row(title: "Keep my conversations in my account", detail: m.keepConversations ? "On: new conversations are uploaded." : "Off: nothing is uploaded from this Mac.",
                    lead: { Image(systemName: "icloud.and.arrow.up").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                    trail: { Toggle("", isOn: Binding(get: { m.keepConversations }, set: { m.setKeepConversations($0) })).labelsHidden().toggleStyle(.switch) })
                row(title: "Something not working?", detail: "Copy diagnostics gives setup facts only: the version, what is switched on, and when the server last confirmed this Mac. No email, passwords or conversations. Paste it into your report.",
                    lead: { Image(systemName: "ladybug").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                    trail: { HStack(spacing: 18) {
                        link("Copy diagnostics") { m.copyDiagnostics(center: center) }
                        link("Report a problem", dim: true) { NSWorkspace.shared.open(Diagnostics.issueURL) }
                    } })
                connectionsSection
                Text("Signing out removes this Mac's key and returns Dex Notch to the sign-in screen.")
                    .font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
        }
    }

    /// Whether each assistant is connected to the memory, with a button for the ones that aren't.
    private var connectionsSection: some View {
        let mon = ConnectionMonitor.shared
        return VStack(alignment: .leading, spacing: 0) {
            subhead("Connections").padding(.top, 8)
            Text("Claude and ChatGPT can all search and add to the same memory once they're connected. Dex Notch checks, and tells you at the notch if one is missing.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            ForEach(Surface.allCases, id: \.self) { s in
                let c = mon.report?.state(s) ?? .unknown, here = mon.installed.contains(s)
                row(title: s.name, detail: mon.report == nil ? "Checking…" : ConnectionLogic.detail(s, c, here: here),
                    lead: { Image(systemName: c == .connected ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 17)).foregroundStyle(c == .connected ? Ink.ember : Ink.dim) },
                    trail: { if c != .connected && (here || !s.isCLI) {
                        link(mon.busy == s ? "Working…" : s.isCLI ? (c == .needsSignIn ? "Sign in" : "Add to \(s.name)") : "Connect") { mon.connect(s) }
                    } })
            }
            HStack(spacing: 18) {
                link(mon.checking ? "Checking…" : "Check again") { Task { await mon.refresh(full: true) } }
                Toggle("Remind me at the notch", isOn: Binding(get: { mon.remind }, set: { mon.setRemind($0) })).toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
            }.padding(.top, 12)
            let here = mon.agentsHere, on = mon.instructionsOn
            row(title: "Save every conversation", detail: here.isEmpty ? "No Claude Code, Codex or Gemini found on this Mac." : (on ? "On" : "Off") + " for " + here.map(\.label).joined(separator: ", ") + ". They save a summary to your memory when a conversation ends.",
                lead: { Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 17)).foregroundStyle(on ? Ink.ember : Ink.dim) },
                trail: { if !here.isEmpty { link(on ? "Turn off" : "Turn on", dim: on) { mon.toggleInstructions() } } })
            if let n = mon.note { Text(n).font(.system(size: 13)).foregroundStyle(Ink.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
        }
        .task { mon.refreshInstructions(); await mon.refresh() }
    }

    private var finishPane: some View {
        let ok = PhoneNotes.canRead() && center.settings.phoneAlerts
        return VStack(alignment: .leading, spacing: 0) {
            header("You're set", "Here is what Dex Notch will do. Change any of it later from the menu bar icon → Settings.")
            row(title: "AI to ask", detail: a.cliFound.isEmpty ? "None found yet. Install Claude or Codex, then press Check again in Settings." : a.cliFound.map(\.displayName).sorted().joined(separator: ", "),
                lead: { Image(systemName: a.cliFound.isEmpty ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(a.cliFound.isEmpty ? Ink.dim : Ink.ember) }, trail: { EmptyView() })
            row(title: "Folders", detail: m.folders.isEmpty ? "None. Edits stay in the scratch folder." : "\(m.folders.count) allowed",
                lead: { Image(systemName: m.folders.isEmpty ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(m.folders.isEmpty ? Ink.dim : Ink.ember) }, trail: { EmptyView() })
            row(title: "Gmail", detail: center.accounts.isEmpty ? "Not connected." : center.accounts.joined(separator: ", "),
                lead: { Image(systemName: center.accounts.isEmpty ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(center.accounts.isEmpty ? Ink.dim : Ink.ember) }, trail: { EmptyView() })
            row(title: "iPhone notifications", detail: ok ? "On." : center.settings.phoneAlerts ? "Switched on, but Full Disk Access is still missing." : "Off.",
                lead: { Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Ink.ember : Ink.dim) }, trail: { EmptyView() })
            Text("Press ⌥ Space any time to ask.").font(.system(size: 15)).foregroundStyle(Ink.dim).padding(.top, 26)
        }
    }

    // MARK: updates

    private var updatesPane: some View {
        let u = AppUpdater.shared
        return VStack(alignment: .leading, spacing: 0) {
            header("Updates", "Dex Notch looks for a new version once a day and downloads it in the background. It never restarts without asking.")
            row(title: "Version \(u.version)", detail: [u.status, u.readyVersion == nil ? u.lastCheckedText : nil].compactMap { $0 }.joined(separator: " "),
                lead: { Image("AppMark").resizable().frame(width: 26, height: 26) },
                trail: {
                    if u.readyVersion != nil { link("Restart now") { u.restartNow() } }
                    else if u.running { link("Check now") { u.checkNow() } }
                })
            row(title: "Update automatically", detail: u.running ? "Turn this off to update only when you choose Check now." : "Not available in this build.",
                lead: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16)).foregroundStyle(Ink.dim) },
                trail: { Toggle("", isOn: Binding(get: { u.autoUpdate }, set: { u.autoUpdate = $0 })).labelsHidden().toggleStyle(.switch).disabled(!u.running) })
            link("What's new in \(u.version)") { NSWorkspace.shared.open(u.notesURL) }.padding(.top, 18)
        }
    }

    // MARK: footer

    private var footer: some View {
        guided ? AnyView(guidedFooter) : AnyView(settingsFooter)
    }

    private var guidedFooter: some View {
        let steps = SetupPane.guided, i = steps.firstIndex(of: m.pane) ?? 0, last = i == steps.count - 1
        return VStack(spacing: 0) {
            Rectangle().fill(Ink.text.opacity(0.09)).frame(height: 1)
            HStack(spacing: 18) {
                if let msg = m.message { Text(msg).font(.system(size: 13)).foregroundStyle(Ink.emberDeep).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                else { Text("Step \(i + 1) of \(steps.count)").font(.system(size: 13)).foregroundStyle(Ink.dim) }
                Spacer(minLength: 12)
                if i > 0 { Button("Back") { withAnimation(.spring(duration: 0.4, bounce: 0.12)) { m.pane = steps[i - 1] } }.buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.dim) }
                Button {
                    if last { if m.save() { done() } } else { withAnimation(.spring(duration: 0.4, bounce: 0.12)) { m.pane = steps[i + 1] } }
                } label: {
                    Text(last ? "Start using Dex Notch" : i == 0 ? "Begin" : "Continue").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black).lineLimit(1).fixedSize()
                        .padding(.horizontal, 22).padding(.vertical, 8).background(Capsule().fill(Ink.ember))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 48).padding(.vertical, 14)
        }
        .background(Color.black)
    }

    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Ink.text.opacity(0.09)).frame(height: 1)
            HStack(spacing: 18) {
                if let msg = m.message {
                    Text(msg).font(.system(size: 13)).foregroundStyle(Ink.emberDeep).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Cancel") { done() }.buttonStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .keyboardShortcut(.cancelAction)
                Button { if m.save() { done() } } label: {
                    Text("Save").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black).lineLimit(1).fixedSize()
                        .padding(.horizontal, 22).padding(.vertical, 8).background(Capsule().fill(Ink.ember))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 48).padding(.vertical, 14)
        }
        .background(Color.black)
    }
}

/// The window itself. Opens on first launch (no settings.json yet) and from the menu bar.
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    static let doneKey = "setupCompleted"
    /// First run walks through everything; anyone who already had a settings.json is an existing user and goes straight to the app.
    static var needsWalkthrough: Bool {
        if UserDefaults.standard.bool(forKey: doneKey) { return false }
        if FileManager.default.fileExists(atPath: Settings.defaultURL.path) { UserDefaults.standard.set(true, forKey: doneKey); return false }
        return true
    }

    private var model: SetupModel?

    func show(assistant: Assistant, guided: Bool = false, pane: SetupPane? = nil) {
        if let w = window { if let pane { model?.pane = pane }; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        assistant.refreshAvailability()
        let model = SetupModel(assistant: assistant); self.model = model
        if let pane { model.pane = pane }
        if guided { model.pane = .welcome }
        else if let p = ProcessInfo.processInfo.environment["NOTCH_OPEN_SETTINGS"]?.lowercased(), let pane = SetupPane.allCases.first(where: { $0.rawValue.lowercased() == p }) { model.pane = pane }
        let h = min(600, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SetupView.width, height: h), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Dex Notch"
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: SetupView(m: model, height: h, guided: guided) { [weak self] in self?.window?.close() })
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil; if guided { UserDefaults.standard.set(true, forKey: SetupWindow.doneKey) } }       // closed early: don't ask again, Settings is in the menu
        }
        window = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}
