import AppKit
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let folder=root.appendingPathComponent(".build/Clipper.iconset")
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for base in [16,32,128,256,512] {
  for scale in [1,2] {
    let size=base*scale
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let context=NSGraphicsContext.current!.cgContext
    context.scaleBy(x:Double(size)/1024,y:Double(size)/1024)
    NSColor(calibratedRed:0.09,green:0.33,blue:0.65,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:214,yRadius:214).fill()
    NSColor.white.setStroke()
    let frame=NSBezierPath(roundedRect:NSRect(x:206,y:270,width:612,height:484),xRadius:28,yRadius:28)
    frame.lineWidth=28; frame.stroke()
    NSColor.white.withAlphaComponent(0.35).setFill()
    for x in stride(from:260,through:748,by:81) {
        NSBezierPath(roundedRect:NSRect(x:x,y:299,width:42,height:26),xRadius:5,yRadius:5).fill()
        NSBezierPath(roundedRect:NSRect(x:x,y:699,width:42,height:26),xRadius:5,yRadius:5).fill()
    }
    NSColor.white.setFill()
    for x in [190,802] { NSBezierPath(roundedRect:NSRect(x:x,y:359,width:32,height:306),xRadius:12,yRadius:12).fill() }
    let play=NSBezierPath(); play.move(to:NSPoint(x:451,y:395)); play.line(to:NSPoint(x:451,y:629)); play.line(to:NSPoint(x:640,y:512)); play.close(); play.fill()
    NSGraphicsContext.restoreGraphicsState()
    let png=bitmap.representation(using:.png,properties:[:])!
    let name="icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try png.write(to:folder.appendingPathComponent(name))
}
}
