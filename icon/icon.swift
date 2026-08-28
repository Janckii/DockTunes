import Cocoa

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Apples Kachel sitzt eingerückt in der Fläche, nicht randfüllend.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let radius = rect.width * 0.225
let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Grundfläche: dasselbe Graphit wie das Dock-Glas, oben etwas heller
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.33, green: 0.33, blue: 0.34, alpha: 1),
    CGColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                       end: CGPoint(x: 0, y: rect.minY), options: [])
ctx.restoreGState()

// Lichtkante oben, wie beim Panel
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
ctx.setLineWidth(6)
ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.strokePath()
ctx.restoreGState()

// Tonanzeige: fünf Balken, wie im Panel
let heights: [CGFloat] = [0.30, 0.62, 0.94, 0.52, 0.36]
let barW = rect.width * 0.085
let gap = rect.width * 0.052
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = rect.midX - total/2
let maxH = rect.height * 0.52
for h in heights {
    let bh = maxH * h
    let bar = CGRect(x: x, y: rect.midY - bh/2, width: barW, height: bh)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW/2, cornerHeight: barW/2, transform: nil))
    ctx.fillPath()
    x += barW + gap
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"))
print("Icon gezeichnet, \(Int(S))x\(Int(S))")
