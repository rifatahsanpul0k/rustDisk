#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/dist/icon_build"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
OUTPUT_ICNS="$ROOT_DIR/dist/AppIcon.icns"

rm -rf "$BUILD_DIR"
mkdir -p "$ICONSET_DIR"

echo "==> Rendering 1024x1024 master icon via CoreGraphics..."
swift - "$BUILD_DIR/master_1024.png" <<'EOF'
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else { exit(1) }
let outputPath = args[1]

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let backgroundRect = CGRect(x: 80, y: 80, width: 864, height: 864)
let backgroundPath = NSBezierPath(
    roundedRect: backgroundRect,
    xRadius: 190,
    yRadius: 190
)

context.saveGState()
backgroundPath.addClip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let backgroundColors = [
    CGColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1.0),
    CGColor(red: 0.12, green: 0.17, blue: 0.29, alpha: 1.0),
] as CFArray

if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: backgroundColors,
    locations: [0.0, 1.0]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 944),
        end: CGPoint(x: 512, y: 80),
        options: []
    )
}

NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
backgroundPath.lineWidth = 12
backgroundPath.stroke()
context.restoreGState()

let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 270

context.setLineWidth(56)
context.setLineCap(.round)
context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.10))
context.addArc(
    center: center,
    radius: radius,
    startAngle: 0,
    endAngle: .pi * 2,
    clockwise: false
)
context.strokePath()

context.setStrokeColor(CGColor(red: 0.16, green: 0.85, blue: 0.62, alpha: 1.0))
context.addArc(
    center: center,
    radius: radius,
    startAngle: .pi * 0.25,
    endAngle: .pi * 1.65,
    clockwise: false
)
context.strokePath()

context.setStrokeColor(CGColor(red: 0.96, green: 0.49, blue: 0.20, alpha: 1.0))
context.addArc(
    center: center,
    radius: radius,
    startAngle: .pi * 1.75,
    endAngle: .pi * 0.12,
    clockwise: false
)
context.strokePath()

context.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 0.95))
context.fillEllipse(in: CGRect(x: 448, y: 448, width: 128, height: 128))

context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.20, alpha: 1.0))
context.fillEllipse(in: CGRect(x: 484, y: 484, width: 56, height: 56))

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
EOF

MASTER_PNG="$BUILD_DIR/master_1024.png"

echo "==> Generating Retina .iconset slices..."
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER_PNG" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$MASTER_PNG" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> Compiling AppIcon.icns via iconutil..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
rm -rf "$BUILD_DIR"

echo "==> Created $OUTPUT_ICNS"
