import AppKit
import SwiftUI
import XCTest
@testable import Clipper

final class EditorWindowTests:XCTestCase {
    func testTallVideoFitsAvailableScreenByReducingWidth() {
        for available in [CGSize(width:1512,height:900),CGSize(width:1280,height:700)] {
            let portrait=EditorWindowLayout.videoSize(width:1180,aspectRatio:9/16,available:available)
            XCTAssertLessThan(portrait.width,1180)
            XCTAssertLessThanOrEqual(portrait.height,available.height)
            XCTAssertLessThanOrEqual(portrait.width,available.width)
            let video=CGSize(width:portrait.width-EditorWindowLayout.surroundingSize.width,
                             height:portrait.height-EditorWindowLayout.surroundingSize.height)
            XCTAssertEqual(video.width/video.height,9/16,accuracy:0.002)
            XCTAssertEqual(portrait.height,available.height,accuracy:1)
        }
        let wide=EditorWindowLayout.videoSize(width:1180,aspectRatio:2.4,available:CGSize(width:1512,height:900))
        let landscape=EditorWindowLayout.videoSize(width:1180,aspectRatio:16/9,available:CGSize(width:1512,height:900))
        XCTAssertEqual(wide.width,1180)
        XCTAssertLessThan(wide.height,landscape.height)
    }

    @MainActor func testNativeEditorFitsVideoResizesAndReturnsToStarter() async throws {
        _=NSApplication.shared
        let editor=Editor()
        let host=NSHostingView(rootView:EditorView(editor:editor,playback:editor.playback))
        let window=NSWindow(contentRect:CGRect(x:200,y:200,width:1180,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=host
        defer { window.contentView=nil; window.close(); editor.close() }
        try await settle()
        XCTAssertEqual(window.contentLayoutRect.width,520,accuracy:1)
        XCTAssertEqual(window.contentLayoutRect.height,440,accuracy:1)
        let starterScreen=try XCTUnwrap(window.screen).visibleFrame
        XCTAssertEqual(window.frame.midX,starterScreen.midX,accuracy:1)
        XCTAssertEqual(window.frame.midY,starterScreen.midY,accuracy:1)

        editor.source=URL(fileURLWithPath:"/test/video.mp4")
        for size in [CGSize(width:1920,height:1080),CGSize(width:2400,height:1000),CGSize(width:1080,height:1920)] {
            editor.playback.details=MediaDetails(duration:5,origin:0,width:Int(size.width),height:Int(size.height),rotation:0,pixelAspect:1,fps:30,hdr:false,codec:"h264",audioLabels:[],audioStreams:[])
            try await settle()
            host.layoutSubtreeIfNeeded()
            let surface=try XCTUnwrap(descendant(ComparisonSurface.Surface.self,in:host))
            XCTAssertEqual(surface.bounds.width,window.contentLayoutRect.width-EditorWindowLayout.surroundingSize.width,accuracy:1,"The video must fill the right column")
            XCTAssertEqual(surface.bounds.width/surface.bounds.height,size.width/size.height,accuracy:0.002)
            XCTAssertEqual(window.contentLayoutRect.height-surface.bounds.height,EditorWindowLayout.surroundingSize.height,accuracy:1,"Only the controls and spacing should surround the video")
            let visible=try XCTUnwrap(window.screen).visibleFrame
            XCTAssertGreaterThanOrEqual(window.frame.minY,visible.minY-1)
            XCTAssertLessThanOrEqual(window.frame.maxY,visible.maxY+1)
            XCTAssertLessThanOrEqual(window.maxSize.height,visible.height)
            if size.width>size.height {
                XCTAssertEqual(window.frame.width,1180,accuracy:1)
            } else {
                XCTAssertEqual(window.frame.height,visible.height,accuracy:1)
                XCTAssertLessThan(window.frame.width,1180)
            }
        }

        // Switching back from portrait restores the preferred landscape width.
        editor.playback.details?.width=1920; editor.playback.details?.height=1080
        try await settle()
        let targetWidth=min(1100,window.frame.width-40)
        window.setFrame(CGRect(x:window.frame.minX,y:window.frame.minY,width:targetWidth,height:window.frame.height),display:false)
        try await settle()
        let surface=try XCTUnwrap(descendant(ComparisonSurface.Surface.self,in:host))
        XCTAssertEqual(window.frame.width,targetWidth,accuracy:1)
        XCTAssertEqual(window.contentLayoutRect.height-surface.bounds.height,EditorWindowLayout.surroundingSize.height,accuracy:1)

        var shorter=window.frame
        shorter.size.height -= 25
        window.setFrame(shorter,display:false)
        try await settle()
        XCTAssertLessThan(window.frame.width,targetWidth,"Dragging the height should also preserve the video aspect ratio")
        XCTAssertEqual(window.contentLayoutRect.height-surface.bounds.height,EditorWindowLayout.surroundingSize.height,accuracy:1)
        let resizedWidth=window.frame.width

        editor.playback.details?.width=1080; editor.playback.details?.height=1920
        try await settle()
        editor.close()
        try await settle()
        XCTAssertEqual(window.contentLayoutRect.width,520,accuracy:1)
        XCTAssertEqual(window.contentLayoutRect.height,440,accuracy:1)
        let closingScreen=try XCTUnwrap(window.screen).visibleFrame
        XCTAssertEqual(window.frame.midX,closingScreen.midX,accuracy:1)
        XCTAssertEqual(window.frame.midY,closingScreen.midY,accuracy:1,"Closing a portrait video should center the starter rather than preserve the video's top edge")
        editor.source=URL(fileURLWithPath:"/test/reopened.mp4")
        try await settle()
        XCTAssertEqual(window.frame.width,resizedWidth,accuracy:1,"Reopening should remember the editor width, independently of the starter window")
    }

    @MainActor private func settle() async throws {
        try await Task.sleep(nanoseconds:150_000_000)
    }

    @MainActor private func descendant<T:NSView>(_ type:T.Type,in view:NSView)->T? {
        if let match=view as? T { return match }
        for child in view.subviews { if let match=descendant(type,in:child) { return match } }
        return nil
    }
}
