import SwiftUI
import AppKit

/// One desktop material spans the editor. Only the inspector and timeline use
/// floating glass; the live video remains outside all material effects.
struct WindowMaterial:NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduced
    func makeNSView(context:Context)->NSVisualEffectView {
        let view=NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {
        view.material = reduced ? .windowBackground : .underWindowBackground
    }
}

struct GlassPanel:ViewModifier {
    var radius:CGFloat
    var concentric=false
    // The window supplies the outer shape. Use the same resolved radius for all
    // corners of an island, with a modest minimum away from the window corners.
    static var windowIsland:GlassPanel { GlassPanel(radius:8,concentric:true) }
    @Environment(\.accessibilityReduceTransparency) private var reduced
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 26.0,*), concentric {
            panel(content,in:ConcentricRectangle(corners:.concentric(minimum:.fixed(radius)),isUniform:true))
        } else {
            panel(content,in:RoundedRectangle(cornerRadius:radius))
        }
    }
    @ViewBuilder private func panel<S:Shape>(_ content:Content,in shape:S)->some View {
        if reduced {
            content.background(Color(nsColor:.windowBackgroundColor),in:shape)
        } else if #available(macOS 26.0,*) {
            content.glassEffect(.regular,in:shape)
        } else {
            content.background(.ultraThinMaterial,in:shape)
        }
    }
}
