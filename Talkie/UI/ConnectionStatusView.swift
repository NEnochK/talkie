import SwiftUI

struct ConnectionStatusView: View {
	let label: String
	let state: TransportState
	let peerIsTalking: Bool
	let peerIsMuted: Bool
	let route: String

	var body: some View {
		VStack(spacing: 14) {
			HStack(spacing: 10) {
				StatusDot(color: indicatorColor, pulsing: state == .searching || state == .connecting)
				Text(label)
					.font(.headline)
					.foregroundStyle(Palette.textPrimary)
			}

			if state == .connected {
				HStack(spacing: 7) {
					Image(systemName: peerStatusIcon)
						.symbolEffect(.variableColor, isActive: peerIsTalking)
					Text(peerStatusLabel)
				}
				.font(.subheadline.weight(.medium))
				.foregroundStyle(peerStatusColor)
				.padding(.horizontal, 12)
				.padding(.vertical, 6)
				.background(
					Capsule().fill(peerStatusColor.opacity(0.14)))
			}

			Divider().overlay(Palette.separator)

			HStack(spacing: 6) {
				Image(systemName: "airpods.pro")
				Text(route.isEmpty ? "No audio route" : route)
			}
			.font(.footnote)
			.foregroundStyle(Palette.textSecondary)
		}
		.frame(maxWidth: .infinity)
		.card()
	}

	private var indicatorColor: Color {
		switch state {
		case .idle: return Palette.idle
		case .searching, .connecting: return Palette.pending
		case .connected: return Palette.live
		}
	}

	private var peerStatusColor: Color {
		if peerIsMuted { return Palette.textSecondary }
		return peerIsTalking ? Palette.live : Palette.textSecondary
	}

	private var peerStatusIcon: String {
		if peerIsMuted { return "mic.slash.fill" }
		return peerIsTalking ? "waveform" : "ear"
	}

	private var peerStatusLabel: String {
		if peerIsMuted { return "Peer is muted" }
		return peerIsTalking ? "Peer is talking" : "Listening"
	}
}

/// Status light with a soft halo, so it reads as lit rather than as a flat dot —
/// which matters most on the dark background, where a plain circle disappears.
struct StatusDot: View {
	let color: Color
	var pulsing = false

	@State private var expanded = false

	var body: some View {
		ZStack {
			Circle()
				.fill(color.opacity(0.25))
				.frame(width: 20, height: 20)
				.scaleEffect(expanded ? 1.15 : 0.85)
			Circle()
				.fill(color)
				.frame(width: 10, height: 10)
				.shadow(color: color.opacity(0.8), radius: 4)
		}
		.animation(
			pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
			value: expanded)
		.onAppear { expanded = pulsing }
		.onChange(of: pulsing) { _, active in expanded = active }
	}
}
