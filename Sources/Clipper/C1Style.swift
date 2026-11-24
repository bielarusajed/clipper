import SwiftUI
import AppKit

enum C1 {
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let muted = Color.secondary.opacity(0.8)
    static let blue = Color(red:0.09,green:0.45,blue:0.91)
    static let amber = Color(red:0.90,green:0.64,blue:0.16)
    static let canvas = Color.primary.opacity(0.06)
    static let paper = Color.clear
    static let line = Color.primary.opacity(0.1)
    static let selection = NSColor(calibratedRed:0.90,green:0.64,blue:0.16,alpha:1)
    static let playhead = NSColor.controlAccentColor
}

extension View {
    /// The window-wide blue tint turns native popups and bordered buttons into dark
    /// blue text on a faint blue glass bezel. Keep them neutral; blue marks primary
    /// actions and filled selections only.
    func c1NeutralControl()->some View { tint(nil) }
}

struct C1Group<Content:View>:View {
    @ViewBuilder var content:Content
    var body:some View { VStack(spacing:0) { content } }
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
                    primary ? LinearGradient(colors:[Color(red:0.16,green:0.53,blue:0.98),C1.blue],startPoint:.top,endPoint:.bottom) : LinearGradient(colors:[Color.primary.opacity(0.04),Color.primary.opacity(0.02)],startPoint:.top,endPoint:.bottom)
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
