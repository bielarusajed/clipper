import AppKit
import SwiftUI
import XCTest
@testable import Clipper

final class TimelineTests:XCTestCase {
    @MainActor func testTimelineOnlyScrollsHorizontallyWhenZoomed() async throws {
        _=NSApplication.shared
        let editor=Editor()
        let host=NSHostingView(rootView:Timeline(editor:editor,playback:editor.playback))
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:EditorWindowLayout.timelineHeight),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=host
        defer { window.contentView=nil; window.close(); editor.close() }
        try await Task.sleep(nanoseconds:100_000_000)
        host.layoutSubtreeIfNeeded()
        let scroll=try XCTUnwrap(descendant(TimelineScrollView.self,in:host))
        for zoom in [0.0,2,0] {
            editor.timelineZoom=zoom
            try await Task.sleep(nanoseconds:100_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(try XCTUnwrap(scroll.horizontalScroller).isHidden,zoom == 0)
            let canvas=try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height,canvas.frame.height,"The canvas must fit above the horizontal scrollbar, leaving no vertical scroll range")
            XCTAssertEqual(scroll.contentView.bounds.minY,0,accuracy:0.01)
            for horizontal in [-60,0] {
                for vertical in [30,-30] {
                    let event=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:Int32(vertical),wheel2:Int32(horizontal),wheel3:0))
                    scroll.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:event)))
                    XCTAssertEqual(scroll.contentView.bounds.minY,0,accuracy:0.01,"Scrolling must keep the ruler and filmstrip fixed vertically")
                }
            }
            // Trackpad gestures take a different AppKit path from wheel events.
            // Check while fingers are down and during momentum, not just after release.
            for horizontal in [-60,0] {
                for vertical in [30,-30] {
                    let phases:[(CGScrollPhase,CGMomentumScrollPhase)]=[
                        (.began,.none),(.changed,.none),(.changed,.none),(.ended,.none),
                        (CGScrollPhase(rawValue:0)!, .begin),(CGScrollPhase(rawValue:0)!, CGMomentumScrollPhase(rawValue:2)!),(CGScrollPhase(rawValue:0)!, .end)
                    ]
                    for (phase,momentum) in phases {
                        let event=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:Int32(vertical),wheel2:Int32(horizontal),wheel3:0))
                        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
                        event.setIntegerValueField(.scrollWheelEventScrollPhase,value:Int64(phase.rawValue))
                        event.setIntegerValueField(.scrollWheelEventMomentumPhase,value:Int64(momentum.rawValue))
                        let native=try XCTUnwrap(NSEvent(cgEvent:event))
                        XCTAssertTrue(native.hasPreciseScrollingDeltas)
                        scroll.scrollWheel(with:native)
                        try await Task.sleep(nanoseconds:20_000_000)
                        XCTAssertEqual(scroll.contentView.bounds.minY,0,accuracy:0.01,"The timeline must not move vertically during an active trackpad gesture or momentum")
                    }
                }
            }
            if zoom>0 {
                XCTAssertGreaterThan(scroll.contentView.bounds.minX,0,"Horizontal scrolling must remain available when zoomed")
            } else {
                XCTAssertEqual(scroll.contentView.bounds.minX,0,accuracy:0.01,"The fitted timeline must not scroll when there is no scrollbar")
            }
        }
    }

    @MainActor private func descendant<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let match=view as? T { return match }
        for child in view.subviews { if let match=descendant(type,in:child) { return match } }
        return nil
    }
}
