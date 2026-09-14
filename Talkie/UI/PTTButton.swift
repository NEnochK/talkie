import SwiftUI

/// Press-and-hold transmit button.
///
/// Uses a zero-distance drag rather than a tap gesture so press and release are
/// separate edges, and the radio stops the instant a finger lifts.
struct PTTButton: View {
	let isTransmitting: Bool
	let isEnabled: Bool
	let onPress: () -> Void
	let onRelease: () -> Void

	@State private var isPressed = false

	var body: some View {
		ZStack {
			// Halo only while live, so the transmitting state is unmistakable
			// across the room and in the dark.
			if isTransmitting {
				Circle()
					.fill(Palette.transmitting.opacity(0.18))
					.frame(width: 264, height: 264)
					.blur(radius: 12)
			}

			Circle()
				.fill(fill)
				.overlay(
					Circle().strokeBorder(
						isEnabled ? Color.white.opacity(0.18) : Palette.separator,
						lineWidth: 1))
				.shadow(
					color: isEnabled ? shadowColor.opacity(0.45) : .clear,
					radius: isTransmitting ? 22 : 14,
					y: 6)
				.scaleEffect(isPressed ? 0.95 : 1)

			VStack(spacing: 8) {
				Image(systemName: isTransmitting ? "waveform" : "mic.fill")
					.font(.system(size: 44, weight: .semibold))
					.symbolEffect(.variableColor, isActive: isTransmitting)
				Text(isTransmitting ? "Transmitting" : "Hold to talk")
					.font(.headline)
			}
			.foregroundStyle(isEnabled ? Color.white : Palette.textSecondary)
		}
		.animation(.easeOut(duration: 0.12), value: isPressed)
		.animation(.easeOut(duration: 0.18), value: isTransmitting)
		.frame(width: 240, height: 240)
		.contentShape(Circle())
		.gesture(
			DragGesture(minimumDistance: 0)
				.onChanged { _ in
					guard isEnabled, !isPressed else { return }
					isPressed = true
					onPress()
				}
				.onEnded { _ in
					guard isPressed else { return }
					isPressed = false
					onRelease()
				}
		)
		.disabled(!isEnabled)
		.accessibilityLabel("Push to talk")
		.accessibilityHint("Hold to transmit, release to stop")
		.accessibilityAddTraits(isTransmitting ? [.isSelected] : [])
	}

	private var fill: LinearGradient {
		let colors: [Color]
		if !isEnabled {
			colors = [Palette.surfaceRaised, Palette.surfaceRaised]
		} else if isTransmitting {
			colors = [Palette.transmitting, Palette.transmitting.opacity(0.78)]
		} else {
			colors = [Palette.accent, Palette.accent.opacity(0.78)]
		}
		return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
	}

	private var shadowColor: Color {
		isTransmitting ? Palette.transmitting : Palette.accent
	}
}
