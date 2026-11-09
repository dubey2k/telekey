import AppKit
// Cyberpunk round, app palette only: graphite 0E0F11/16171A/1F2124/2B2E33, signal orange FF6A2B, live green 3DDC84, text ECECEC.
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(red: CGFloat(h >> 16 & 255)/255, green: CGFloat(h >> 8 & 255)/255, blue: CGFloat(h & 255)/255, alpha: a) }
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let O: UInt32 = 0xFF6A2B, G: UInt32 = 0x3DDC84, BG: UInt32 = 0x0E0F11, SURF: UInt32 = 0x16171A, LINE: UInt32 = 0x2B2E33, TXT: UInt32 = 0xECECEC
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
func fill(_ p: CGPath, _ c: CGColor) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }
func stroke(_ p: CGPath, _ c: CGColor, _ w: CGFloat) { ctx.addPath(p); ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.setLineJoin(.miter); ctx.setLineCap(.square); ctx.strokePath() }
func glow(_ c: UInt32, _ blur: CGFloat, _ draw: () -> Void) { ctx.saveGState(); ctx.setShadow(offset: .zero, blur: blur, color: rgb(c, 0.85)); draw(); ctx.restoreGState() }
/// pointer, tip at (x,y), height s
func pointer(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPath {
    poly([(0,0),(0,1.0),(0.25,0.77),(0.43,1.13),(0.59,1.05),(0.42,0.70),(0.74,0.70)].map { P(x + $0.0 * s, y - $0.1 * s) })
}
// chamfered tile: cut corners, the top-right cut bigger (a machined panel), not the rounded system shape
let tile = poly([P(100, 924 - 70), P(100 + 70, 924), P(924 - 190, 924), P(924, 924 - 190), P(924, 100 + 70), P(924 - 70, 100), P(100 + 70, 100), P(100, 170)])
func panel(scan: Bool = true) {
    fill(tile, rgb(SURF))
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0x1F2124), rgb(BG)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: P(0, 924), end: P(0, 100), options: [])
    if scan { for y in stride(from: 104.0, to: 924, by: 12) { fill(CGPath(rect: CGRect(x: 100, y: y, width: 824, height: 3), transform: nil), rgb(0xFFFFFF, 0.025)) } }
    ctx.restoreGState()
    stroke(tile, rgb(LINE), 6)
    // orange accent along the big chamfer, like a hazard edge
    let edge = CGMutablePath(); edge.move(to: P(924 - 190 + 14, 924 - 22)); edge.addLine(to: P(924 - 22, 924 - 190 + 14))
    stroke(edge, rgb(O), 14)
}
func ticks(_ x: CGFloat, _ y: CGFloat, _ count: Int, _ c: CGColor) {
    for i in 0..<count { fill(CGPath(rect: CGRect(x: x + CGFloat(i) * 22, y: y, width: 12, height: 26), transform: nil), c) }
}

// 1 Glitch: the pointer sliced and shifted like a corrupted frame, with a green ghost offset behind
func glitch() {
    panel()
    let p = pointer(330, 800, 520)
    ctx.saveGState(); ctx.translateBy(x: -16, y: 0); fill(p, rgb(G, 0.75)); ctx.restoreGState()   // chromatic ghost
    let slices: [(CGFloat, CGFloat, CGFloat)] = [(800, 610, 0), (610, 590, 26), (590, 578, -14), (578, 420, 0), (420, 404, 34), (404, 230, 0)]
    for (top, bottom, dx) in slices {
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: bottom, width: 1024, height: top - bottom)); ctx.translateBy(x: dx, y: 0)
        glow(O, 36) { fill(p, rgb(O)) }
        ctx.restoreGState()
    }
    ticks(180, 160, 5, rgb(O)); fill(CGPath(rect: CGRect(x: 780, y: 160, width: 70, height: 26), transform: nil), rgb(G))
}
// 2 Uplink: circuit traces routed at 45° from a port into a chamfered screen; the green node is the live link
func uplink() {
    panel()
    let screen = poly([P(360, 760), P(820, 760), P(820, 470), P(790, 440), P(360, 440)])
    stroke(screen, rgb(TXT, 0.9), 18)
    glow(O, 26) {
        for (i, off) in [0.0, 44, 88].enumerated() {
            let t = CGMutablePath()
            t.move(to: P(170, 300 - off)); t.addLine(to: P(300 + off, 300 - off)); t.addLine(to: P(450 + off * 0.2, 450 + off * 0.0)); t.addLine(to: P(450 + off * 0.2, 470 + CGFloat(i) * 70))
            stroke(t, rgb(O), 16)
            fill(CGPath(ellipseIn: CGRect(x: 150, y: 288 - off, width: 26, height: 26), transform: nil), rgb(O))
        }
    }
    glow(G, 30) { fill(CGPath(ellipseIn: CGRect(x: 600, y: 570, width: 70, height: 70), transform: nil), rgb(G)) }
}
// 3 Reticle: segmented targeting ring locked on a pointer, green lock pip
func reticle() {
    panel()
    let c = P(512, 500)
    for (i, start) in stride(from: 10.0, to: 360, by: 60).enumerated() {
        let a = CGMutablePath(); a.addArc(center: c, radius: 300, startAngle: start * .pi / 180, endAngle: (start + 38) * .pi / 180, clockwise: false)
        stroke(a, i % 3 == 0 ? rgb(O) : rgb(TXT, 0.55), 22)
    }
    for ang in stride(from: 0.0, to: 360, by: 15) {
        let r1: CGFloat = 340, r2: CGFloat = ang.truncatingRemainder(dividingBy: 45) == 0 ? 375 : 355
        let t = CGMutablePath(); let a = ang * .pi / 180
        t.move(to: P(c.x + r1 * cos(a), c.y + r1 * sin(a))); t.addLine(to: P(c.x + r2 * cos(a), c.y + r2 * sin(a)))
        stroke(t, rgb(TXT, 0.3), 6)
    }
    glow(O, 34) { fill(pointer(470, 640, 300), rgb(O)) }
    glow(G, 24) { fill(CGPath(rect: CGRect(x: 640, y: 640, width: 34, height: 34), transform: nil), rgb(G)) }
}
// 4 Pixel jack: an 8-bit pointer whose pixels stream off to the right, as if being transmitted
func pixel() {
    panel()
    let rows = ["X.........","XX........","XOX.......","XOOX......","XOOOX.....","XOOOOX....","XOOOOOX...","XOOOOOOX..","XOOOOOOOX.","XOOOOXXXXX","XOOXOX....","XOX.XOX...","XX..XOX...","X....XOX..",".....XX..."]
    let s: CGFloat = 36, ox: CGFloat = 250, oy: CGFloat = 820
    func cells(_ kind: Character, _ c: CGColor, _ gap: CGFloat) {
        for (r, row) in rows.enumerated() { for (k, ch) in row.enumerated() where ch == kind {
            fill(CGPath(rect: CGRect(x: ox + CGFloat(k) * s, y: oy - CGFloat(r + 1) * s, width: s - gap, height: s - gap), transform: nil), c)
        } }
    }
    cells("O", rgb(0x0B0C0E), 0)              // solid body first, no glow behind it
    glow(O, 30) { cells("X", rgb(O), 4) }     // then the lit outline
    // the stream: pixels flying off to the right, thinning out
    for (i, r) in [4, 6, 8, 9].enumerated() {
        let end = [6, 8, 9, 10][i]  // first empty column after the pointer's edge on that row
        for j in 0..<(4 - i % 2) {
            let x = ox + CGFloat(end + 1 + j * 2) * s, a = 0.9 - CGFloat(j) * 0.25
            fill(CGPath(rect: CGRect(x: x, y: oy - CGFloat(r + 1) * s, width: s - 4, height: s - 4), transform: nil), rgb(j == 0 && i == 2 ? G : O, a))
        }
    }
}

// 5 Telekey: an 8-bit keycap with a pointer on its face, its pixels streaming off to the right (sent to the TV).
// `teleport` dissolves the right side of the cap instead, as if the key is being beamed away.
let keycap = ["XXXXXXXXXXXXXX","XSSSSSSSSSSSSX","XSLLLLLLLLLLSX","XSLOOOOOOOOLSX","XSLOGOOOOOOLSX","XSLOGGOOOOOLSX","XSLOGGGOOOOLSX","XSLOGGGGOOOLSX","XSLOGGGGGOOLSX","XSLOGGGOOOOLSX","XSLOGOGGOOOLSX","XSLOOOGGOOOLSX","XSLOOOOOOOOLSX","XSLLLLLLLLLLSX","XSSSSSSSSSSSSX","XSSSSSSSSSSSSX","XXXXXXXXXXXXXX"]
func key(teleport: Bool) {
    panel()
    let s: CGFloat = 34, ox: CGFloat = teleport ? 250 : 190, oy: CGFloat = 815
    let cut = 10
    func cell(_ r: Int, _ k: Int) -> (CGRect, CGFloat)? {
        var x = ox + CGFloat(k) * s, a: CGFloat = 1
        if teleport && k >= cut {
            let h = (r * 7 + k * 13) % 5           // cheap deterministic scatter
            if h == 0 { return nil }
            x += CGFloat(k - cut + 1) * s * (0.5 + CGFloat(h) * 0.25); a = max(0.15, 1 - CGFloat(k - cut + 1) * 0.2)
        }
        return (CGRect(x: x, y: oy - CGFloat(r + 1) * s, width: s, height: s), a)
    }
    func cells(_ kind: Character, _ color: UInt32, _ gap: CGFloat) {
        for (r, row) in keycap.enumerated() { for (k, ch) in row.enumerated() where ch == kind {
            if let (rect, a) = cell(r, k) { fill(CGPath(rect: rect.insetBy(dx: gap / 2, dy: gap / 2), transform: nil), rgb(color, a)) }
        } }
    }
    cells("O", 0x0B0C0E, 0); cells("S", 0x1F2124, 0); cells("L", 0x2B2E33, 3)
    glow(O, 30) { cells("X", O, 4) }
    glow(G, 24) { cells("G", G, 4) }
    if !teleport {
        for (i, r) in [2, 6, 10, 15].enumerated() {
            let end = keycap[r].lastIndex(where: { $0 != "." })!.utf16Offset(in: keycap[r]) + 1
            for j in 0..<(3 - i % 2) {
                let x = ox + CGFloat(end + 1 + j * 2) * s
                fill(CGPath(rect: CGRect(x: x, y: oy - CGFloat(r + 1) * s, width: s - 4, height: s - 4), transform: nil), rgb(j == 0 && i == 1 ? G : O, 0.9 - CGFloat(j) * 0.28))
            }
        }
    }
}

let w = CommandLine.arguments[1]
switch w { case "glitch": glitch(); case "uplink": uplink(); case "reticle": reticle(); case "key": key(teleport: false); case "teleport": key(teleport: true); case "pixel": pixel(); default: key(teleport: false) }
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: w + ".png"))
