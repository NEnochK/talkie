import SwiftUI
import TalkieCore

struct ContentView: View {
	@State private var model = CallViewModel()
	@State private var store = ChannelStore()
	@State private var isShowingChannelPicker = false
	@AppStorage("com.talkie.appearance") private var appearanceRaw = AppearanceSetting.system.rawValue

	private var appearance: AppearanceSetting {
		AppearanceSetting(rawValue: appearanceRaw) ?? .system
	}

	var body: some View {
		NavigationStack {
			ZStack {
				Palette.background.ignoresSafeArea()

				ScrollView {
					VStack(spacing: 16) {
						channelRow

						ConnectionStatusView(
							label: model.connectionLabel,
							state: model.snapshot.connection,
							peerIsTalking: model.snapshot.peerIsTalking,
							peerIsMuted: model.snapshot.peerIsMuted,
							route: model.snapshot.route)

						if model.isRunning {
							modePicker
							controls.padding(.vertical, 8)
						} else {
							startPrompt
						}

						if let message = model.snapshot.errorMessage {
							notice(message, symbol: "exclamationmark.triangle.fill", tint: Palette.transmitting)
						}

						if model.showsMicrophoneHint {
							notice(
								"Using the phone microphone. Connect AirPods for hands-free use.",
								symbol: "info.circle.fill",
								tint: Palette.warning)
						}

						if model.isRunning {
							LinkQualityView(
								stats: model.snapshot.stats,
								startsExpanded: model.isLoopback)
						}
					}
					.padding(.horizontal, 16)
					.padding(.vertical, 12)
				}
			}
			.navigationTitle("Talkie")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { appearanceMenu }
				ToolbarItem(placement: .topBarTrailing) {
					if model.isRunning {
						// The root `.tint` overrides the destructive role's colour,
						// so state it explicitly.
						Button("End") { model.stop() }
							.foregroundStyle(Palette.transmitting)
					}
				}
			}
		}
		.tint(Palette.accent)
		.preferredColorScheme(appearance.colorScheme)
		.task {
			model.setChannel(store.current)
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-uiDemoChannel") {
				isShowingChannelPicker = true
			}
			model.startLoopbackIfRequested()
			#endif
		}
		.sheet(isPresented: $isShowingChannelPicker) {
			ChannelPickerView(store: store) { channel in
				store.select(channel)
				model.setChannel(channel)
			}
		}
		.onOpenURL { url in
			// talkie://join?c=<name>, from a shared QR code.
			guard let channel = Channel(url: url) else { return }
			isShowingChannelPicker = false
			store.select(channel)
			model.setChannel(channel)
		}
	}

	/// Channel is shown above everything else: on a radio, which channel you are
	/// on is the first thing you need to know, and the commonest thing to get wrong.
	private var channelRow: some View {
		Button {
			isShowingChannelPicker = true
		} label: {
			HStack(spacing: 10) {
				Image(systemName: "number")
					.font(.subheadline.weight(.bold))
					.foregroundStyle(Palette.accent)
				VStack(alignment: .leading, spacing: 1) {
					Text(store.current.name)
						.font(.headline)
						.foregroundStyle(Palette.textPrimary)
					Text("Channel")
						.font(.caption)
						.foregroundStyle(Palette.textSecondary)
				}
				Spacer()
				Text("Change")
					.font(.subheadline.weight(.medium))
					.foregroundStyle(Palette.accent)
				Image(systemName: "chevron.right")
					.font(.caption.weight(.semibold))
					.foregroundStyle(Palette.textSecondary)
			}
			.card()
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Channel \(store.current.name). Change channel")
	}

	private var appearanceMenu: some View {
		Menu {
			Picker("Appearance", selection: $appearanceRaw) {
				ForEach(AppearanceSetting.allCases) { option in
					Label(option.label, systemImage: option.symbol).tag(option.rawValue)
				}
			}
		} label: {
			Image(systemName: appearance.symbol)
		}
		.accessibilityLabel("Appearance")
	}

	private var modePicker: some View {
		Picker("Mode", selection: Binding(
			get: { model.mode },
			set: { model.setMode($0) })) {
			ForEach(TalkMode.allCases) { mode in
				Text(mode.rawValue).tag(mode)
			}
		}
		.pickerStyle(.segmented)
	}

	@ViewBuilder
	private var controls: some View {
		switch model.mode {
		case .pushToTalk:
			PTTButton(
				isTransmitting: model.snapshot.isTransmitting,
				isEnabled: model.isConnected,
				onPress: { model.pushToTalkBegan() },
				onRelease: { model.pushToTalkEnded() })
		case .openMic:
			Button {
				model.toggleMute()
			} label: {
				Label(
					model.snapshot.isMuted ? "Unmute" : "Mute",
					systemImage: model.snapshot.isMuted ? "mic.slash.fill" : "mic.fill")
					.font(.title3.weight(.semibold))
					.frame(maxWidth: .infinity)
					.padding(.vertical, 18)
					.foregroundStyle(.white)
					.background(
						RoundedRectangle(cornerRadius: 16, style: .continuous)
							.fill(model.snapshot.isMuted ? Palette.idle : Palette.accent))
			}
			.buttonStyle(.plain)
			.disabled(!model.isConnected)
			.opacity(model.isConnected ? 1 : 0.5)
		}
	}

	private var startPrompt: some View {
		VStack(spacing: 16) {
			Text("Talk to a nearby iPhone over Bluetooth. No network, no account.")
				.font(.subheadline)
				.foregroundStyle(Palette.textSecondary)
				.multilineTextAlignment(.center)
				.padding(.top, 8)

			Button {
				model.start()
			} label: {
				Text("Start")
					.font(.title3.weight(.semibold))
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 16)
					.background(
						RoundedRectangle(cornerRadius: 16, style: .continuous)
							.fill(Palette.accent)
							.shadow(color: Palette.accent.opacity(0.35), radius: 12, y: 5))
			}
			.buttonStyle(.plain)

			#if DEBUG
			loopbackControls
			#endif
		}
	}

	private func notice(_ message: String, symbol: String, tint: Color) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: symbol)
				.foregroundStyle(tint)
			Text(message)
				.foregroundStyle(Palette.textSecondary)
			Spacer(minLength: 0)
		}
		.font(.footnote)
		.card()
	}
}

#if DEBUG
extension ContentView {
	/// Single-device test rig: your own voice goes through encode, a lossy fake
	/// transport, the jitter buffer and decode, then back out to the AirPods.
	/// Tuning concealment against reproducible impairment beats chasing it over a
	/// live radio.
	@ViewBuilder
	fileprivate var loopbackControls: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Loopback test")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Palette.textPrimary)

			labelledSlider(
				"Packet loss",
				value: $model.loopbackLossPercent,
				range: 0...50,
				format: "%.0f%%")
			// Must be able to exceed the jitter buffer's 160 ms ceiling. Measured
			// offline, anything under that is absorbed completely — 120 ms of jitter
			// produced output bit-identical to a clean run, so the old 0-120 range
			// could not affect the audio at all.
			labelledSlider(
				"Jitter",
				value: $model.loopbackJitterMilliseconds,
				range: 0...400,
				format: "%.0f ms")
			// The control that actually makes loss audible: FEC repairs isolated
			// drops but not runs of them.
			labelledSlider(
				"Loss burst",
				value: $model.loopbackBurstFrames,
				range: 1...8,
				format: "%.0f frames")

			Text("Jitter under ~160 ms is absorbed by the buffer. Uniform loss is largely repaired by Opus FEC — raise the burst length to hear it.")
				.font(.caption)
				.foregroundStyle(Palette.textSecondary)

			Button("Start loopback") { model.startLoopback() }
				.font(.subheadline.weight(.medium))
				.frame(maxWidth: .infinity)
				.padding(.vertical, 10)
				.background(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.fill(Palette.accent.opacity(0.16)))
				.foregroundStyle(Palette.accent)
				.buttonStyle(.plain)
		}
		.card(raised: true)
	}

	fileprivate func labelledSlider(
		_ name: String,
		value: Binding<Double>,
		range: ClosedRange<Double>,
		format: String
	) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(name)
					.foregroundStyle(Palette.textSecondary)
				Spacer()
				Text(String(format: format, value.wrappedValue))
					.monospacedDigit()
					.foregroundStyle(Palette.textPrimary)
			}
			.font(.footnote)
			Slider(value: value, in: range)
		}
	}
}
#endif

#Preview("Dark") {
	ContentView().preferredColorScheme(.dark)
}

#Preview("Light") {
	ContentView().preferredColorScheme(.light)
}
