import SwiftUI
import AppKit

@main struct ClipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var editor=Editor()
    var body: some Scene {
        WindowGroup {
            EditorView(editor:editor,playback:editor.playback)
                .frame(minWidth:940,minHeight:680)
                .onAppear { delegate.editor=editor; delegate.deliverPending() }
                .onOpenURL { editor.open($0) }
        }
        .defaultSize(width:1180,height:820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("Open Video…") { editor.openPanel() }.keyboardShortcut("o").disabled(editor.exporting)
            }
            CommandGroup(after:.saveItem) {
                Button("Export Clip") { editor.export() }.keyboardShortcut("e").disabled(!editor.canExport)
                Button("Export Clip As…") { editor.export(saveAs:true) }.keyboardShortcut("e",modifiers:[.command,.shift]).disabled(!editor.canExport)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { editor.togglePlayback() }.keyboardShortcut(.space,modifiers:[])
                Button("Previous Frame") { editor.returnToOriginal(); editor.playback.step(-1) }.keyboardShortcut(.leftArrow,modifiers:[])
                Button("Next Frame") { editor.returnToOriginal(); editor.playback.step(1) }.keyboardShortcut(.rightArrow,modifiers:[])
                Divider()
                Button("Set Start Here") { editor.markStart() }.keyboardShortcut("i",modifiers:[]).disabled(editor.exporting)
                Button("Set End Here") { editor.markEnd() }.keyboardShortcut("o",modifiers:[]).disabled(editor.exporting)
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: Editor?
    var pending: [URL]=[]
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true) }
    func application(_ application:NSApplication,open urls:[URL]) {
        guard let url=urls.first else { return }
        if let editor { editor.open(url) } else { pending=urls }
    }
    func deliverPending() { if let url=pending.first { pending=[]; editor?.open(url) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editor?.exporting == true {
            let alert=NSAlert(); alert.messageText="Cancel the export and quit?"; alert.addButton(withTitle:"Keep Exporting"); alert.addButton(withTitle:"Cancel and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            editor?.cancel()
        }
        editor?.invalidatePreview(); return .terminateNow
    }
}
