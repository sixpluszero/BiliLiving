import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
func json(_ value: Any, at url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
let metadata: [String:Any] = ["author":"xcode", "version":1]
func render(width: Int, height: Int, to url: URL, foreground: Bool, background: Bool, shelf: Bool = false) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let w = CGFloat(width), h = CGFloat(height)
    if background {
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.27, alpha: 1), ending: NSColor(calibratedWhite: 0.025, alpha: 1))!.draw(in: NSRect(x:0,y:0,width:w,height:h), angle: -30)
    }
    if foreground {
        let size = h * (shelf ? 0.3 : 0.5)
        let cx = w / 2, cy = h * (shelf ? 0.63 : 0.52)
        let frame = NSRect(x:cx-size*0.72,y:cy-size*0.48,width:size*1.44,height:size*0.96)
        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        let screen = NSBezierPath(roundedRect:frame,xRadius:size*0.2,yRadius:size*0.2)
        screen.fill()
        NSColor(calibratedWhite:1,alpha:0.8).setStroke(); screen.lineWidth = max(2,size*0.024); screen.stroke()
        let play=NSBezierPath();play.move(to:NSPoint(x:cx-size*0.13,y:cy-size*0.23));play.line(to:NSPoint(x:cx+size*0.25,y:cy));play.line(to:NSPoint(x:cx-size*0.13,y:cy+size*0.23));play.close()
        NSColor.white.setFill();play.fill()
        if shelf {
            let text="BiliLiving" as NSString
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:h*0.095,weight:.semibold),.foregroundColor:NSColor.white]
            let measured=text.size(withAttributes:attributes)
            text.draw(at:NSPoint(x:(w-measured.width)/2,y:h*0.20),withAttributes:attributes)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
try fm.createDirectory(at:root,withIntermediateDirectories:true)
var assets: [[String:Any]] = []
for (name,w,h) in [("Living Icon.imagestack",400,240),("Living Store.imagestack",1280,768)] {
    let stack=root.appendingPathComponent(name)
    try fm.createDirectory(at:stack,withIntermediateDirectories:true)
    try json(["info":metadata,"layers":[["filename":"Front.imagestacklayer"],["filename":"Back.imagestacklayer"]]],at:stack.appendingPathComponent("Contents.json"))
    for layer in ["Front","Back"] {
        let path=stack.appendingPathComponent("\(layer).imagestacklayer/Content.imageset")
        try fm.createDirectory(at:path,withIntermediateDirectories:true)
        try json(["info":metadata,"content":["filename":"Content.imageset"]],at:path.deletingLastPathComponent().appendingPathComponent("Contents.json"))
        try render(width:w,height:h,to:path.appendingPathComponent("living.png"),foreground:layer == "Front",background:layer == "Back")
        var item: [String:Any] = ["idiom":"tv","filename":"living.png"]
        if w == 400 { item["scale"] = "1x" }
        try json(["info":metadata,"images":[item]],at:path.appendingPathComponent("Contents.json"))
    }
    assets.append(["filename":name,"idiom":"tv","role":"primary-app-icon","size":"\(w)x\(h)"])
}
for (name,width,role) in [("Living Shelf.imageset",1920,"top-shelf-image"),("Living Wide.imageset",2320,"top-shelf-image-wide")] {
    let path=root.appendingPathComponent(name)
    try fm.createDirectory(at:path,withIntermediateDirectories:true)
    try render(width:width,height:720,to:path.appendingPathComponent("living.png"),foreground:true,background:true,shelf:true)
    try json(["info":metadata,"images":[["idiom":"tv","filename":"living.png","scale":"1x"]]],at:path.appendingPathComponent("Contents.json"))
    assets.append(["filename":name,"idiom":"tv","role":role,"size":"\(width)x720"])
}
try json(["info":metadata,"assets":assets],at:root.appendingPathComponent("Contents.json"))
