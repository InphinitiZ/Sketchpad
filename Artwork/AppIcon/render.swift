import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// All geometry uses a 1024-point canvas with a top-left origin.
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
}
func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func shape(_ c: CGContext, _ path: CGPath, _ fill: CGColor) { c.addPath(path); c.setFillColor(fill); c.fillPath() }
func gradient(_ c: CGContext, _ path: CGPath, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint) {
    c.saveGState(); c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); c.restoreGState()
}
func polygon(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath(); return p
}
func context(_ width: Int, _ height: Int) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
    return c
}
func write(_ image: CGImage, _ filename: String) {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
}
let c = context(1024, 1024)
let tile = roundRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 12), blur: 20, color: color(0x071E39, 0.23)); shape(c, tile, color(0x195B93)); c.restoreGState()
gradient(c, tile, [color(0x287DB0), color(0x16497E)], CGPoint(x: 400,y: 100), CGPoint(x: 600,y: 924))
c.saveGState(); c.addPath(tile); c.clip(); c.addPath(roundRect(CGRect(x: 101.5,y: 101.5,width: 821,height: 821),184)); c.setStrokeColor(color(0xFFFFFF,0.22)); c.setLineWidth(3); c.strokePath(); c.restoreGState()
// A slightly turned sheet gives the central drawing a tactile, unmistakable silhouette.
c.saveGState(); c.translateBy(x: 507, y: 502); c.rotate(by: -6 * .pi / 180)
let paper = roundRect(CGRect(x: -248,y: -275,width: 496,height: 550),35)
c.saveGState(); c.setShadow(offset: CGSize(width: 0,height: 15),blur: 22,color: color(0x062A50,0.33)); shape(c,paper,color(0xF8FAFC)); c.restoreGState()
gradient(c,paper,[color(0xFFFFFF),color(0xE5EEF6)],CGPoint(x:0,y:-275),CGPoint(x:0,y:275))
// One wide, rising paint gesture. Rounded ends remain distinct at small sizes.
let stroke = CGMutablePath(); stroke.move(to: CGPoint(x:-157,y:105)); stroke.addCurve(to: CGPoint(x:144,y:-108), control1:CGPoint(x:-55,y:132),control2:CGPoint(x:-24,y:-121))
c.saveGState(); c.addPath(stroke); c.setStrokeColor(color(0xF15354)); c.setLineWidth(107); c.setLineCap(.round); c.strokePath(); c.restoreGState()
c.restoreGState()
// Pencil, drawn along a local vertical axis, points toward the lower left.
c.saveGState(); c.translateBy(x:640,y:512); c.rotate(by: 37 * .pi / 180)
let pencilBody = roundRect(CGRect(x:-37,y:-261,width:74,height:420),14)
c.saveGState(); c.setShadow(offset:CGSize(width:5,height:9),blur:10,color:color(0x18334F,0.32)); shape(c,pencilBody,color(0xFFC54A)); shape(c,polygon([CGPoint(x:-37,y:143),CGPoint(x:37,y:143),CGPoint(x:0,y:242)]),color(0xEBC59A)); c.restoreGState()
gradient(c,pencilBody,[color(0xFFE494),color(0xFFCA4B),color(0xEAA82C)],CGPoint(x:-37,y:0),CGPoint(x:37,y:0))
// Warm white ferrule and dark blue cap keep the tool graphic and simple.
shape(c,roundRect(CGRect(x:-37,y:-272,width:74,height:66),14),color(0x173C60))
shape(c,CGPath(rect:CGRect(x:-37,y:-220,width:74,height:29),transform:nil),color(0xEEF4F8))
shape(c,polygon([CGPoint(x:-37,y:143),CGPoint(x:37,y:143),CGPoint(x:0,y:242)]),color(0xEFCDA5))
shape(c,polygon([CGPoint(x:-13,y:207),CGPoint(x:13,y:207),CGPoint(x:0,y:242)]),color(0x173C60))
c.restoreGState()
let icon = c.makeImage()!
write(icon,"AppIcon-1024.png")

// True pixel-size comparisons: each background contains the six requested sizes.
let sizes = [1024,256,128,64,32,16]
let preview = context(1760,2240)
for row in 0..<2 {
    let top = row*1120
    preview.setFillColor(color(row == 0 ? 0xEEF0F4 : 0x151C29)); preview.fill(CGRect(x:0,y:top,width:1760,height:1120))
    var x = 36
    for size in sizes {
        let y = top + 52 + (1024-size)/2
        // Quartz image drawing needs its own flip inside our top-left canvas.
        preview.saveGState(); preview.translateBy(x:CGFloat(x),y:CGFloat(y+size)); preview.scaleBy(x:1,y:-1); preview.interpolationQuality = .high
        preview.draw(icon,in:CGRect(x:0,y:0,width:size,height:size)); preview.restoreGState()
        x += size + 28
    }
}
write(preview.makeImage()!,"preview.png")
print("Rendered AppIcon-1024.png and preview.png")
