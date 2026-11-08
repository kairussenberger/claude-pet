// The chat transcript: a WKWebView rendering Markdown, KaTeX math and images from assets/web.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ChatLine: Identifiable, Codable {
    enum Kind: String, Codable { case user, assistant, tool, error, info }
    enum CodingKeys: String, CodingKey { case kind, text, images }   // ids are per-launch only
    let id = UUID()
    let kind: Kind
    var text: String
    var images: [String] = []       // pictures shown with the line: attached, or mentioned but not embedded

    var json: [String: Any] { ["kind": kind.rawValue, "text": text, "images": images] }
}

enum ChatImages {
    static let extensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic"]
    private static let extPattern = "\\.(?:" + extensions.joined(separator: "|") + ")"
    private static let embedded = try! NSRegularExpression(pattern: "!\\[[^\\]\\n]*\\]\\(\\s*<?([^)>\\n]+?)>?\\s*\\)")
    private static let mentioned = try! NSRegularExpression(
        pattern: "`([^`\\n]+\(extPattern))`|(?<![\\w/.\\]])(~?/[^\\s`'\"()<>\\[\\]]+\(extPattern))(?![\\w/])",
        options: .caseInsensitive)

    static func isImage(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// What Cmd+V should attach: copied files, or a clipboard image saved to a temp PNG.
    /// Empty when the clipboard holds text, which then pastes normally.
    static func pastedFiles(from pb: NSPasteboard) -> [URL] {
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL], !urls.isEmpty { return urls }
        guard pb.availableType(from: [.string]) == nil, let png = pngData(from: pb) else { return [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-pet-pasted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: file)) == nil ? [] : [file]
    }

    private static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = NSImage(pasteboard: pb)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// A path from a reply as a file URL: handles file://, ~, percent escapes and relative paths.
    static func resolve(_ raw: String, base: URL) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.lowercased().hasPrefix("file://") { path = URL(string: path)?.path ?? String(path.dropFirst(7)) }
        if !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath),
           let decoded = path.removingPercentEncoding { path = decoded }
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        return isImage(url) ? url.standardizedFileURL : nil
    }

    /// Existing image files named in the text but not already embedded with ![](…).
    static func mentioned(in text: String, base: URL) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var rest = text
        for m in embedded.matches(in: text, range: whole).reversed() {
            if let url = resolve(ns.substring(with: m.range(at: 1)), base: base) { seen.insert(url.path) }
            rest = (rest as NSString).replacingCharacters(in: m.range, with: "")
        }
        let restNS = rest as NSString
        var found: [String] = []
        for m in mentioned.matches(in: rest, range: NSRange(location: 0, length: restNS.length)) {
            let range = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard let url = resolve(restNS.substring(with: range), base: base),
                  FileManager.default.fileExists(atPath: url.path),
                  seen.insert(url.path).inserted else { continue }
            found.append(url.path)
        }
        return found
    }
}

/// Serves petchat://app/<asset> from the bundle and petchat://app/image?p=<path> from disk.
/// Only image files are readable from outside the bundle.
final class ChatSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "petchat"
    static let root: URL = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("web")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("web")
    }()

    var base = URL(fileURLWithPath: NSHomeDirectory())

    static func imageFile(_ url: URL, base: URL) -> URL? {
        guard url.path == "/image",
              let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value
        else { return nil }
        return ChatImages.resolve(p, base: base)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = Self.imageFile(url, base: base)
            ?? Self.root.appendingPathComponent(url.path).standardizedFileURL
        let allowed = url.path == "/image" ? Self.imageFile(url, base: base) != nil : file.path.hasPrefix(Self.root.standardizedFileURL.path + "/")
        guard allowed, let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Leaves file drags to the panel's SwiftUI onDrop instead of navigating to the dropped file.
final class ChatWebView: WKWebView {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct TranscriptView: NSViewRepresentable {
    let lines: [ChatLine]
    let running: Bool
    let workDir: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: ChatSchemeHandler.scheme)
        let web = ChatWebView(frame: .zero, configuration: config)
        web.unregisterDraggedTypes()
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "\(ChatSchemeHandler.scheme)://app/index.html")!))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, lines: lines, running: running, workDir: workDir)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let scheme = ChatSchemeHandler()
        private var ready = false
        private var lines: [ChatLine] = []
        private var running = false
        private var firstSent: UUID?
        private var sent = 0
        private var runningSent: Bool?

        func update(_ web: WKWebView, lines: [ChatLine], running: Bool, workDir: URL) {
            self.lines = lines
            self.running = running
            scheme.base = workDir
            sync(web)
        }

        /// The transcript only ever grows or restarts, so new lines are all the page needs.
        private func sync(_ web: WKWebView) {
            guard ready else { return }
            if sent > 0, lines.first?.id != firstSent {
                web.evaluateJavaScript("clearLines()")
                sent = 0
            }
            if lines.count > sent,
               let data = try? JSONSerialization.data(withJSONObject: lines[sent...].map(\.json)),
               let json = String(data: data, encoding: .utf8) {
                web.evaluateJavaScript("appendLines(\(json))")
                firstSent = lines.first?.id
                sent = lines.count
            }
            if runningSent != running {
                web.evaluateJavaScript("setRunning(\(running))")
                runningSent = running
            }
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            sent = 0
            runningSent = nil
            sync(web)
        }

        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            ready = false
            web.reload()
        }

        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, action.navigationType == .linkActivated else {
                decisionHandler(action.request.url?.scheme == ChatSchemeHandler.scheme ? .allow : .cancel)
                return
            }
            decisionHandler(.cancel)
            if url.scheme == ChatSchemeHandler.scheme {
                if let file = ChatSchemeHandler.imageFile(url, base: scheme.base) { NSWorkspace.shared.open(file) }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
