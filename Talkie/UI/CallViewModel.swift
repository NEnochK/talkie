import Foundation
import Observation
import TalkieCore
import UIKit

@MainActor
@Observable
final class CallViewModel {
	private(set) var snapshot = CallSnapshot()
	private(set) var isRunning = false
	private(set) var mode: TalkMode = .pushToTalk
	private(set) var isLoopback = false
	private(set) var channel: Channel = .general

	/// Impairments applied to the loopback transport, for tuning the jitter buffer
	/// on a single device. Ignored for real calls.
	var loopbackLossPercent: Double = 0
	var loopbackJitterMilliseconds: Double = 0
	var loopbackBurstFrames: Double = 1

	private var session: CallSession?
	private let impact = UIImpactFeedbackGenerator(style: .medium)

	init() {
		#if DEBUG
		applyDemoStateIfRequested()
		#endif
	}

	#if DEBUG
	/// Starts the loopback rig straight from a launch argument, so the audio path
	/// can be exercised without tapping through the UI:
	///   -autoLoopback [-loss <percent>] [-jitter <milliseconds>]
	func startLoopbackIfRequested() {
		let arguments = ProcessInfo.processInfo.arguments
		guard arguments.contains("-autoLoopback"), !isRunning else { return }

		func value(after flag: String) -> Double? {
			guard let index = arguments.firstIndex(of: flag),
			      arguments.index(after: index) < arguments.endIndex else { return nil }
			return Double(arguments[arguments.index(after: index)])
		}
		loopbackLossPercent = value(after: "-loss") ?? 0
		loopbackJitterMilliseconds = value(after: "-jitter") ?? 0
		loopbackBurstFrames = value(after: "-burst") ?? 1
		startLoopback()
	}

	/// Fills in a plausible in-call state with no hardware attached, so the UI can
	/// be inspected and screenshotted. Enabled with the `-uiDemo` launch argument;
	/// it starts no session and touches no radio.
	private func applyDemoStateIfRequested() {
		let arguments = ProcessInfo.processInfo.arguments

		// The state users actually see first: hunting for a peer, controls inert.
		if arguments.contains("-uiDemoSearching") {
			isRunning = true
			var searching = CallSnapshot()
			searching.connection = .searching
			searching.route = "iPhone Microphone"
			snapshot = searching
			return
		}

		guard arguments.contains("-uiDemo") else { return }
		isRunning = true
		var demo = CallSnapshot()
		demo.connection = .connected
		demo.peerName = "Sam's iPhone"
		demo.peerIsTalking = true
		demo.isTransmitting = true
		demo.route = "Sam's AirPods Pro"
		demo.usingBluetoothMicrophone = true
		demo.stats.roundTripMilliseconds = 68
		demo.stats.lossPercent = 1.4
		demo.stats.concealed = 6
		demo.stats.fecRecovered = 11
		demo.stats.late = 2
		demo.stats.rebuffers = 0
		demo.stats.transmitDrops = 3
		demo.stats.playbackDrops = 0
		demo.stats.jitterBufferDepth = 3
		demo.stats.targetDepth = 4
		snapshot = demo
	}
	#endif

	/// Starts a real Bluetooth call on the current channel.
	func start() {
		begin(transport: nil, loopback: false)
	}

	/// Switches rooms. A live call is torn down and re-established on the new
	/// channel, because the channel *is* the BLE service UUID — there is nothing
	/// to renegotiate on an existing link.
	func setChannel(_ newChannel: Channel) {
		guard newChannel.serviceUUID != channel.serviceUUID else { return }
		let wasRunning = isRunning && !isLoopback
		if isRunning { stop() }
		channel = newChannel
		if wasRunning { start() }
	}

	/// Starts a fake call that echoes your own voice back through the full
	/// encode/transport/jitter-buffer/decode chain, with the configured loss and
	/// jitter applied. Needs only one device.
	func startLoopback() {
		let loopback = LoopbackTransport()
		loopback.lossProbability = loopbackLossPercent / 100
		loopback.jitter = loopbackJitterMilliseconds / 1000
		loopback.burstLength = Int(loopbackBurstFrames)
		begin(transport: loopback, loopback: true)
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false
		isLoopback = false
		session?.stop()
		session = nil
		snapshot = CallSnapshot()
	}

	private func begin(transport: (any Transport)?, loopback: Bool) {
		guard !isRunning else { return }
		isRunning = true
		isLoopback = loopback
		impact.prepare()

		let session = CallSession(channel: channel, transport: transport)
		session.onSnapshot = { [weak self] snapshot in
			// CallSession already delivers this on the main queue.
			MainActor.assumeIsolated { self?.snapshot = snapshot }
		}
		self.session = session
		session.setMode(mode)
		session.start()
	}

	func setMode(_ newMode: TalkMode) {
		mode = newMode
		session?.setMode(newMode)
	}

	func toggleMute() {
		session?.setMuted(!snapshot.isMuted)
	}

	func pushToTalkBegan() {
		impact.impactOccurred()
		session?.beginTransmitting()
	}

	func pushToTalkEnded() {
		impact.impactOccurred(intensity: 0.6)
		session?.endTransmitting()
	}

	var connectionLabel: String {
		switch snapshot.connection {
		case .idle: return isRunning ? "Starting" : "Off"
		case .searching: return "Searching for a peer"
		case .connecting: return "Connecting"
		case .connected:
			if isLoopback { return "Loopback test" }
			return snapshot.peerName.map { "Connected to \($0)" } ?? "Connected"
		}
	}

	var isConnected: Bool { snapshot.connection == .connected }

	/// The whole point is talking through AirPods, so say something when the mic
	/// is actually the phone.
	var showsMicrophoneHint: Bool {
		isRunning && isConnected && !snapshot.usingBluetoothMicrophone
	}
}
