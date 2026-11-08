// Past chats (saved transcripts you can reopen) and the chat panel's drag-to-resize edges.
import AppKit
import SwiftUI

struct ChatMeta: Codable, Identifiable, Equatable {
    let id: String
    var sessionId: String
    var workDir: String
    var title: String
    var updated: Date
}

/// An index plus one transcript file per chat, in ~/Library/Application Support/Claude Pet/chats.
/// The transcript is what the panel showed; Claude Code itself keeps the real session for --resume.
enum ChatStore {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude Pet/chats", isDirectory: true)
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }
    private static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func index() -> [ChatMeta] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? decoder.decode([ChatMeta].self, from: data) else { return [] }
        return list.sorted { $0.updated > $1.updated }
    }

    static func lines(_ id: String) -> [ChatLine] {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return [] }
        return (try? decoder.decode([ChatLine].self, from: data)) ?? []
    }

    /// Writes the transcript and returns the updated index.
    @discardableResult
    static func save(_ meta: ChatMeta, lines: [ChatLine]) -> [ChatMeta] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoder.encode(lines).write(to: fileURL(meta.id), options: .atomic)
        var list = index().filter { $0.id != meta.id }
        list.insert(meta, at: 0)
        writeIndex(list)
        return list
    }

    @discardableResult
    static func delete(_ id: String) -> [ChatMeta] {
        try? FileManager.default.removeItem(at: fileURL(id))
        let list = index().filter { $0.id != id }
        writeIndex(list)
        return list
    }

    private static func writeIndex(_ list: [ChatMeta]) {
        try? encoder.encode(list).write(to: indexURL, options: .atomic)
    }

    static func title(for lines: [ChatLine]) -> String {
        guard let first = lines.first(where: { $0.kind == .user }) else { return "Untitled chat" }
        let text = first.text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if text.isEmpty { return first.images.isEmpty ? "Untitled chat" : "Image" }
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

// MARK: - History list

struct HistoryList: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        if session.history.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22))
                Text("No past chats yet").font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.history) { meta in
                        HistoryRow(meta: meta, current: meta.id == session.chatId,
                                   open: { session.open(meta) }, delete: { session.deleteChat(meta) })
                    }
                }
                .padding(6)
            }
        }
    }
}

struct HistoryRow: View {
    let meta: ChatMeta
    let current: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(current ? ClaudeStyle.clay : .clear).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(meta.workDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(Self.relative.localizedString(for: meta.updated, relativeTo: Date()))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hover {
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete this chat")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? ClaudeStyle.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}

// MARK: - Resizing

/// Invisible strips along the chat panel's edges and corners that resize the window when dragged.
struct ResizeEdges: View {
    private let t: CGFloat = 6, corner: CGFloat = 14

    var body: some View {
        ZStack {
            handle([.top]).frame(height: t).frame(maxHeight: .infinity, alignment: .top).padding(.horizontal, corner)
            handle([.bottom]).frame(height: t).frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, corner)
            handle([.left]).frame(width: t).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, corner)
            handle([.right]).frame(width: t).frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, corner)
            handle([.top, .left]).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            handle([.top, .right]).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            handle([.bottom, .left]).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            handle([.bottom, .right]).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func handle(_ edges: ResizeHandle.Edges) -> some View { ResizeHandle(edges: edges) }
}

struct ResizeHandle: NSViewRepresentable {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }
    static let minSize = NSSize(width: 300, height: 260)

    let edges: Edges
    func makeNSView(context: Context) -> HandleView { HandleView(edges: edges) }
    func updateNSView(_ v: HandleView, context: Context) {}

    final class HandleView: NSView {
        let edges: Edges
        private var start: (frame: NSRect, mouse: NSPoint)?

        init(edges: Edges) { self.edges = edges; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

        private var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition
                switch edges {
                case [.top, .left]: pos = .topLeft
                case [.top, .right]: pos = .topRight
                case [.bottom, .left]: pos = .bottomLeft
                case [.bottom, .right]: pos = .bottomRight
                case [.top]: pos = .top
                case [.bottom]: pos = .bottom
                case [.left]: pos = .left
                default: pos = .right
                }
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return edges.isDisjoint(with: [.left, .right]) ? .resizeUpDown : .resizeLeftRight
        }

        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            start = (w.frame, NSEvent.mouseLocation)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window, let s = start else { return }
            let m = NSEvent.mouseLocation
            let dx = m.x - s.mouse.x, dy = m.y - s.mouse.y
            let maxSize = (w.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 4000, height: 4000)
            let minS = ResizeHandle.minSize
            var f = s.frame
            func clampW(_ v: CGFloat) -> CGFloat { min(max(v, minS.width), maxSize.width) }
            func clampH(_ v: CGFloat) -> CGFloat { min(max(v, minS.height), maxSize.height) }
            if edges.contains(.right) { f.size.width = clampW(s.frame.width + dx) }
            if edges.contains(.left) { f.size.width = clampW(s.frame.width - dx); f.origin.x = s.frame.maxX - f.width }
            if edges.contains(.top) { f.size.height = clampH(s.frame.height + dy) }
            if edges.contains(.bottom) { f.size.height = clampH(s.frame.height - dy); f.origin.y = s.frame.maxY - f.height }
            w.setFrame(f.integral, display: true)
            w.invalidateShadow()
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            MainActor.assumeIsolated { PetApp.shared.chatResized() }
        }
    }
}
