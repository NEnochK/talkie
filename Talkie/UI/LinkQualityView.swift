import SwiftUI

/// Diagnostics panel. Every number maps to a specific failure mode, so a bad call
/// can be characterised without attaching a debugger.
struct LinkQualityView: View {
	let stats: LinkStats
	var startsExpanded = false

	@State private var isExpanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button {
				withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
			} label: {
				HStack {
					Text("Link quality")
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(Palette.textPrimary)
					Spacer()
					headline
					Image(systemName: "chevron.right")
						.font(.caption.weight(.semibold))
						.foregroundStyle(Palette.textSecondary)
						.rotationEffect(.degrees(isExpanded ? 90 : 0))
				}
			}
			.buttonStyle(.plain)

			if isExpanded {
				Divider()
					.overlay(Palette.separator)
					.padding(.vertical, 12)

				VStack(spacing: 7) {
					row("Round trip", roundTrip)
					row("Buffer", "\(stats.jitterBufferDepth) / \(stats.targetDepth) frames")
					row("Concealed", "\(stats.concealed)")
					row("FEC recovered", "\(stats.fecRecovered)")
					row("Late", "\(stats.late)")
					row("Rebuffers", "\(stats.rebuffers)")
					row("Radio drops", "\(stats.transmitDrops)")
					row("Playback drops", "\(stats.playbackDrops)")
				}
			}
		}
		.card()
		.onAppear { isExpanded = startsExpanded }
	}

	/// Loss is the one number worth seeing without expanding, and it is colour-coded
	/// because "is this call healthy" should be answerable at a glance.
	private var headline: some View {
		Text(String(format: "%.1f%% loss", stats.lossPercent))
			.font(.caption.monospacedDigit().weight(.medium))
			.foregroundStyle(lossColor)
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Capsule().fill(lossColor.opacity(0.14)))
	}

	private var lossColor: Color {
		switch stats.lossPercent {
		case ..<2: return Palette.live
		case ..<10: return Palette.pending
		default: return Palette.transmitting
		}
	}

	private var roundTrip: String {
		stats.roundTripMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
	}

	private func row(_ name: String, _ value: String) -> some View {
		HStack {
			Text(name)
				.foregroundStyle(Palette.textSecondary)
			Spacer()
			Text(value)
				.foregroundStyle(Palette.textPrimary)
		}
		.font(.footnote.monospacedDigit())
	}
}
