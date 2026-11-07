import SwiftUI
import AppKit

@main struct ClipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var editor=Editor()
    var body: some Scene {
        WindowGroup {
            EditorView(editor:editor,playback:editor.playback)
                .onAppear { delegate.editor=editor; delegate.deliverPending() }
                .onOpenURL { editor.open($0) }
        }
        .defaultSize(width:EditorWindowLayout.starterSize.width,height:EditorWindowLayout.starterSize.height)
        .windowStyle(.titleBar)
        .commands {
            EditHistoryCommands(editor:editor)
            CommandGroup(replacing:.newItem) {
                Button("Open Video…") { editor.openPanel() }.keyboardShortcut("o").disabled(editor.exporting)
                Button("Import URL…") { editor.showURLImporter() }.keyboardShortcut("o",modifiers:[.command,.shift]).disabled(editor.exporting)
                Button("Close Video") { editor.close() }.keyboardShortcut("w",modifiers:[.command,.shift]).disabled(editor.source == nil || editor.exporting)
            }
            CommandGroup(after:.saveItem) {
                Button("Export Clip") { editor.export() }.keyboardShortcut("e").disabled(!editor.canExport)
                Button("Export Clip As…") { editor.export(saveAs:true) }.keyboardShortcut("e",modifiers:[.command,.shift]).disabled(!editor.canExport)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { editor.togglePlayback() }.disabled(editor.loading)
                Button("Previous Frame") { editor.stepFrame(-1) }.disabled(editor.loading)
                Button("Next Frame") { editor.stepFrame(1) }.disabled(editor.loading)
                Divider()
                Button("Set Start Here") { editor.markStart() }.disabled(editor.exporting || editor.loading)
                Button("Set End Here") { editor.markEnd() }.disabled(editor.exporting || editor.loading)
            }
            CommandGroup(after:.toolbar) {
                Button("Zoom Timeline In") { editor.zoomTimeline(by:0.5) }.keyboardShortcut("=").disabled(editor.source == nil)
                Button("Fit Timeline") { editor.timelineZoom=0 }.keyboardShortcut("0").disabled(editor.source == nil)
                Button("Zoom Timeline Out") { editor.zoomTimeline(by:-0.5) }.keyboardShortcut("-").disabled(editor.source == nil)
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: Editor?
    var pending: [URL]=[]
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if let editor=self?.editor, !editor.importPresented, editor.source != nil, !(NSApp.keyWindow is NSPanel),
               event.modifierFlags.intersection([.command,.control,.option]) == .command,
               ["+","=","-"].contains(event.charactersIgnoringModifiers ?? "") {
                editor.zoomTimeline(by:event.charactersIgnoringModifiers == "-" ? -0.5 : 0.5)
                return nil
            }
            guard let editor=self?.editor, !editor.importPresented, !editor.loading, !editor.exporting, editor.details != nil,
                  !(NSApp.keyWindow is NSPanel),
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !(NSApp.keyWindow?.firstResponder is NSControl),
                  event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            switch event.keyCode {
            case 123: editor.stepFrame(-1)
            case 124: editor.stepFrame(1)
            case 49: editor.togglePlayback()
            default:
                if event.charactersIgnoringModifiers?.lowercased() == "i" { editor.markStart() }
                else if event.charactersIgnoringModifiers?.lowercased() == "o" { editor.markEnd() }
                else { return event }
            }
            return nil
        }
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        guard let url=urls.first else { return }
        if let editor { editor.open(url) } else { pending=urls }
    }
    func deliverPending() { if let url=pending.first { pending=[]; editor?.open(url) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor?.urlImporter.busy == true {
            let alert=NSAlert(); alert.messageText="Cancel the URL import and quit?"
            alert.addButton(withTitle:"Keep Importing"); alert.addButton(withTitle:"Cancel and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            Task { await editor?.urlImporter.cancelAndWait(); editor?.prepareToQuit(); NSApp.reply(toApplicationShouldTerminate:true) }
            return .terminateLater
        }
        if editor?.exporting == true {
            let alert=NSAlert(); alert.messageText="Cancel the export and quit?"; alert.addButton(withTitle:"Keep Exporting"); alert.addButton(withTitle:"Cancel and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            editor?.cancelAndQuit()
            return .terminateLater
        }
        editor?.prepareToQuit(); return .terminateNow
    }
}

/// Menu shortcuts route text editing through AppKit and complete edits through our manager.
struct EditHistoryCommands:Commands {
    @ObservedObject var editor:Editor
    private var nativeText:Bool { editor.textEditing || editor.importPresented || NSApp.keyWindow?.firstResponder is NSText || NSApp.keyWindow is NSPanel }
    private var manager:UndoManager? { nativeText ? NSApp.keyWindow?.firstResponder?.undoManager : editor.editUndoManager }
    var body:some Commands {
        CommandGroup(replacing:.undoRedo) {
            Button(manager?.undoMenuItemTitle ?? "Undo") { perform(redo:false) }
                .keyboardShortcut("z")
                .disabled(nativeText ? manager?.canUndo != true : !editor.canUndo)
            Button(manager?.redoMenuItemTitle ?? "Redo") { perform(redo:true) }
                .keyboardShortcut("z",modifiers:[.command,.shift])
                .disabled(nativeText ? manager?.canRedo != true : !editor.canRedo)
        }
    }
    func perform(redo:Bool,in window:NSWindow?=NSApp.keyWindow) {
        if window?.firstResponder is NSText || editor.importPresented || window is NSPanel {
            let action=NSSelectorFromString(redo ? "redo:" : "undo:")
            NSApp.sendAction(action,to:window,from:nil)
        } else if redo { editor.redoEdit() }
        else { editor.undoEdit() }
    }
}
