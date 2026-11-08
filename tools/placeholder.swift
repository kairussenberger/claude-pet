// Draws the default pet sprite (an orange blob with sunglasses) and its glint mask.
// Swap in your own art any time; see README "Make it your own pet".
// usage (from the repo root): swift tools/placeholder.swift
import AppKit

let W = 420, H = 460
func render(_ path: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
func rgb(_ v: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
// sunglasses: two rounded lenses and a bridge (y measured from the bottom)
let lenses = [CGRect(x: 108, y: 250, width: 92, height: 64), CGRect(x: 220, y: 250, width: 92, height: 64)]
func glasses(_ c: CGContext, _ color: CGColor) {
    c.setFillColor(color)
    for r in lenses { c.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil)) }
    c.fillPath()
    c.fill(CGRect(x: 196, y: 288, width: 28, height: 12))
}

render("assets/pet.png") { c in
    c.setFillColor(rgb(0x000000, 0.0)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // feet
    c.setFillColor(rgb(0xB65A3C))
    c.fillEllipse(in: CGRect(x: 110, y: 6, width: 80, height: 40))
    c.fillEllipse(in: CGRect(x: 230, y: 6, width: 80, height: 40))
    // body
    let body = CGPath(roundedRect: CGRect(x: 50, y: 26, width: 320, height: 400), cornerWidth: 150, cornerHeight: 160, transform: nil)
    c.addPath(body); c.setFillColor(rgb(0xD97757)); c.fillPath()
    // belly highlight
    c.setFillColor(rgb(0xF2B49B, 0.55)); c.fillEllipse(in: CGRect(x: 120, y: 60, width: 180, height: 150))
    // arms
    c.setFillColor(rgb(0xC4664A))
    c.fillEllipse(in: CGRect(x: 26, y: 140, width: 60, height: 110))
    c.fillEllipse(in: CGRect(x: 334, y: 140, width: 60, height: 110))
    glasses(c, rgb(0x1E1E1E))
    // smile
    c.setStrokeColor(rgb(0x1E1E1E)); c.setLineWidth(9); c.setLineCap(.round)
    c.addArc(center: CGPoint(x: 210, y: 236), radius: 34, startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
    c.strokePath()
}
// glint mask: white where the lenses are, transparent elsewhere
render("assets/pet_lens.png") { c in glasses(c, rgb(0xFFFFFF)) }
print("wrote assets/pet.png and assets/pet_lens.png")
