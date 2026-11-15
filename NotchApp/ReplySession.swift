import SwiftUI

/// One reply in progress: the email, the AI's draft, your changes to it, and the questions you asked about the email.
@MainActor @Observable
final class ReplySession {
    enum Tab { case draft, ask }
    enum Stage: Equatable { case needsPermission, loading, ready, failed(String) }
    enum Outcome: Equatable { case none, undo(Int), sending, sent, saved, failed(String) }
    struct Exchange: Identifiable { let id = UUID(); var question: String; var answer: String }

    let alert: AddonAlert
    var stage: Stage
    var context: MailContext?
    var draft = ""
    var drafting = false
    var backend: Backend
    var tab: Tab = .draft
    var input = ""
    var exchanges: [Exchange] = []
    var asking = false
    var outcome: Outcome = .none
    var note: String?                 // a quiet line under the draft: which agent wrote it, or why it couldn't

    init(alert: AddonAlert, stage: Stage, backend: Backend) { self.alert = alert; self.stage = stage; self.backend = backend }

    var busy: Bool { drafting || asking }
    /// Who the reply goes to, for the button: "Send to Priya Nair".
    var recipientName: String { context.flatMap { MailReply.recipient($0) }.map(Triage.displayName) ?? alert.sender }
    var canSend: Bool { stage == .ready && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && outcome == .none }
}
