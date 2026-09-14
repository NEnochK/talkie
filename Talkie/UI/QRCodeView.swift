import CoreImage.CIFilterBuiltins
import TalkieCore
import SwiftUI

/// Renders a channel's share link as a QR code.
///
/// The link uses the registered `talkie://` scheme, so the system Camera app can
/// open it directly — the person joining does not need the app open, or even
/// installed-and-running, to act on it.
struct QRCodeView: View {
	let channel: Channel

	var body: some View {
		VStack(spacing: 14) {
			if let image = Self.makeImage(for: channel.shareURL) {
				Image(uiImage: image)
					.interpolation(.none)
					.resizable()
					.scaledToFit()
					.frame(width: 200, height: 200)
					.padding(12)
					.background(
						RoundedRectangle(cornerRadius: 12, style: .continuous)
							// Always light: QR readers need the dark-on-light
							// contrast, so this one panel does not follow the theme.
							.fill(Color.white))
			} else {
				Text("Could not render a code")
					.font(.footnote)
					.foregroundStyle(Palette.textSecondary)
			}

			Text(channel.name)
				.font(.headline)
				.foregroundStyle(Palette.textPrimary)
			Text("Scan to join this channel")
				.font(.footnote)
				.foregroundStyle(Palette.textSecondary)
		}
	}

	private static func makeImage(for url: URL) -> UIImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		filter.correctionLevel = "M"

		guard let output = filter.outputImage else { return nil }
		// Scale up before rasterising; the generator emits roughly one pixel per
		// module, which would otherwise render as mush.
		let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

		let context = CIContext()
		guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
		return UIImage(cgImage: cgImage)
	}
}
