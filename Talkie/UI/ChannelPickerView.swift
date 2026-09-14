import SwiftUI
import TalkieCore

/// Channel entry: type a name, pick a recent one, or scan someone's code.
struct ChannelPickerView: View {
	let store: ChannelStore
	let onSelect: (Channel) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var typedName = ""
	@State private var isShowingShare = false
	@State private var isShowingScanner = false
	@FocusState private var isFieldFocused: Bool

	private var typedChannel: Channel? { Channel(name: typedName) }

	var body: some View {
		NavigationStack {
			ZStack {
				Palette.background.ignoresSafeArea()

				ScrollView {
					VStack(spacing: 16) {
						entryCard
						sharingCard
						if !store.recents.isEmpty { recentsCard }
					}
					.padding(16)
				}
			}
			.navigationTitle("Channel")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
			.sheet(isPresented: $isShowingShare) {
				shareSheet
			}
			.sheet(isPresented: $isShowingScanner) {
				scannerSheet
			}
		}
		.tint(Palette.accent)
	}

	private var entryCard: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Join a channel")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Palette.textPrimary)

			Text("Everyone who types the same name ends up in the same room. Names are not case sensitive.")
				.font(.footnote)
				.foregroundStyle(Palette.textSecondary)

			HStack(spacing: 10) {
				TextField("Channel name", text: $typedName)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.join)
					.focused($isFieldFocused)
					.onSubmit(join)
					.padding(.horizontal, 12)
					.padding(.vertical, 10)
					.background(
						RoundedRectangle(cornerRadius: 10, style: .continuous)
							.fill(Palette.surfaceRaised))
					.overlay(
						RoundedRectangle(cornerRadius: 10, style: .continuous)
							.strokeBorder(Palette.separator, lineWidth: 1))

				Button("Join", action: join)
					.font(.subheadline.weight(.semibold))
					.disabled(typedChannel == nil)
			}

			if !typedName.isEmpty && typedChannel == nil {
				Text("Names must be 1 to \(Channel.maxNameLength) characters.")
					.font(.caption)
					.foregroundStyle(Palette.transmitting)
			}
		}
		.card()
	}

	private var sharingCard: some View {
		HStack(spacing: 12) {
			actionButton("Show code", symbol: "qrcode") { isShowingShare = true }
			actionButton("Scan code", symbol: "qrcode.viewfinder") { isShowingScanner = true }
		}
	}

	private var recentsCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Recent")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(Palette.textPrimary)

			ForEach(store.recents) { channel in
				let isCurrent = channel.serviceUUID == store.current.serviceUUID
				HStack {
					Image(systemName: isCurrent ? "checkmark.circle.fill" : "number")
						.foregroundStyle(isCurrent ? Palette.live : Palette.textSecondary)
					Text(channel.name)
						.foregroundStyle(Palette.textPrimary)
					Spacer()
					if !isCurrent {
						Button {
							store.forget(channel)
						} label: {
							Image(systemName: "xmark.circle.fill")
								.foregroundStyle(Palette.textSecondary)
						}
						.buttonStyle(.plain)
						.accessibilityLabel("Forget \(channel.name)")
					}
				}
				.font(.subheadline)
				.padding(.vertical, 6)
				.contentShape(Rectangle())
				.onTapGesture { select(channel) }
			}
		}
		.card()
	}

	private var shareSheet: some View {
		NavigationStack {
			ZStack {
				Palette.background.ignoresSafeArea()
				QRCodeView(channel: store.current)
			}
			.navigationTitle("Share channel")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { isShowingShare = false }
				}
			}
		}
		.tint(Palette.accent)
	}

	private var scannerSheet: some View {
		NavigationStack {
			QRScannerView { channel in
				isShowingScanner = false
				select(channel)
			}
			.ignoresSafeArea(edges: .bottom)
			.navigationTitle("Scan a code")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Cancel") { isShowingScanner = false }
				}
			}
		}
		.tint(Palette.accent)
	}

	private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 6) {
				Image(systemName: symbol).font(.title2)
				Text(title).font(.footnote.weight(.medium))
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 14)
			.foregroundStyle(Palette.accent)
			.background(
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.fill(Palette.accent.opacity(0.14)))
		}
		.buttonStyle(.plain)
	}

	private func join() {
		guard let channel = typedChannel else { return }
		select(channel)
	}

	private func select(_ channel: Channel) {
		isFieldFocused = false
		typedName = ""
		onSelect(channel)
		dismiss()
	}
}
