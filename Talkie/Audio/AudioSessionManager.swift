import AVFoundation
import Foundation
import TalkieCore

/// Owns the `AVAudioSession` configuration for a call.
///
/// The important choice here is `.voiceChat` plus `.allowBluetoothHFP`. Using the
/// AirPods microphone forces the Bluetooth link from A2DP to HFP, which caps the
/// whole route at 16 kHz mono — that is why `AudioConfig` is pinned to 16 kHz and
/// there is nothing to gain from encoding wider.
///
/// iOS 26 added `.bluetoothHighQualityRecording`, which avoids that downgrade, and
/// it is deliberately not used: the SDK documents it as compatible only with
/// `AVAudioSessionMode.default` and explicitly "not recommended for real-time
/// communication usage" because it adds input latency. We need `.voiceChat` for
/// echo cancellation and automatic gain control, which matters far more here than
/// bandwidth.
final class AudioSessionManager {
	enum Interruption {
		case began
		case ended(shouldResume: Bool)
	}

	var onInterruption: ((Interruption) -> Void)?
	var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?

	private let session = AVAudioSession.sharedInstance()
	private var observing = false

	func configure() throws {
		try session.setCategory(
			.playAndRecord,
			mode: .voiceChat,
			options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
		try session.setPreferredSampleRate(Double(AudioConfig.sampleRate))
		try session.setPreferredIOBufferDuration(AudioConfig.frameDuration)
		startObserving()
	}

	func activate() throws {
		try session.setActive(true, options: [])
	}

	func deactivate() {
		try? session.setActive(false, options: [.notifyOthersOnDeactivation])
	}

	/// Human-readable description of where audio is actually going, for the UI.
	var currentRouteDescription: String {
		let outputs = session.currentRoute.outputs.map(\.portName)
		return outputs.isEmpty ? "No output" : outputs.joined(separator: ", ")
	}

	/// True when the microphone is coming from a Bluetooth headset rather than the
	/// phone itself, which is the AirPods case this app is built around.
	var isUsingBluetoothMicrophone: Bool {
		session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
	}

	private func startObserving() {
		guard !observing else { return }
		observing = true

		NotificationCenter.default.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: session,
			queue: .main
		) { [weak self] notification in
			guard let info = notification.userInfo,
			      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
			      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

			switch type {
			case .began:
				self?.onInterruption?(.began)
			case .ended:
				let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
				let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
				self?.onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
			@unknown default:
				break
			}
		}

		NotificationCenter.default.addObserver(
			forName: AVAudioSession.routeChangeNotification,
			object: session,
			queue: .main
		) { [weak self] notification in
			guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
			      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
			self?.onRouteChange?(reason)
		}
	}
}
