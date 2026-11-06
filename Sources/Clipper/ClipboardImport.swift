import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardImport:Equatable {
    case file(URL), web(URL)

    static func read(_ pasteboard:NSPasteboard) -> Self? {
        // Finder's Copy carries file URLs, even when no readable text is present.
        if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],
           let file=urls.first(where:isVideoFile) { return .file(file) }
        if let text=pasteboard.string(forType:.string), let input=parse(text) { return input }
        if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL] {
            for url in urls {
                if let input=parse(url.absoluteString) { return input }
            }
        }
        return nil
    }

    static func parse(_ text:String) -> Self? {
        var text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.count >= 2, let first=text.first, ["\"","'"].contains(first), text.last == first {
            text=String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let url=URL(fileURLWithPath:(text as NSString).expandingTildeInPath)
            return isVideoFile(url) ? .file(url) : nil
        }
        if let url=URL(string:text), url.isFileURL {
            return isVideoFile(url) ? .file(url) : nil
        }
        if text.rangeOfCharacter(from:.whitespacesAndNewlines) == nil,
           let url=try? URLMedia.parseURL(text) { return .web(url) }
        // Link-bearing plain text also works, but multiple links are ambiguous.
        guard let detector=try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links=detector.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { result -> URL? in
            guard let url=result.url else { return nil }
            return try? URLMedia.parseURL(url.absoluteString)
        }
        return links.count == 1 ? .web(links[0]) : nil
    }

    private static func isVideoFile(_ url:URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&directory), !directory.boolValue,
              FileManager.default.isReadableFile(atPath:url.path) else { return false }
        let type=try? url.resourceValues(forKeys:[.contentTypeKey]).contentType
        return type?.conforms(to:.movie) == true || type?.conforms(to:.video) == true
            || ["mp4","mov","m4v","mkv","webm","avi","mpeg","mpg","ts","mts","m2ts","flv","wmv","ogv","3gp"].contains(url.pathExtension.lowercased())
    }
}

/// Handles the normal Edit > Paste action after text controls have had first refusal.
/// Installing after the window keeps the URL dialog and editable timestamps on native paste.
struct WindowPasteHandler:NSViewRepresentable {
    let editor:Editor
    func makeNSView(context:Context)->PasteHostView { PasteHostView(editor:editor) }
    func updateNSView(_ view:PasteHostView,context:Context) { view.handler.editor=editor }
    static func dismantleNSView(_ view:PasteHostView,coordinator:()) { view.uninstall() }

    final class PasteHostView:NSView {
        let handler=PasteResponder()
        private weak var attachedWindow:NSWindow?
        init(editor:Editor) { super.init(frame:.zero); handler.editor=editor }
        required init?(coder:NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard let window else { return }
            attachedWindow=window
            handler.nextResponder=window.nextResponder
            window.nextResponder=handler
        }
        func uninstall() {
            if let window=attachedWindow, window.nextResponder === handler { window.nextResponder=handler.nextResponder }
            attachedWindow=nil; handler.nextResponder=nil
        }
    }

    final class PasteResponder:NSResponder,NSUserInterfaceValidations {
        weak var editor:Editor?
        @objc func paste(_ sender:Any?) {
            guard let editor, editor.canPasteImport, let input=ClipboardImport.read(.general) else { return }
            editor.paste(input)
        }
        func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem)->Bool {
            item.action == #selector(paste(_:)) && editor?.canPasteImport == true && ClipboardImport.read(.general) != nil
        }
    }
}
