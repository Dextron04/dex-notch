import SwiftUI
import AVKit

/// The update card grown into a page: every release you haven't got yet, scrollable, with the screenshots, animated gifs and videos from the changelog.
struct WhatsNewPanel: View {
    var c: AddonCenter
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image("AppMark").resizable().frame(width: 17, height: 17).accessibilityHidden(true)
                    Text("Dex Notch").font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
                Color.clear.frame(width: notch.width)
                Text("What's new").font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.text.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 26)
            }
            .frame(height: notch.height)

            Group {
                switch c.notesState {
                case .loading: Text("Loading the release notes…").font(.system(size: 13)).foregroundStyle(Ink.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed: Text("Couldn't load the notes. You're offline, or GitHub didn't answer.").font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.center).padding(.horizontal, 40).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(c.notes.enumerated()), id: \.offset) { i, b in row(b, first: i == 0) }
                        }
                        .padding(.horizontal, 30).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 22) {
                Button { c.open() } label: {
                    HStack(spacing: 6) { Text(AppUpdater.shared.readyVersion != nil ? "Restart to update" : "Update").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember); key("⌥↩") }.contentShape(Rectangle())
                }
                .keyboardShortcut(.return, modifiers: .option)
                Button { c.closeNotes() } label: {
                    HStack(spacing: 6) { Text("Close").font(.system(size: 14)).foregroundStyle(Ink.dim); key("esc") }.contentShape(Rectangle())
                }
                Spacer(minLength: 8)
                Link("All releases", destination: URL(string: "https://github.com/\(Changelog.repo)/releases")!).font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28).frame(height: 44)
            .background(Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.horizontal, 26), alignment: .top)
        }
        .frame(width: AlertView.notesWidth)
    }

    private func key(_ k: String) -> some View {
        Text(k).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.text.opacity(0.6))
            .padding(.horizontal, 5).padding(.vertical, 1.5).overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.text.opacity(0.22), lineWidth: 0.75))
    }

    @ViewBuilder private func row(_ b: Changelog.Block, first: Bool) -> some View {
        switch b {
        case .release(let v, let t):
            VStack(alignment: .leading, spacing: 3) {
                Text("VERSION \(v)").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Ink.ember)
                if !t.isEmpty { Text(t).font(.system(size: 19, weight: .semibold)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.top, first ? 0 : 22)
        case .date(let d): Text(d).font(.system(size: 12)).foregroundStyle(Ink.dim)
        case .text(let s): Text(inline(s)).font(.system(size: 13.5)).foregroundStyle(Ink.text.opacity(0.9)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•").font(.system(size: 13.5)).foregroundStyle(Ink.ember)
                Text(inline(s)).font(.system(size: 13.5)).foregroundStyle(Ink.text.opacity(0.9)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        case .image(let u, let alt): RemoteImage(url: u, alt: alt)
        case .video(let u, let t): VideoClip(url: u, title: t)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A png, jpg or animated gif. Loaded when the page opens; if it can't be, the picture's description stands in.
private struct RemoteImage: View {
    let url: URL, alt: String
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Animated(image: image).aspectRatio(image.size, contentMode: .fit).frame(maxWidth: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.text.opacity(0.1), lineWidth: 0.75))
                    .accessibilityLabel(alt)
            } else if failed { Text(alt).font(.system(size: 12)).italic().foregroundStyle(Ink.dim) }
            else { RoundedRectangle(cornerRadius: 10).fill(Ink.text.opacity(0.05)).frame(height: 120).frame(maxWidth: 520) }
        }
        .task(id: url) {
            guard let (d, _) = try? await URLSession.shared.data(from: url), let i = NSImage(data: d) else { failed = true; return }
            image = i
        }
    }
    /// NSImageView plays a gif by itself; SwiftUI's Image would show one frame.
    private struct Animated: NSViewRepresentable {
        let image: NSImage
        func makeNSView(context: Context) -> NSImageView {
            let v = NSImageView(image: image); v.animates = true; v.imageScaling = .scaleProportionallyUpOrDown
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return v
        }
        func updateNSView(_ v: NSImageView, context: Context) { v.image = image }
    }
}

/// An mp4 with its own play control. It starts paused on its first frame and never makes a sound until you press play.
private struct VideoClip: View {
    let url: URL, title: String
    @State private var player: AVPlayer?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Player(player: player).aspectRatio(16.0 / 10.0, contentMode: .fit).frame(maxWidth: 520)
                .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.text.opacity(0.1), lineWidth: 0.75))
            if !title.isEmpty { Text(title).font(.system(size: 12)).foregroundStyle(Ink.dim) }
        }
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
        .onDisappear { player?.pause() }
    }
    private struct Player: NSViewRepresentable {
        let player: AVPlayer?
        func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.controlsStyle = .inline; v.videoGravity = .resizeAspect; return v }
        func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
    }
}
