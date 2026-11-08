// Claude Pet — a draggable desktop buddy that fronts Claude Code (`claude -p`, headless).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Claude Code runner

@MainActor
final class ClaudeSession: ObservableObject {
    @Published var lines: [ChatLine] = []
    @Published var attachments: [URL] = []
    @Published var running = false
    @Published var chatOpen = false
    @Published var mood: Mood = .idle
    @Published var workDir: URL
    @Published var lastReply = ""
    @Published var history: [ChatMeta] = ChatStore.index()
    @Published var showingHistory = false

    enum Mood { case idle, thinking, happy, sad }

    private(set) var sessionId: String?
    private(set) var chatId: String?        // this chat's entry in ChatStore, once saved
    private var savedCount = 0
    private var generation = 0              // bumped when a run is abandoned, so its late output is dropped
    private var process: Process?
    private var buffer = Data()

    /// Screenshots live in the per-user temp folder and are overwritten by the next capture.
    static let screenDir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-pet-screen").path

    /// Tells Claude what this panel can display (see Sources/Transcript.swift) and how to see the screen.
    static func panelPrompt(screenAllowed: Bool) -> String {
        let shots = (1...4).map { "screen-\($0).png" }.joined(separator: " ")
        let howToLook = screenAllowed ? """
            look at their screen before you answer or ask them anything: run \
            `rm -rf \(screenDir) && mkdir -p \(screenDir) && cd \(screenDir) && screencapture -x \(shots)`, \
            then Read each screen-N.png in that folder that exists (one per connected display). Capture again for every \
            new request, since the screen changes. The small chat panel and the cartoon pet are this app, \
            so ignore them. Mention briefly what you saw. Do not capture for self-contained requests.
            """ : """
            you would normally look at their screen, but Screen Recording permission is missing. Do not try \
            to capture or search for old screenshots. Tell them to allow Claude Pet under System Settings > Privacy & Security > \
            Screen & System Audio Recording, then reopen the Pet.
            """
        return """
            You are replying in the Claude Pet chat panel, a small desktop chat about 350 px wide. \
            It renders GitHub-flavored Markdown, LaTeX math (KaTeX) and images inline.
            - Math: write every formula, variable and unit-bearing quantity in LaTeX, inline as $...$ and \
            display as $$...$$ on its own lines. Never use Unicode or plain-text approximations, and never \
            put math in a code block. Do not make a PDF to show math.
            - Images: to show a plot, diagram or any other picture, save it as a PNG (in /tmp/claude-pet/ \
            unless the user names a location) and embed it in your reply with ![short description](/absolute/path.png), \
            writing the path as <path> inside the parentheses if it contains spaces. It appears right in the chat, \
            so do not wrap it in a PDF or open it in another app.
            - Only produce a PDF when the user explicitly asks for one.
            - Screen: when a request needs context the user has not given, such as "this", "that error", \
            "what does this mean" or "fix it", and the conversation, attached files and working directory \
            do not settle it, \(howToLook)
            """
    }

    init() {
        let d = UserDefaults.standard
        workDir = URL(fileURLWithPath: d.string(forKey: "workDir") ?? NSHomeDirectory())
    }

    func setWorkDir(_ url: URL) {
        workDir = url
        UserDefaults.standard.set(url.path, forKey: "workDir")
        newChat()
        lines.append(.init(kind: .info, text: "Working in \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"))
    }

    func attach(_ urls: [URL]) {
        for u in urls where !attachments.contains(u) { attachments.append(u) }
    }

    func newChat() {
        saveChat()
        stop()
        if running { generation += 1; running = false; process = nil; mood = .idle }
        sessionId = nil
        chatId = nil
        savedCount = 0
        lines = []
        lastReply = ""
    }

    /// Reopen a past chat: its transcript, folder and Claude session, so the next message resumes it.
    func open(_ meta: ChatMeta) {
        showingHistory = false
        guard meta.id != chatId else { return }
        newChat()
        workDir = URL(fileURLWithPath: meta.workDir)
        UserDefaults.standard.set(meta.workDir, forKey: "workDir")
        sessionId = meta.sessionId
        chatId = meta.id
        lines = ChatStore.lines(meta.id)
        savedCount = lines.count
        lastReply = lines.last { $0.kind == .assistant }?.text ?? ""
    }

    func deleteChat(_ meta: ChatMeta) {
        if meta.id == chatId { chatId = nil; savedCount = lines.count }   // keep it on screen, just forget it
        history = ChatStore.delete(meta.id)
    }

    /// Saves the transcript if it has a Claude session and changed since the last save.
    func saveChat() {
        guard let sid = sessionId, lines.count != savedCount, lines.contains(where: { $0.kind == .user }) else { return }
        let id = chatId ?? UUID().uuidString
        chatId = id
        let meta = ChatMeta(id: id, sessionId: sid, workDir: workDir.path, title: ChatStore.title(for: lines), updated: Date())
        history = ChatStore.save(meta, lines: lines)
        savedCount = lines.count
    }

    static func claudePath() -> String? {
        let fm = FileManager.default
        let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "~/.npm-global/bin/claude"]
            .map { ($0 as NSString).expandingTildeInPath }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let claude = Self.claudePath() else {
            lines.append(.init(kind: .error, text: "Couldn't find the `claude` binary."))
            return
        }

        var full = trimmed
        if !attachments.isEmpty {
            full += "\n\nAttached files:\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        let others = attachments.filter { !ChatImages.isImage($0) }
        let shown = [trimmed, others.isEmpty ? "" : "📎 " + others.map(\.lastPathComponent).joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        lines.append(.init(kind: .user, text: shown, images: attachments.filter(ChatImages.isImage).map(\.path)))

        var args = ["-p", full, "--output-format", "stream-json", "--verbose"]
        if Self.skipPermissions { args.append("--dangerously-skip-permissions") }
        args += ["--append-system-prompt", Self.panelPrompt(screenAllowed: CGPreflightScreenCaptureAccess())]
        let dirs = Set(attachments.map { $0.hasDirectoryPath ? $0.path : $0.deletingLastPathComponent().path })
        for dir in dirs where dir != workDir.path { args += ["--add-dir", dir] }
        if let sid = sessionId { args += ["--resume", sid] }
        attachments = []

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer = Data()
        let gen = generation

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in if self?.generation == gen { self?.ingest(chunk) } }
        }
        p.terminationHandler = { [weak self] proc in
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                if self?.generation == gen { self?.finished(status: proc.terminationStatus, stderr: errText) }
            }
        }

        do {
            try p.run()
            process = p
            running = true
            mood = .thinking
        } catch {
            lines.append(.init(kind: .error, text: "Failed to launch claude: \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
        }
    }

    private func handle(_ ev: [String: Any]) {
        if let sid = ev["session_id"] as? String { sessionId = sid }
        switch ev["type"] as? String {
        case "assistant":
            let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.isEmpty {
                        lines.append(.init(kind: .assistant, text: t, images: ChatImages.mentioned(in: t, base: workDir)))
                        lastReply = t
                    }
                case "tool_use":
                    lines.append(.init(kind: .tool, text: Self.describeTool(block)))
                default: break
                }
            }
        case "result":
            if ev["is_error"] as? Bool == true {
                let msg = ev["result"] as? String ?? (ev["subtype"] as? String ?? "error")
                lines.append(.init(kind: .error, text: msg))
                mood = .sad
            } else {
                mood = .happy
            }
        default: break
        }
    }

    static func describeTool(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["url"]
                      ?? input["description"] ?? input["query"]) as? String
        guard var d = detail else { return name }
        d = d.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if d.count > 70 { d = String(d.prefix(70)) + "…" }
        return "\(name)  \(d)"
    }

    private func finished(status: Int32, stderr: String) {
        if !buffer.isEmpty { ingest(Data([0x0A])) }
        running = false
        process = nil
        if status != 0 && mood != .sad {
            let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(.init(kind: status == 2 || status == 130 || status == 15 ? .info : .error,
                               text: e.isEmpty ? "Stopped (exit \(status))." : e))
            mood = .sad
        }
        saveChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.running == false { self?.mood = .idle }
        }
    }

    /// Off by default: Claude then follows your normal Claude Code permission settings, and in the
    /// headless chat any tool you haven't allowed (e.g. in ~/.claude/settings.json) is refused.
    /// Turn on from the ✨ menu to run with --dangerously-skip-permissions.
    static var skipPermissions: Bool {
        get { UserDefaults.standard.bool(forKey: "skipPermissions") }
        set { UserDefaults.standard.set(newValue, forKey: "skipPermissions") }
    }

    /// Continue this conversation interactively in iTerm.
    func openInTerminal() {
        let dir = workDir.path.replacingOccurrences(of: "'", with: "'\\''")
        var cmd = "cd '\(dir)' && claude" + (Self.skipPermissions ? " --dangerously-skip-permissions" : "")
        if let sid = sessionId { cmd += " --resume \(sid)" }
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escaped)"
            end tell
            """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

// MARK: - Pet

struct PetView: View {
    @ObservedObject var session: ClaudeSession
    @State private var hop = false
    @State private var dropHover = false
    @State private var squish = false

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .top) {
                ChibiSprite(t: t, mood: session.mood, hopping: hop)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .scaleEffect(x: squish ? 1.1 : 1, y: squish ? 0.88 : 1, anchor: .bottom)
                    .offset(y: hop ? -16 : 0)
                    .scaleEffect(dropHover ? 1.08 : 1, anchor: .bottom)

                if session.mood != .idle {
                    MoodBubble(mood: session.mood, t: t)
                        .offset(x: 50, y: -8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: hop)
        .animation(.spring(response: 0.25, dampingFraction: 0.45), value: squish)
        .animation(.spring(response: 0.3), value: dropHover)
        .animation(.easeInOut(duration: 0.2), value: session.mood)
        .overlay(DragHandle(onClick: poke))
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            loadFiles(providers) { session.attach($0); celebrate() }
            return true
        }
        .onChange(of: session.mood) { _, m in if m == .happy { celebrate() } }
    }

    private func poke() {
        squish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { squish = false; celebrate() }
    }

    private func celebrate() {
        hop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { hop = false }
    }
}

/// The pet: assets/pet.png (default drawn by tools/placeholder.swift), rocked and squashed in
/// code, with a glint sweeping across its shades (masked by assets/pet_lens.png, optional).
struct ChibiSprite: View {
    let t: Double
    let mood: ClaudeSession.Mood
    var hopping = false

    static func resource(_ name: String) -> NSImage? {
        Bundle.main.image(forResource: name)
            ?? NSImage(contentsOfFile: (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/\(name).png")
    }
    static let image = resource("pet") ?? NSImage(systemSymbolName: "crown", accessibilityDescription: nil)!
    static let lens = resource("pet_lens")
    static let aspect = image.size.width / image.size.height

    var body: some View {
        let thinking = mood == .thinking
        let waddle = thinking ? sin(t * 7) * 6 : sin(t * 1.3) * 1.5
        let bounce = thinking ? -abs(sin(t * 7)) * 3 : 0
        let breathe = 1 + sin(t * 2.4) * 0.02
        let cycle = thinking ? 1.6 : 5.0, sweep = 0.6                       // glint: faster while working
        let gp = t.truncatingRemainder(dividingBy: cycle)
        let glint = gp < sweep ? gp / sweep : -1

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                Ellipse().fill(.black.opacity(0.2))
                    .frame(width: hopping ? 70 : 110, height: 8)
                    .offset(y: 3)
                Image(nsImage: Self.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .overlay { if glint >= 0, let lens = Self.lens { shine(glint, mask: lens) } }
                    .scaleEffect(x: 1 + (breathe - 1) * 0.5, y: breathe, anchor: .bottom)
                    .rotationEffect(.degrees(waddle), anchor: .bottom)
                    .offset(y: bounce)
            }
        }
    }

    private func shine(_ phase: Double, mask: NSImage) -> some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.12, height: g.size.height * 1.5)
                .rotationEffect(.degrees(25))
                .position(x: g.size.width * (0.1 + phase * 0.8), y: g.size.height / 2)
        }
        .mask(Image(nsImage: mask).resizable().aspectRatio(Self.aspect, contentMode: .fit))
        .allowsHitTesting(false)
    }
}

struct MoodBubble: View {
    let mood: ClaudeSession.Mood
    let t: Double
    var body: some View {
        Group {
            switch mood {
            case .thinking:
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle().frame(width: 5, height: 5)
                            .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.8)))
                    }
                }
            case .happy: Text("✓").font(.system(size: 13, weight: .heavy))
            case .sad: Text("?!").font(.system(size: 12, weight: .heavy))
            case .idle: EmptyView()
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(.white).shadow(color: .black.opacity(0.25), radius: 3, y: 1))
    }
}

/// Transparent NSView over the pet: drags the window natively, reports plain clicks.
struct DragHandle: NSViewRepresentable {
    let onClick: () -> Void
    func makeNSView(context: Context) -> HandleView { HandleView(onClick: onClick) }
    func updateNSView(_ v: HandleView, context: Context) { v.onClick = onClick }

    final class HandleView: NSView {
        var onClick: () -> Void
        init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            let before = w.frame.origin
            w.performDrag(with: event)
            if w.frame.origin == before { onClick() } else { PetApp.shared.savePosition() }
        }
        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(PetApp.shared.makeMenu(), with: event, for: self)
        }
        // let file drags fall through to SwiftUI's onDrop
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .rightMouseDown { return super.hitTest(point) }
            return nil
        }
    }
}

func loadFiles(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

/// Claude-app palette: clay accent, ivory / warm-charcoal surfaces.
enum ClaudeStyle {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)         // #D97757
    static let surface = dynamic(light: (0.980, 0.976, 0.961), dark: (0.188, 0.188, 0.180))   // #FAF9F5 / #30302E
    static let hover = dynamic(light: (0.941, 0.933, 0.902), dark: (0.239, 0.239, 0.227))     // #F0EEE6 / #3D3D3A
    static let text = dynamic(light: (0.239, 0.239, 0.227), dark: (0.761, 0.753, 0.714))      // #3D3D3A / #C2C0B6
    static let hairline = dynamic(light: (0.122, 0.118, 0.114, 0.12), dark: (1, 1, 1, 0.10))
    static let track = dynamic(light: (0.941, 0.933, 0.902), dark: (0.149, 0.149, 0.141))     // segmented-control trough
    static let segment = dynamic(light: (1, 1, 1), dark: (0.255, 0.255, 0.243))              // selected segment
    static let iconOn = dynamic(light: (0.122, 0.118, 0.114), dark: (0.925, 0.918, 0.890))
    static let iconOff = dynamic(light: (0.45, 0.45, 0.43), dark: (0.70, 0.69, 0.66))

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        dynamic(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }
    static func dynamic(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let c = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}

/// Rounded chat bubble with a small circle notched into its lower right, like the Claude app's chat icon.
struct ChatGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * 0.40
        let c = CGPoint(x: rect.minX + r + rect.width * 0.08, y: rect.minY + r + rect.height * 0.06)
        var p = Path()
        // bubble outline with a gap where the small circle sits, tail at lower left
        p.addArc(center: c, radius: r, startAngle: .degrees(75), endAngle: .degrees(20), clockwise: false)
        p.move(to: CGPoint(x: c.x + cos(.pi * 0.62) * r, y: c.y + sin(.pi * 0.62) * r))
        p.addLine(to: CGPoint(x: c.x - r * 0.75, y: c.y + r * 1.05))
        p.addLine(to: CGPoint(x: c.x + cos(.pi * 0.82) * r, y: c.y + sin(.pi * 0.82) * r))
        let s = r * 0.42
        p.addEllipse(in: CGRect(x: c.x + r * 0.62 - s, y: c.y + r * 0.62 - s, width: s * 2, height: s * 2))
        return p.strokedPath(StrokeStyle(lineWidth: max(1.5, r * 0.2), lineCap: .round, lineJoin: .round))
    }
}

struct RootView: View {
    @ObservedObject var session: ClaudeSession
    @State private var plusHover = false
    @State private var askHover = false
    @State private var addHover = false

    var body: some View {
        VStack(spacing: 4) {
            PetView(session: session)
                .frame(width: 150, height: 145)
            controls
        }
        .padding(.top, 24)   // headroom for the hop and the mood bubble
        .padding(.bottom, 8)
        .frame(width: 176)
    }

    /// Segmented two-button control in the Claude app's style.
    private var controls: some View {
        HStack(spacing: 2) {
            Segment(selected: session.chatOpen, hover: askHover) {
                ChatGlyph().frame(width: 17, height: 17)
            } action: { PetApp.shared.toggleChat() }
            .onHover { askHover = $0 }
            .help(session.chatOpen ? "Close chat (Esc)" : "Prompt Claude Code")

            Segment(selected: plusHover, hover: addHover) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
            } action: { PetApp.shared.pickFiles() }
            .overlay(alignment: .topTrailing) {
                if !session.attachments.isEmpty {
                    Text("\(session.attachments.count)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Circle().fill(ClaudeStyle.clay))
                        .offset(x: 3, y: -3)
                }
            }
            .onHover { addHover = $0 }
            .help("Drop files here (or click to pick)")
            .onDrop(of: [.fileURL], isTargeted: $plusHover) { providers in
                loadFiles(providers) { urls in
                    session.attach(urls)
                    PetApp.shared.showChat()
                }
                return true
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ClaudeStyle.track))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ClaudeStyle.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .scaleEffect(plusHover ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: plusHover)
    }
}

struct Segment<Icon: View>: View {
    let selected: Bool
    let hover: Bool
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(selected || hover ? ClaudeStyle.iconOn : ClaudeStyle.iconOff)
                .frame(width: 40, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? ClaudeStyle.segment : hover ? ClaudeStyle.segment.opacity(0.5) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? ClaudeStyle.hairline : .clear, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

// MARK: - Chat panel

struct ChatView: View {
    @ObservedObject var session: ClaudeSession
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ZStack {
                VStack(spacing: 0) {
                    transcript
                    if !session.attachments.isEmpty { attachmentRow }
                    inputRow
                }
                if session.showingHistory {
                    HistoryList(session: session)
                        .background(ClaudeStyle.surface)
                }
            }
        }
        .frame(minWidth: ResizeHandle.minSize.width, maxWidth: .infinity,
               minHeight: ResizeHandle.minSize.height, maxHeight: .infinity)
        .background(ClaudeStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(dropHover ? ClaudeStyle.clay : ClaudeStyle.hairline, lineWidth: dropHover ? 2 : 0.5))
        .overlay(ResizeEdges())
        .foregroundStyle(ClaudeStyle.text)
        .tint(ClaudeStyle.clay)
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            loadFiles(providers) { session.attach($0) }
            return true
        }
        .onAppear { focused = true }
        .onChange(of: session.chatOpen) { _, open in if open { focused = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(session.running ? .orange : .green).frame(width: 7, height: 7)
            Button {
                PetApp.shared.pickWorkDir()
            } label: {
                Label(session.workDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                      systemImage: "folder")
                    .lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .help("Change working directory")
            Spacer()
            Button { session.openInTerminal() } label: { Image(systemName: "terminal") }
                .buttonStyle(.plain).help("Continue in iTerm")
            Button { session.showingHistory = false; session.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).help("New conversation")
            Button { session.showingHistory.toggle() } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(session.showingHistory ? ClaudeStyle.clay : ClaudeStyle.text)
            }
            .buttonStyle(.plain).help(session.showingHistory ? "Back to chat" : "Past chats")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var transcript: some View {
        TranscriptView(lines: session.lines, running: session.running, workDir: session.workDir)
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.attachments, id: \.self) { url in
                    if ChatImages.isImage(url) {
                        ImageChip(url: url) { session.attachments.removeAll { $0 == url } }
                    } else {
                        HStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
                            Text(url.lastPathComponent).lineLimit(1)
                            Button { session.attachments.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.quaternary))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude Code…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(ClaudeStyle.hover))
            Button {
                session.running ? session.stop() : send()
            } label: {
                Image(systemName: session.running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ClaudeStyle.clay))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(session.running ? "." : .return, modifiers: .command)
        }
        .padding(10)
    }

    private func send() {
        guard !session.running else { return }
        session.send(draft)
        draft = ""
    }
}

/// Thumbnail of an attached image, waiting to be sent.
struct ImageChip: View {
    let url: URL
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ClaudeStyle.hairline, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain).padding(2)
        }
        .help(url.lastPathComponent)
        .onAppear { thumbnail = NSImage(contentsOf: url) }
    }
}

// MARK: - Windows

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// fitsContent: the window takes the SwiftUI content's size; otherwise the content fills the window.
    init(content: some View, fitsContent: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = fitsContent ? [.intrinsicContentSize] : []
        contentView = host
        setContentSize(fitsContent ? host.fittingSize : NSSize(width: 380, height: 440))
    }
}

@MainActor
final class PetApp: NSObject, NSApplicationDelegate {
    static let shared = PetApp()
    let session = ClaudeSession()
    var petWindow: FloatingPanel!
    var chatWindow: FloatingPanel!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        petWindow = FloatingPanel(content: RootView(session: session))
        chatWindow = FloatingPanel(content: ChatView(session: session), fitsContent: false)
        chatWindow.hasShadow = true
        if let s = UserDefaults.standard.string(forKey: "chatSize") {
            let size = NSSizeFromString(s)
            chatWindow.setContentSize(NSSize(width: max(size.width, ResizeHandle.minSize.width),
                                             height: max(size.height, ResizeHandle.minSize.height)))
        }

        if let s = UserDefaults.standard.string(forKey: "petOrigin") {
            petWindow.setFrameOrigin(NSPointFromString(s))
        } else if let vf = NSScreen.main?.visibleFrame {
            petWindow.setFrameOrigin(NSPoint(x: vf.maxX - petWindow.frame.width - 40, y: vf.minY + 40))
        }
        clampToScreen()
        petWindow.orderFrontRegardless()

        installEditMenu()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        // Esc closes the chat panel; Cmd+V attaches clipboard images and files
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            guard event.keyCode == 53 || isPaste else { return event }
            let handled = MainActor.assumeIsolated {
                let app = PetApp.shared
                guard app.session.chatOpen else { return false }
                if !isPaste, app.session.showingHistory { app.session.showingHistory = false; return true }
                if isPaste {
                    let files = ChatImages.pastedFiles(from: .general)
                    app.session.attach(files)
                    return !files.isEmpty
                }
                app.hideChat()
                return true
            }
            return handled ? nil : event
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude Pet")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
    }

    /// Never shown (the app has no menu bar), but it's what routes Cmd+C/V/X/A/Z to the focused view.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(item)
    }

    // build the menu fresh on each click so titles/checkmarks are current
    @objc func statusClicked() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: session.chatOpen ? "Hide chat" : "Open chat", action: #selector(toggleChatAction), keyEquivalent: "")
        m.addItem(withTitle: "New conversation", action: #selector(newChatAction), keyEquivalent: "")
        m.addItem(withTitle: "Working directory…", action: #selector(workDirAction), keyEquivalent: "")
        m.addItem(withTitle: "Continue in iTerm", action: #selector(terminalAction), keyEquivalent: "")
        let skip = m.addItem(withTitle: "Skip permission prompts (risky)", action: #selector(toggleSkipAction), keyEquivalent: "")
        skip.state = ClaudeSession.skipPermissions ? .on : .off
        if !CGPreflightScreenCaptureAccess() {
            m.addItem(withTitle: "Allow screen access…", action: #selector(screenAccessAction), keyEquivalent: "")
        }
        m.addItem(.separator())
        m.addItem(withTitle: petWindow.isVisible ? "Hide pet" : "Show pet", action: #selector(togglePetAction), keyEquivalent: "")
        m.addItem(withTitle: "Quit Claude Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for it in m.items where it.action != #selector(NSApplication.terminate(_:)) { it.target = self }
        return m
    }

    func applicationWillTerminate(_ note: Notification) { session.saveChat() }

    @objc func toggleChatAction() { toggleChat() }
    @objc func newChatAction() { session.newChat() }
    @objc func workDirAction() { pickWorkDir() }
    @objc func terminalAction() { session.openInTerminal() }
    @objc func toggleSkipAction() {
        if ClaudeSession.skipPermissions { ClaudeSession.skipPermissions = false; return }
        let a = NSAlert()
        a.messageText = "Skip all permission prompts?"
        a.informativeText = "Claude will run commands and edit files in the working directory without asking (--dangerously-skip-permissions). Only turn this on if you trust what you ask it to do."
        a.addButton(withTitle: "Turn on"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { ClaudeSession.skipPermissions = true }
    }
    @objc func screenAccessAction() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func togglePetAction() {
        if petWindow.isVisible { hideChat(); petWindow.orderOut(nil) } else { petWindow.orderFrontRegardless() }
    }

    func toggleChat() { session.chatOpen ? hideChat() : showChat() }

    func showChat() {
        if !petWindow.isVisible { petWindow.orderFrontRegardless() }
        session.chatOpen = true
        positionChat()
        if chatWindow.parent == nil { petWindow.addChildWindow(chatWindow, ordered: .above) }
        NSApp.activate(ignoringOtherApps: true)
        chatWindow.makeKeyAndOrderFront(nil)
    }

    func hideChat() {
        session.chatOpen = false
        session.showingHistory = false
        petWindow.removeChildWindow(chatWindow)
        chatWindow.orderOut(nil)
    }

    /// Put the chat beside the pet on whichever side has room, bottom-aligned with the pet.
    func positionChat() {
        let pet = petWindow.frame
        let size = chatWindow.frame.size
        let vf = (petWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = pet.minX - size.width + 10
        if x < vf.minX { x = pet.maxX - 10 }
        var y = pet.minY + 20
        y = min(max(y, vf.minY), vf.maxY - size.height)
        chatWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Remembers the size the chat was dragged to, keeping it on screen and beside the pet.
    func chatResized() {
        UserDefaults.standard.set(NSStringFromSize(chatWindow.frame.size), forKey: "chatSize")
        let f = chatWindow.frame
        let vf = (chatWindow.screen ?? NSScreen.main)?.visibleFrame ?? f
        let y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        let x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        chatWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func savePosition() {
        clampToScreen()
        UserDefaults.standard.set(NSStringFromPoint(petWindow.frame.origin), forKey: "petOrigin")
        if session.chatOpen { positionChat() }
    }

    private func clampToScreen() {
        let f = petWindow.frame
        guard let vf = (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main)?.visibleFrame else { return }
        let x = min(max(f.minX, vf.minX - 20), vf.maxX - f.width + 20)
        let y = min(max(f.minY, vf.minY - 10), vf.maxY - f.height)
        petWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.level = .modalPanel
        if p.runModal() == .OK {
            session.attach(p.urls)
            showChat()
        }
    }

    func pickWorkDir() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = session.workDir
        p.prompt = "Use folder"
        p.level = .modalPanel
        if p.runModal() == .OK, let u = p.url { session.setWorkDir(u) }
        if session.chatOpen { showChat() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = PetApp.shared
    app.run()
}
