#!/usr/bin/env swift
import Cocoa
import CoreGraphics

// Builds Piko's macOS AppIcon.icns and Xcode AppIcon.appiconset PNGs from the
// 1024x1024 framed squircle master at docs/images/piko-icon.png.

func resizeCGImage(_ src: CGImage, pixelSize: Int) -> CGImage? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    return ctx.makeImage()
}

func pngData(for image: CGImage) throws -> Data {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    return data
}

func bigEndianUInt32(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return Data(bytes: &be, count: 4)
}

let args = CommandLine.arguments
let repoRoot = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath)
let masterURL = repoRoot.appendingPathComponent("docs/images/piko-icon.png")

guard let masterNS = NSImage(contentsOf: masterURL),
      let masterCG = masterNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Failed to load master icon at \(masterURL.path)\n", stderr)
    exit(1)
}

let fm = FileManager.default

let specs: [(icnsTag: String, assetName: String, sizeLabel: String, scaleLabel: String, px: Int)] = [
    ("icp4", "piko-16x16.png",      "16x16",   "1x", 16),
    ("ic11", "piko-16x16@2x.png",   "16x16",   "2x", 32),
    ("icp5", "piko-32x32.png",      "32x32",   "1x", 32),
    ("ic12", "piko-32x32@2x.png",   "32x32",   "2x", 64),
    ("ic07", "piko-128x128.png",    "128x128", "1x", 128),
    ("ic13", "piko-128x128@2x.png", "128x128", "2x", 256),
    ("ic08", "piko-256x256.png",    "256x256", "1x", 256),
    ("ic14", "piko-256x256@2x.png", "256x256", "2x", 512),
    ("ic09", "piko-512x512.png",    "512x512", "1x", 512),
    ("ic10", "piko-512x512@2x.png", "512x512", "2x", 1024),
]

let appIconSetDir = repoRoot.appendingPathComponent("reminders-menubar/Resources/Assets.xcassets/AppIcon.appiconset")
if let existing = try? fm.contentsOfDirectory(at: appIconSetDir, includingPropertiesForKeys: nil) {
    for file in existing where file.pathExtension == "png" {
        try? fm.removeItem(at: file)
    }
}

var contentsImages: [[String: String]] = []
var icnsBody = Data()

for spec in specs {
    guard let img = resizeCGImage(masterCG, pixelSize: spec.px) else {
        fputs("Failed to render \(spec.assetName)\n", stderr)
        exit(1)
    }
    let data = try pngData(for: img)
    try data.write(to: appIconSetDir.appendingPathComponent(spec.assetName))

    // Append ICNS chunk: 4-byte OSType tag + 4-byte chunk length (8 + payload) + PNG bytes
    icnsBody.append(contentsOf: spec.icnsTag.utf8)
    icnsBody.append(bigEndianUInt32(UInt32(8 + data.count)))
    icnsBody.append(data)

    contentsImages.append([
        "filename": spec.assetName,
        "idiom": "mac",
        "scale": spec.scaleLabel,
        "size": spec.sizeLabel
    ])
}

let contentsJSON: [String: Any] = [
    "images": contentsImages,
    "info": [
        "author": "xcode",
        "version": 1
    ]
]
let jsonData = try JSONSerialization.data(withJSONObject: contentsJSON, options: [.prettyPrinted, .sortedKeys])
try jsonData.write(to: appIconSetDir.appendingPathComponent("Contents.json"))

var icnsData = Data()
icnsData.append(contentsOf: "icns".utf8)
icnsData.append(bigEndianUInt32(UInt32(8 + icnsBody.count)))
icnsData.append(icnsBody)

let icnsOut = repoRoot.appendingPathComponent("reminders-menubar/Resources/AppIcon.icns")
try icnsData.write(to: icnsOut)

// Quick sanity check that AppKit decodes the generated ICNS cleanly with all representations
guard let verified = NSImage(contentsOf: icnsOut), !verified.representations.isEmpty else {
    fputs("Verification failed: AppKit could not decode \(icnsOut.path)\n", stderr)
    exit(1)
}
print("Generated \(icnsOut.path) (\(verified.representations.count) representations) and updated \(appIconSetDir.path)")
