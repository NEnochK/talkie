import SwiftUI

/// Semantic colours for the whole app, defined explicitly for both appearances.
///
/// These resolve through a dynamic `UIColor`, so they follow the trait collection
/// — which means they react both to the system setting and to an in-app
/// `.preferredColorScheme` override, with no duplicate plumbing.
///
/// Dark is built on a near-black with a slight blue cast rather than pure black:
/// lifted surfaces need something to lift away from, and #000 leaves cards with
/// nothing to separate them from the background.
enum Palette {
	// Structure
	static let background = dynamic(light: 0xF4F5F8, dark: 0x0B0D10)
	static let surface = dynamic(light: 0xFFFFFF, dark: 0x16191F)
	static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x1E222A)
	static let separator = dynamic(light: 0x1013_1A, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)

	// Text
	static let textPrimary = dynamic(light: 0x10131A, dark: 0xF2F4F7)
	static let textSecondary = dynamic(light: 0x5B6472, dark: 0x99A1AE)

	// Brand
	static let accent = dynamic(light: 0x0A6CF5, dark: 0x4C9EFF)

	// Connection and transmission states
	static let idle = dynamic(light: 0x98A0AC, dark: 0x5C636E)
	static let pending = dynamic(light: 0xE08600, dark: 0xFF9F0A)
	static let live = dynamic(light: 0x1BA94C, dark: 0x30D158)
	static let transmitting = dynamic(light: 0xE5342A, dark: 0xFF453A)
	static let warning = dynamic(light: 0xC26A00, dark: 0xFFB340)

	private static func dynamic(
		light: UInt32,
		dark: UInt32,
		lightAlpha: Double = 1,
		darkAlpha: Double = 1
	) -> Color {
		Color(uiColor: UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(hex: dark, alpha: darkAlpha)
				: UIColor(hex: light, alpha: lightAlpha)
		})
	}
}

private extension UIColor {
	convenience init(hex: UInt32, alpha: Double) {
		self.init(
			red: CGFloat((hex >> 16) & 0xFF) / 255,
			green: CGFloat((hex >> 8) & 0xFF) / 255,
			blue: CGFloat(hex & 0xFF) / 255,
			alpha: CGFloat(alpha))
	}
}

/// Which appearance the user picked, independent of the system setting.
enum AppearanceSetting: String, CaseIterable, Identifiable {
	case system, light, dark

	var id: String { rawValue }

	var label: String {
		switch self {
		case .system: return "System"
		case .light: return "Light"
		case .dark: return "Dark"
		}
	}

	var symbol: String {
		switch self {
		case .system: return "circle.lefthalf.filled"
		case .light: return "sun.max"
		case .dark: return "moon"
		}
	}

	/// `nil` hands control back to the system.
	var colorScheme: ColorScheme? {
		switch self {
		case .system: return nil
		case .light: return .light
		case .dark: return .dark
		}
	}
}

/// Grouped panel used for every block of content, so the layout reads as a stack
/// of surfaces instead of text floating on a void.
struct CardBackground: ViewModifier {
	var raised = false

	func body(content: Content) -> some View {
		content
			.padding(16)
			.background(
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(raised ? Palette.surfaceRaised : Palette.surface))
			.overlay(
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.strokeBorder(Palette.separator, lineWidth: 1))
	}
}

extension View {
	func card(raised: Bool = false) -> some View {
		modifier(CardBackground(raised: raised))
	}
}
