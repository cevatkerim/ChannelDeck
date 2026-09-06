// Reproducible vector artwork; run with: swift Scripts/render-brand.swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("ChannelDeck/Resources/Assets.xcassets")
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat, angle: CGFloat = 0) -> CGPath {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        .rotated(by: angle * .pi / 180).translatedBy(x: -rect.midX, y: -rect.midY)
    return path.copy(using: &t)!
}
let back = rounded(CGRect(x: 308, y: 231, width: 480, height: 451), 106, angle: 9)
let front = rounded(CGRect(x: 222, y: 337, width: 491, height: 402), 106, angle: -8)
let play: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 443, y: 458))
    p.addQuadCurve(to: CGPoint(x: 460, y: 461), control: CGPoint(x: 443, y: 449))
    p.addLine(to: CGPoint(x: 569, y: 520))
    p.addQuadCurve(to: CGPoint(x: 569, y: 539), control: CGPoint(x: 585, y: 529))
    p.addLine(to: CGPoint(x: 459, y: 601))
    p.addQuadCurve(to: CGPoint(x: 443, y: 590), control: CGPoint(x: 442, y: 610))
    p.closeSubpath()
    var t = CGAffineTransform(translationX: 490, y: 530).rotated(by: -8 * .pi / 180).translatedBy(x: -490, y: -530)
    return p.copy(using: &t)!
}()
func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray,
        locations: [0, 1])!, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
func drawIcon(_ c: CGContext) {
    let base = rounded(CGRect(x: 70, y: 70, width: 884, height: 884), 210)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 12), blur: 25, color: color(0x0C3026, alpha: 0.2))
    c.setFillColor(color(0x153F33)); c.addPath(base); c.fillPath(); c.restoreGState()
    gradient(c, path: base, colors: [color(0x285E4C), color(0x0F2D25)],
             start: CGPoint(x: 150, y: 80), end: CGPoint(x: 830, y: 940))
    c.setLineWidth(2); c.setStrokeColor(color(0xCAFFE3, alpha: 0.18)); c.addPath(base); c.strokePath()
    gradient(c, path: back, colors: [color(0x91E5BF), color(0x429B7C)],
             start: CGPoint(x: 340, y: 230), end: CGPoint(x: 730, y: 720))
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 16), blur: 25, color: color(0x09251D, alpha: 0.35))
    c.setFillColor(color(0xBDF4D8)); c.addPath(front); c.fillPath(); c.restoreGState()
    gradient(c, path: front, colors: [color(0xE5FFEE), color(0x8ADFB6)],
             start: CGPoint(x: 260, y: 325), end: CGPoint(x: 700, y: 790))
    c.setLineWidth(2); c.setStrokeColor(color(0xFFFFFF, alpha: 0.55)); c.addPath(front); c.strokePath()
    c.setFillColor(color(0x174A39)); c.addPath(play); c.fillPath()
}
func drawSymbol(_ c: CGContext) {
    c.setFillColor(color(0x000000)); c.setStrokeColor(color(0x000000)); c.setLineWidth(48)
    // Use a vector clipping mask: clear blend mode is not preserved by PDF renderers.
    c.saveGState()
    c.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    c.addPath(rounded(CGRect(x: 200, y: 315, width: 535, height: 446), 128, angle: -8))
    c.clip(using: .evenOdd)
    c.addPath(back); c.strokePath()
    c.restoreGState()
    c.addPath(front); c.addPath(play); c.drawPath(using: .eoFill)
}
func png(size: Int, to url: URL, symbol: Bool = false) throws {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    c.translateBy(x: 0, y: 1024); c.scaleBy(x: 1, y: -1)
    if symbol { drawSymbol(c) } else { drawIcon(c) }
    let image = c.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write artwork") }
}
if CommandLine.arguments.contains("--tvos") {
    let catalog = root.appendingPathComponent("ChannelDeckTV/Resources/Assets.xcassets")
    let brand = catalog.appendingPathComponent("TVBrand.brandassets")
    let info: [String: Any] = ["author": "com.kerimincedayi.ChannelDeckTV", "version": 1]
    func metadata(_ object: [String: Any], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("Contents.json"))
    }
    func artwork(width: Int, height: Int, layer: String, at url: URL) {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        let canvasWidth: CGFloat = layer == "Shelf" ? 1920 : 1024
        let canvasHeight: CGFloat = layer == "Shelf" ? 720 : 614.4
        c.scaleBy(x: CGFloat(width) / canvasWidth, y: CGFloat(height) / canvasHeight)
        if layer == "Background" || layer == "Shelf" {
            gradient(c, path: CGPath(rect: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), transform: nil),
                     colors: [color(0x285E4C), color(0x081B16)], start: .zero, end: CGPoint(x: canvasWidth, y: canvasHeight))
        }
        c.saveGState()
        if layer == "Shelf" { c.translateBy(x: 160, y: -35); c.scaleBy(x: 0.75, y: 0.75) }
        else { c.translateBy(x: 102, y: -102); c.scaleBy(x: 0.8, y: 0.8) }
        if layer == "Middle" || layer == "Shelf" {
            gradient(c, path: back, colors: [color(0x91E5BF), color(0x429B7C)], start: CGPoint(x: 340, y: 230), end: CGPoint(x: 730, y: 720))
        }
        if layer == "Foreground" || layer == "Shelf" {
            gradient(c, path: front, colors: [color(0xE5FFEE), color(0x8ADFB6)], start: CGPoint(x: 260, y: 325), end: CGPoint(x: 700, y: 790))
            c.setFillColor(color(0x174A39)); c.addPath(play); c.fillPath()
        }
        c.restoreGState()
        if layer == "Shelf" {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            ("ChannelDeck" as NSString).draw(at: CGPoint(x: 850, y: 285), withAttributes: [.font: NSFont.systemFont(ofSize: 84, weight: .bold), .foregroundColor: NSColor.white])
            ("Your front row to live TV" as NSString).draw(at: CGPoint(x: 853, y: 390), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor(cgColor: color(0x91E5BF))!])
            NSGraphicsContext.restoreGraphicsState()
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, c.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
    try metadata(["info": info], at: catalog)
    var assets: [[String: Any]] = []
    for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Store Icon", 1280, 768, [1])] {
        let stack = brand.appendingPathComponent(name + ".imagestack")
        let layers = ["Foreground", "Middle", "Background"]
        try metadata(["info": info, "layers": layers.map { ["filename": $0 + ".imagestacklayer"] }], at: stack)
        for layer in layers {
            let directory = stack.appendingPathComponent(layer + ".imagestacklayer/Content.imageset")
            try metadata(["info": info, "images": scales.map { ["idiom": "tv", "scale": "\($0)x", "filename": "layer@\($0)x.png"] }], at: directory)
            for scale in scales { artwork(width: width * scale, height: height * scale, layer: layer, at: directory.appendingPathComponent("layer@\(scale)x.png")) }
        }
        assets.append(["filename": name + ".imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "\(width)x\(height)"])
    }
    let shelf = brand.appendingPathComponent("Top Shelf.imageset")
    try metadata(["info": info, "images": [1, 2].map { ["idiom": "tv", "scale": "\($0)x", "filename": "shelf@\($0)x.png"] }], at: shelf)
    for scale in [1, 2] { artwork(width: 1920 * scale, height: 720 * scale, layer: "Shelf", at: shelf.appendingPathComponent("shelf@\(scale)x.png")) }
    assets.append(["filename": "Top Shelf.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"])
    try metadata(["info": info, "assets": assets], at: brand)
    print("Rendered layered Apple TV icons and Top Shelf artwork.")
    exit(0)
}
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try png(size: size, to: assets.appendingPathComponent("AppIcon.appiconset/icon_\(size)x\(size).png"))
}
try png(size: 512, to: assets.appendingPathComponent("ChannelDeckMark.imageset/ChannelDeckMark.png"))
try png(size: 1024, to: assets.appendingPathComponent("ChannelDeckMark.imageset/ChannelDeckMark@2x.png"))
try png(size: 1024, to: root.appendingPathComponent("docs/brand/channeldeck-icon.png"))
var bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let url = assets.appendingPathComponent("ChannelDeckSymbol.imageset/ChannelDeckSymbol.pdf")
let pdf = CGContext(url as CFURL, mediaBox: &bounds, nil)!
pdf.beginPDFPage(nil); pdf.translateBy(x: 0, y: 1024); pdf.scaleBy(x: 1, y: -1)
drawSymbol(pdf); pdf.endPDFPage(); pdf.closePDF()
print("Rendered the Dock icon at every macOS size and the vector interface mark.")
