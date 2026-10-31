//
//  wingcut.swift
//  SoarX — developer tool, not part of any target
//
//  Turns a manufacturer's colourway render into a wing-library image:
//  one wing, background removed, 500x500 RGBA, matching the rest of
//  ParaFlightLog/Resources/WingLibrary.
//
//  Manufacturers publish all colourways in one transparent PNG, and the
//  wings are drawn at an angle so their bounding boxes OVERLAP — no crop
//  rectangle can isolate one. Connected components can: the wings never
//  touch, and the baked-in colourway label ("HKC", "AHI") falls out as a
//  component of its own, so it disappears for free.
//
//  Usage:
//      swiftc -O scripts/wingcut.swift -o /tmp/wingcut
//      /tmp/wingcut comps render.png              # list components
//      /tmp/wingcut keep render.png out.png 0     # keep component 0
//
//  For a render published on a flat studio background with no alpha
//  (Flare, most dealers):
//      /tmp/wingcut dekey render.png out.png      # key out the backdrop
//
//  Other modes (bbox, cols, rows, make) exist for probing a source.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Loads a PNG into a known RGBA8 premultiplied-last buffer so pixel maths is
// predictable whatever the source file's layout.
func loadRGBA(_ path: String) -> (px: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    // CGContext draws bottom-up; flip to top-left origin so every coordinate in
    // this tool means the same thing as in a screenshot.
    var flipped = [UInt8](repeating: 0, count: px.count)
    for y in 0..<h {
        let srcRow = (h - 1 - y) * w * 4
        let dstRow = y * w * 4
        for i in 0..<(w * 4) { flipped[dstRow + i] = px[srcRow + i] }
    }
    return (flipped, w, h)
}

func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, to path: String) -> Bool {
    var bottomUp = [UInt8](repeating: 0, count: px.count)
    for y in 0..<h {
        let srcRow = (h - 1 - y) * w * 4
        let dstRow = y * w * 4
        for i in 0..<(w * 4) { bottomUp[dstRow + i] = px[srcRow + i] }
    }
    guard let ctx = CGContext(data: &bottomUp, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let img = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst)
}

func alphaBounds(_ px: [UInt8], _ w: Int, _ h: Int, threshold: UInt8 = 8,
                 in rect: (x: Int, y: Int, w: Int, h: Int)? = nil) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
    let r = rect ?? (0, 0, w, h)
    var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
    for y in r.y..<min(r.y + r.h, h) {
        for x in r.x..<min(r.x + r.w, w) {
            if px[(y * w + x) * 4 + 3] > threshold {
                if x < x0 { x0 = x }; if x > x1 { x1 = x }
                if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        }
    }
    return x1 >= x0 ? (x0, y0, x1, y1) : nil
}


// Connected components of opaque pixels. Colourway renders are laid out so
// their bounding boxes overlap (the wings are drawn at an angle), so no
// rectangle can isolate one — but they never touch, so a flood fill can.
// It also separates the baked-in colourway label into a component of its own.
func components(_ px: [UInt8], _ w: Int, _ h: Int, threshold: UInt8 = 8) -> (label: [Int], count: Int) {
    var label = [Int](repeating: -1, count: w * h)
    var next = 0
    var stack: [Int] = []
    for start in 0..<(w * h) where label[start] == -1 && px[start * 4 + 3] > threshold {
        label[start] = next
        stack.append(start)
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let q = ny * w + nx
                if label[q] == -1 && px[q * 4 + 3] > threshold {
                    label[q] = next
                    stack.append(q)
                }
            }
        }
        next += 1
    }
    return (label, next)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: wingcut bbox <in.png> [x y w h] | wingcut make <in.png> <out.png> <cx> <cy> <cw> <ch> [clearX clearY clearW clearH]\n".data(using: .utf8)!)
    exit(2)
}

guard var (px, w, h) = loadRGBA(args[2]) else { print("load failed"); exit(1) }

if args[1] == "dekey" {
    // dekey <in> <out> [near] [far]
    //
    // For renders published on a flat studio background instead of with an
    // alpha channel. Everything within `near` of the sampled background colour
    // becomes transparent, everything past `far` stays, and the band between
    // the two is feathered so the edge does not turn into a staircase.
    let out = args[3]
    let near = args.count > 4 ? Double(args[4])! : 12
    let far = args.count > 5 ? Double(args[5])! : 44

    // Background = median of the four corners, so one stray pixel cannot
    // decide what gets erased.
    var corners: [(Double, Double, Double)] = []
    for (x, y) in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)] {
        let i = (y * w + x) * 4
        corners.append((Double(px[i]), Double(px[i+1]), Double(px[i+2])))
    }
    let bg = (corners.map { $0.0 }.sorted()[1], corners.map { $0.1 }.sorted()[1], corners.map { $0.2 }.sorted()[1])

    var alpha = [Double](repeating: 255, count: w * h)
    for i in 0..<(w * h) {
        let o = i * 4
        let d = max(abs(Double(px[o]) - bg.0), max(abs(Double(px[o+1]) - bg.1), abs(Double(px[o+2]) - bg.2)))
        if d <= near { alpha[i] = 0 }
        else if d < far { alpha[i] = 255 * (d - near) / (far - near) }
    }

    // A light panel on the sail can read as background. Transparency only
    // counts when it reaches the border, so flood the outside and restore
    // every hole the keying punched inside the wing.
    var outside = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    for x in 0..<w {
        for y in [0, h - 1] where alpha[y * w + x] < 8 && !outside[y * w + x] {
            outside[y * w + x] = true; stack.append(y * w + x)
        }
    }
    for y in 0..<h {
        for x in [0, w - 1] where alpha[y * w + x] < 8 && !outside[y * w + x] {
            outside[y * w + x] = true; stack.append(y * w + x)
        }
    }
    while let p = stack.popLast() {
        let x = p % w, y = p / w
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            let q = ny * w + nx
            if !outside[q] && alpha[q] < 8 { outside[q] = true; stack.append(q) }
        }
    }
    for i in 0..<(w * h) where alpha[i] < 255 && !outside[i] { alpha[i] = 255 }

    // Unpremultiply against the background so feathered edge pixels keep the
    // sail's colour instead of a grey fringe.
    for i in 0..<(w * h) {
        let o = i * 4
        let a = alpha[i] / 255
        if a <= 0 { px[o] = 0; px[o+1] = 0; px[o+2] = 0; px[o+3] = 0; continue }
        if a < 1 {
            let chans = [Double(px[o]), Double(px[o+1]), Double(px[o+2])]
            let bgs = [bg.0, bg.1, bg.2]
            for c in 0..<3 {
                let v = (chans[c] - (1 - a) * bgs[c]) / a
                px[o + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        // Store premultiplied: that is the layout this tool reads and writes.
        px[o] = UInt8((Double(px[o]) * a).rounded())
        px[o+1] = UInt8((Double(px[o+1]) * a).rounded())
        px[o+2] = UInt8((Double(px[o+2]) * a).rounded())
        px[o+3] = UInt8(alpha[i].rounded())
    }

    // Drop the drop-shadow and any speck the key left behind.
    let (label, n) = components(px, w, h, threshold: 24)
    if n > 0 {
        var area = [Int](repeating: 0, count: n)
        for i in 0..<(w * h) where label[i] >= 0 { area[label[i]] += 1 }
        let biggest = (0..<n).max(by: { area[$0] < area[$1] })!
        for i in 0..<(w * h) where label[i] != biggest {
            px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
        }
    }

    guard let b = alphaBounds(px, w, h) else { print("nothing left"); exit(1) }
    let bw = b.x1 - b.x0 + 1, bh = b.y1 - b.y0 + 1
    let side = 500, pad = 10
    let scale = min(Double(side - 2 * pad) / Double(bw), Double(side - 2 * pad) / Double(bh))
    let dw = Int((Double(bw) * scale).rounded()), dh = Int((Double(bh) * scale).rounded())
    let ox = (side - dw) / 2, oy = (side - dh) / 2
    var outPx = [UInt8](repeating: 0, count: side * side * 4)
    for dy in 0..<dh {
        for dx in 0..<dw {
            let sx0 = b.x0 + Int(Double(dx) / scale), sx1 = min(b.x0 + Int(Double(dx + 1) / scale), b.x1 + 1)
            let sy0 = b.y0 + Int(Double(dy) / scale), sy1 = min(b.y0 + Int(Double(dy + 1) / scale), b.y1 + 1)
            var r = 0, g = 0, bl = 0, a = 0, n2 = 0
            for sy in sy0..<max(sy1, sy0 + 1) {
                for sx in sx0..<max(sx1, sx0 + 1) {
                    guard sx < w, sy < h else { continue }
                    let i = (sy * w + sx) * 4
                    r += Int(px[i]); g += Int(px[i+1]); bl += Int(px[i+2]); a += Int(px[i+3]); n2 += 1
                }
            }
            guard n2 > 0 else { continue }
            let o = ((oy + dy) * side + (ox + dx)) * 4
            outPx[o] = UInt8(r / n2); outPx[o+1] = UInt8(g / n2); outPx[o+2] = UInt8(bl / n2); outPx[o+3] = UInt8(a / n2)
        }
    }
    if writePNG(outPx, side, side, to: out) {
        print("wrote \(out)  bg=\(Int(bg.0)),\(Int(bg.1)),\(Int(bg.2))  \(bw)x\(bh) -> \(dw)x\(dh)")
    } else { print("write failed"); exit(1) }
    exit(0)
}

if args[1] == "comps" {
    let (label, n) = components(px, w, h)
    var area = [Int](repeating: 0, count: n)
    var x0 = [Int](repeating: Int.max, count: n), y0 = [Int](repeating: Int.max, count: n)
    var x1 = [Int](repeating: Int.min, count: n), y1 = [Int](repeating: Int.min, count: n)
    for i in 0..<(w * h) where label[i] >= 0 {
        let c = label[i], x = i % w, y = i / w
        area[c] += 1
        if x < x0[c] { x0[c] = x }; if x > x1[c] { x1[c] = x }
        if y < y0[c] { y0[c] = y }; if y > y1[c] { y1[c] = y }
    }
    for c in (0..<n).sorted(by: { area[$0] > area[$1] }).prefix(12) {
        print("comp \(c)  area=\(area[c])  x=\(x0[c]) y=\(y0[c]) w=\(x1[c] - x0[c] + 1) h=\(y1[c] - y0[c] + 1)")
    }
    exit(0)
}

if args[1] == "keep" {
    // keep <in> <out> <comp ids, comma separated>
    let out = args[3]
    let keep = Set(args[4].split(separator: ",").compactMap { Int($0) })
    let (label, _) = components(px, w, h)
    for i in 0..<(w * h) where !(label[i] >= 0 && keep.contains(label[i])) {
        px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
    }
    guard let b = alphaBounds(px, w, h) else { print("nothing kept"); exit(1) }
    let bw = b.x1 - b.x0 + 1, bh = b.y1 - b.y0 + 1
    let side = 500, pad = 10
    let scale = min(Double(side - 2 * pad) / Double(bw), Double(side - 2 * pad) / Double(bh))
    let dw = Int((Double(bw) * scale).rounded()), dh = Int((Double(bh) * scale).rounded())
    let ox = (side - dw) / 2, oy = (side - dh) / 2
    var outPx = [UInt8](repeating: 0, count: side * side * 4)
    for dy in 0..<dh {
        for dx in 0..<dw {
            let sx0 = b.x0 + Int(Double(dx) / scale), sx1 = min(b.x0 + Int(Double(dx + 1) / scale), b.x1 + 1)
            let sy0 = b.y0 + Int(Double(dy) / scale), sy1 = min(b.y0 + Int(Double(dy + 1) / scale), b.y1 + 1)
            var r = 0, g = 0, bl = 0, a = 0, n = 0
            for sy in sy0..<max(sy1, sy0 + 1) {
                for sx in sx0..<max(sx1, sx0 + 1) {
                    guard sx < w, sy < h else { continue }
                    let i = (sy * w + sx) * 4
                    r += Int(px[i]); g += Int(px[i+1]); bl += Int(px[i+2]); a += Int(px[i+3]); n += 1
                }
            }
            guard n > 0 else { continue }
            let o = ((oy + dy) * side + (ox + dx)) * 4
            outPx[o] = UInt8(r / n); outPx[o+1] = UInt8(g / n); outPx[o+2] = UInt8(bl / n); outPx[o+3] = UInt8(a / n)
        }
    }
    if writePNG(outPx, side, side, to: out) {
        print("wrote \(out)  kept \(keep.sorted())  \(bw)x\(bh) -> \(dw)x\(dh)")
    } else { print("write failed"); exit(1) }
    exit(0)
}

if args[1] == "cols" {
    // Column occupancy: prints the runs of fully transparent columns, which is
    // where one colourway render ends and the next begins.
    var empties: [Int] = []
    for x in 0..<w {
        var any = false
        let thr = args.count >= 4 ? UInt8(args[3]) ?? 8 : 8
        for y in 0..<h where px[(y * w + x) * 4 + 3] > thr { any = true; break }
        if !any { empties.append(x) }
    }
    var runs: [(Int, Int)] = []
    for x in empties {
        if var last = runs.last, last.1 == x - 1 { last.1 = x; runs[runs.count - 1] = last }
        else { runs.append((x, x)) }
    }
    print("empty column runs:", runs.map { "\($0.0)-\($0.1)" }.joined(separator: " "))
    exit(0)
}

if args[1] == "rows" {
    var empties: [Int] = []
    for y in 0..<h {
        var any = false
        for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 { any = true; break }
        if !any { empties.append(y) }
    }
    var runs: [(Int, Int)] = []
    for y in empties {
        if var last = runs.last, last.1 == y - 1 { last.1 = y; runs[runs.count - 1] = last }
        else { runs.append((y, y)) }
    }
    print("empty row runs:", runs.map { "\($0.0)-\($0.1)" }.joined(separator: " "))
    exit(0)
}

if args[1] == "bbox" {
    var rect: (Int, Int, Int, Int)? = nil
    if args.count >= 7 { rect = (Int(args[3])!, Int(args[4])!, Int(args[5])!, Int(args[6])!) }
    if let b = alphaBounds(px, w, h, in: rect) {
        print("image \(w)x\(h)  opaque bbox x=\(b.x0) y=\(b.y0) w=\(b.x1 - b.x0 + 1) h=\(b.y1 - b.y0 + 1)")
    } else { print("image \(w)x\(h)  fully transparent in that region") }
    exit(0)
}

// make
let out = args[3]
let cx = Int(args[4])!, cy = Int(args[5])!, cw = Int(args[6])!, ch = Int(args[7])!

// Optional: wipe a label baked into the transparent area (colourway codes).
if args.count >= 12 {
    let lx = Int(args[8])!, ly = Int(args[9])!, lw = Int(args[10])!, lh = Int(args[11])!
    for y in ly..<min(ly + lh, h) {
        for x in lx..<min(lx + lw, w) {
            let i = (y * w + x) * 4
            px[i] = 0; px[i+1] = 0; px[i+2] = 0; px[i+3] = 0
        }
    }
}

// Trim to what is actually drawn inside the crop, so the wing fills the frame
// the same way the existing library images do.
guard let b = alphaBounds(px, w, h, in: (cx, cy, cw, ch)) else { print("nothing opaque in crop"); exit(1) }
let bw = b.x1 - b.x0 + 1, bh = b.y1 - b.y0 + 1

let side = 500
let pad = 10
let scale = min(Double(side - 2 * pad) / Double(bw), Double(side - 2 * pad) / Double(bh))
let dw = Int((Double(bw) * scale).rounded()), dh = Int((Double(bh) * scale).rounded())
let ox = (side - dw) / 2, oy = (side - dh) / 2

var outPx = [UInt8](repeating: 0, count: side * side * 4)
// Box filter: the sources are larger than 500px, so averaging the covered
// source pixels avoids the aliasing a nearest-neighbour pick would give.
for dy in 0..<dh {
    for dx in 0..<dw {
        let sx0 = b.x0 + Int(Double(dx) / scale), sx1 = min(b.x0 + Int(Double(dx + 1) / scale), b.x1 + 1)
        let sy0 = b.y0 + Int(Double(dy) / scale), sy1 = min(b.y0 + Int(Double(dy + 1) / scale), b.y1 + 1)
        var r = 0, g = 0, bl = 0, a = 0, n = 0
        for sy in sy0..<max(sy1, sy0 + 1) {
            for sx in sx0..<max(sx1, sx0 + 1) {
                guard sx < w, sy < h else { continue }
                let i = (sy * w + sx) * 4
                r += Int(px[i]); g += Int(px[i+1]); bl += Int(px[i+2]); a += Int(px[i+3]); n += 1
            }
        }
        guard n > 0 else { continue }
        let o = ((oy + dy) * side + (ox + dx)) * 4
        outPx[o] = UInt8(r / n); outPx[o+1] = UInt8(g / n); outPx[o+2] = UInt8(bl / n); outPx[o+3] = UInt8(a / n)
    }
}

if writePNG(outPx, side, side, to: out) {
    print("wrote \(out)  source bbox \(bw)x\(bh) -> \(dw)x\(dh) on \(side)x\(side)")
} else { print("write failed"); exit(1) }
