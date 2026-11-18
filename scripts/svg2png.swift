import AppKit
// usage: svg2png <in.svg> <out.png> <longSide>
let args = CommandLine.arguments
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let longSide = CGFloat(Double(args[3]) ?? 1200)
guard let data = try? Data(contentsOf: inURL), let img = NSImage(data: data) else { print("FAIL load \(args[1])"); exit(1) }
let s = img.size
let scale = longSide / max(s.width, s.height)
let w = Int((s.width * scale).rounded()), h = Int((s.height * scale).rounded())
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outURL)
print("OK \(args[2]) \(w)x\(h) src=\(s)")
