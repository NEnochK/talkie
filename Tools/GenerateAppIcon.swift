import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders Talkie's app icon at 1024x1024 in the three appearances iOS asks for.
//
// Kept as code rather than a checked-in binary so the mark can be adjusted and
// re-rendered, and so the geometry is reviewable.
//
//   swift Tools/GenerateAppIcon.swift [output-directory]
//
// The mark is a centre dot with concentric arcs radiating both left and right:
// a two-way radio, not a broadcast. Symmetric, no text, and it still reads as
// something deliberate at 40 points on a home screen.

let side = 1024.0

struct Palette {
	let backgroundTop: CGColor
	let backgroundBottom: CGColor
	let mark: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
	CGColor(
		red: CGFloat((hex >> 16) & 0xFF) / 255,
		green: CGFloat((hex >> 8) & 0xFF) / 255,
		blue: CGFloat(hex & 0xFF) / 255,
		alpha: alpha)
}

let variants: [(name: String, palette: Palette)] = [
	// Light / any appearance: the app's accent blue.
	("AppIcon", Palette(
		backgroundTop: rgb(0x5AA9FF),
		backgroundBottom: rgb(0x0A55DC),
		mark: rgb(0xFFFFFF))),
	// Dark: the same near-black the UI uses, with the accent carrying the mark.
	("AppIcon-Dark", Palette(
		backgroundTop: rgb(0x18202C),
		backgroundBottom: rgb(0x05080D),
		mark: rgb(0x62ABFF))),
	// Tinted: iOS derives a monochrome icon from luminance, so this has to be
	// greyscale — any colour here would simply be discarded.
	("AppIcon-Tinted", Palette(
		backgroundTop: rgb(0x2A2A2A),
		backgroundBottom: rgb(0x0A0A0A),
		mark: rgb(0xF2F2F2))),
]

func makeContext() -> CGContext {
	guard let context = CGContext(
		data: nil,
		width: Int(side),
		height: Int(side),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		// noneSkipLast, not premultipliedLast: App Store Connect rejects an app icon
		// that carries an alpha channel, even a fully opaque one.
		bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
	else { fatalError("could not create bitmap context") }
	context.setAllowsAntialiasing(true)
	context.interpolationQuality = .high
	return context
}

func draw(_ palette: Palette, into context: CGContext) {
	let full = CGRect(x: 0, y: 0, width: side, height: side)

	// Full-bleed square: iOS applies the rounded mask itself.
	let space = CGColorSpaceCreateDeviceRGB()
	guard let gradient = CGGradient(
		colorsSpace: space,
		colors: [palette.backgroundTop, palette.backgroundBottom] as CFArray,
		locations: [0, 1])
	else { fatalError("could not build gradient") }

	context.saveGState()
	context.addRect(full)
	context.clip()
	context.drawLinearGradient(
		gradient,
		start: CGPoint(x: 0, y: side),
		end: CGPoint(x: 0, y: 0),
		options: [])
	context.restoreGState()

	let centre = CGPoint(x: side / 2, y: side / 2)
	context.setFillColor(palette.mark)
	context.setStrokeColor(palette.mark)
	context.setLineCap(.round)

	// Centre dot: the push-to-talk button.
	let dotRadius = side * 0.077
	context.fillEllipse(in: CGRect(
		x: centre.x - dotRadius,
		y: centre.y - dotRadius,
		width: dotRadius * 2,
		height: dotRadius * 2))

	// Two arcs either side. A third reads as clutter below about 60 points.
	let arcs: [(radius: Double, width: Double)] = [
		(side * 0.190, side * 0.052),
		(side * 0.300, side * 0.052),
	]
	let spread = 48.0 * .pi / 180

	for arc in arcs {
		context.setLineWidth(arc.width)
		for facing in [0.0, Double.pi] {
			context.addArc(
				center: centre,
				radius: arc.radius,
				startAngle: facing - spread,
				endAngle: facing + spread,
				clockwise: false)
			context.strokePath()
		}
	}
}

func write(_ image: CGImage, to url: URL) {
	guard let destination = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil)
	else { fatalError("could not open \(url.path) for writing") }
	CGImageDestinationAddImage(destination, image, nil)
	guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

let outputDirectory = CommandLine.arguments.count > 1
	? URL(fileURLWithPath: CommandLine.arguments[1])
	: URL(fileURLWithPath: "Talkie/Assets.xcassets/AppIcon.appiconset")

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
	let context = makeContext()
	draw(variant.palette, into: context)
	guard let image = context.makeImage() else { fatalError("could not render \(variant.name)") }
	let url = outputDirectory.appendingPathComponent("\(variant.name).png")
	write(image, to: url)
	print("wrote \(url.path)")
}
