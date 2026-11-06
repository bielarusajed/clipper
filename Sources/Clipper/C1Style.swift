import SwiftUI
import AppKit

enum C1 {
    static let ink = Color(red:0.15,green:0.20,blue:0.27)
    static let secondary = Color(red:0.40,green:0.46,blue:0.53)
    static let muted = Color(red:0.54,green:0.59,blue:0.65)
    static let blue = Color(red:0.09,green:0.45,blue:0.91)
    static let amber = Color(red:0.90,green:0.64,blue:0.16)
    static let canvas = Color(red:0.88,green:0.91,blue:0.94)
    static let paper = Color(red:0.97,green:0.98,blue:0.995)
    static let line = Color(red:0.39,green:0.50,blue:0.64).opacity(0.14)
    static let selection = NSColor(calibratedRed:0.90,green:0.64,blue:0.16,alpha:1)
    static let playhead = NSColor(calibratedRed:0.32,green:0.43,blue:0.55,alpha:1)
}

struct SidebarMaterial: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {
        view.material = reduceTransparency ? .windowBackground : .sidebar
        view.appearance=NSAppearance(named:.aqua)
    }
}

struct WindowAppearance: NSViewRepresentable {
    func makeNSView(context:Context) -> NSView { WindowHook() }
    func updateNSView(_ view:NSView,context:Context) { }
    private final class WindowHook:NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance=NSAppearance(named:.aqua)
            window?.titlebarAppearsTransparent=true
            window?.toolbar=nil
            window?.backgroundColor=NSColor(calibratedRed:0.96,green:0.97,blue:0.99,alpha:1)
        }
    }
}

struct C1Group<Content:View>:View {
    @ViewBuilder var content:Content
    var body:some View {
        VStack(spacing:0) { content }
            .background(.white.opacity(0.73),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(.white.opacity(0.8),lineWidth:1))
            .shadow(color:C1.ink.opacity(0.025),radius:2,y:1)
    }
}

struct C1ButtonStyle:ButtonStyle {
    var primary=false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .font(.system(size:12,weight:.medium))
            .frame(maxWidth:.infinity,minHeight:34)
            .foregroundStyle(primary ? Color.white : C1.ink)
            .background {
                RoundedRectangle(cornerRadius:8).fill(
                    primary ? LinearGradient(colors:[Color(red:0.16,green:0.53,blue:0.98),C1.blue],startPoint:.top,endPoint:.bottom) : LinearGradient(colors:[.white,.white.opacity(0.88)],startPoint:.top,endPoint:.bottom)
                )
            }
            .overlay(RoundedRectangle(cornerRadius:8).stroke(primary ? C1.blue.opacity(0.4) : C1.line,lineWidth:1))
            .shadow(color:primary ? C1.blue.opacity(0.15) : .clear,radius:4,y:2)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(enabled ? 1 : 0.45)
    }
}

struct AspectGlyph:View {
    var ratio:Double
    var custom=false
    var body:some View {
        let width=min(21,17*ratio), height=min(17,21/ratio)
        RoundedRectangle(cornerRadius:2)
            .stroke(style:StrokeStyle(lineWidth:1,dash:custom ? [2,2] : []))
            .frame(width:width,height:height)
            .frame(width:24,height:21)
    }
}
