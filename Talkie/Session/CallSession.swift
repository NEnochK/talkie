import Foundation
import QuartzCore
import TalkieCore
import UIKit

enum TalkMode: String, CaseIterable, Identifiable {
	case pushToTalk = "Push to talk"
	case openMic = "Open mic"

	var id: String { rawValue }
}

/// Snapshot of everything the UI renders, delivered on the main queue.
struct CallSnapshot: Equatable {
	var connection: TransportState = .idle
	var peerName: String?
	var peerIsTalking = false
	var peerIsMuted = false
	var isTransmitting = false
	var isMuted = false
	var route = ""
	var usingBluetoothMicrophone = false
	var stats = LinkStats()
	var errorMessage: String?
}

/// Owns the whole call: transport, codec, jitter buffer and audio graph.
///
/// Queue discipline, which most of the correctness rests on:
/// - transport callbacks and the decode pump run on `BLEConstants.queue`
/// - microphone frames arrive on the audio capture thread and hop to that queue
/// - UI snapshots are published on the main queue
///
/// Nothing else touches the codec, the jitter buffer or the sequence counter, so
/// none of them need locking.
final class CallSession: @unchecked Sendable {
	/// Delivered on the main queue whenever anything the UI shows changes.
	var onSnapshot: ((CallSnapshot) -> Void)?

	private let queue = BLEConstants.queue
	private let audio = AudioEngineController()
	private let session = AudioSessionManager()
	private let transport: any Transport

	private var encoder: OpusEncoder?
	private var jitterBuffer: JitterBuffer?

	private var decodePump: DispatchSourceTimer?
	private var keepalive: DispatchSourceTimer?

	private var nextSequence: UInt16 = 0
	private var startingNewTalkspurt = true

	private var pendingPings: [UInt32: Double] = [:]
	private var nextPingID: UInt32 = 0

	private var peerTalkingExpiry: Double = 0
	private var playbackDropCount = 0

	private var snapshot = CallSnapshot()

	/// Audio is only sent while this is true: PTT held, or open mic and unmuted.
	private var isTransmitting = false
	private var mode: TalkMode = .pushToTalk
	private var isMuted = false

	/// Stop enqueueing once this much is already waiting, so a decode pump running
	/// marginally fast inflates latency instead of being absorbed. Three frames.
	private var maximumPlaybackBacklog: Int { AudioConfig.samplesPerFrame * 3 }

	init(channel: Channel = .general, transport: (any Transport)? = nil) {
		self.transport = transport
			?? BLETransport(localName: UIDevice.current.name, channel: channel)
		self.transport.delegate = self

		audio.onCapturedFrame = { [weak self] frame in
			// Hop off the capture thread: the encoder and sequence counter belong
			// to the transport queue.
			self?.queue.async { self?.encodeAndSend(frame) }
		}

		// These arrive on the main queue; hop so the audio graph keeps one owner.
		session.onRouteChange = { [weak self] _ in
			guard let self else { return }
			queue.async { [weak self] in self?.handleRouteChange() }
		}
		session.onInterruption = { [weak self] interruption in
			guard let self else { return }
			queue.async { [weak self] in self?.handleInterruption(interruption) }
		}
	}

	// MARK: - Lifecycle

	/// Safe to call from any thread; the work is serialised onto `queue` so the
	/// codec, jitter buffer and audio graph only ever have one owner.
	func start() {
		queue.async { [weak self] in self?.startInternal() }
	}

	func stop() {
		queue.async { [weak self] in self?.stopInternal() }
	}

	private func startInternal() {
		do {
			try session.configure()
			try session.activate()
			encoder = try OpusEncoder()
			jitterBuffer = JitterBuffer(decoder: try OpusDecoder())
			try audio.start()
		} catch {
			update { $0.errorMessage = "Audio setup failed: \(error.localizedDescription)" }
			return
		}

		transport.start()
		startDecodePump()
		startKeepalive()
		refreshRoute()
		applyTransmissionState()
	}

	private func stopInternal() {
		decodePump?.cancel()
		decodePump = nil
		keepalive?.cancel()
		keepalive = nil

		transport.sendControl(.bye)
		transport.stop()
		audio.stop()
		session.deactivate()

		encoder = nil
		jitterBuffer = nil
		isTransmitting = false
		playbackDropCount = 0
		pendingPings.removeAll()
		update { $0 = CallSnapshot() }
	}

	// MARK: - User actions

	func setMode(_ newMode: TalkMode) {
		queue.async { [weak self] in
			guard let self else { return }
			mode = newMode
			// Leaving PTT should not strand the link mid-talkspurt.
			if newMode == .pushToTalk { isTransmitting = false }
			applyTransmissionState()
		}
	}

	func setMuted(_ muted: Bool) {
		queue.async { [weak self] in
			guard let self else { return }
			isMuted = muted
			transport.sendControl(.mute(muted))
			applyTransmissionState()
		}
	}

	/// PTT button pressed.
	func beginTransmitting() {
		queue.async { [weak self] in
			guard let self, mode == .pushToTalk else { return }
			isTransmitting = true
			applyTransmissionState()
		}
	}

	/// PTT button released.
	func endTransmitting() {
		queue.async { [weak self] in
			guard let self, mode == .pushToTalk else { return }
			isTransmitting = false
			applyTransmissionState()
		}
	}

	// MARK: - Transmission

	/// True when microphone audio should actually go out right now.
	private var shouldTransmit: Bool {
		guard transport.state == .connected else { return false }
		switch mode {
		case .pushToTalk: return isTransmitting
		case .openMic: return !isMuted
		}
	}

	private func applyTransmissionState() {
		let active = shouldTransmit
		if active {
			// Mark the next frame so the peer restarts playout instead of trying to
			// conceal the silence that preceded it.
			startingNewTalkspurt = true
			transport.sendControl(.talkStart)
		} else {
			transport.sendControl(.talkEnd)
		}
		update { $0.isTransmitting = active; $0.isMuted = self.isMuted }
	}

	private func encodeAndSend(_ frame: [Int16]) {
		guard shouldTransmit, let encoder else { return }
		guard let payload = try? encoder.encode(frame) else { return }

		let packet = Packet(
			type: .audio,
			sequence: nextSequence,
			flags: startingNewTalkspurt ? .talkspurtStart : [],
			payload: payload)
		nextSequence &+= 1
		startingNewTalkspurt = false

		transport.sendAudio(packet)
	}

	// MARK: - Playback

	private func startDecodePump() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(
			deadline: .now() + AudioConfig.frameDuration,
			repeating: AudioConfig.frameDuration,
			leeway: .milliseconds(2))
		timer.setEventHandler { [weak self] in self?.pumpOneFrame() }
		timer.resume()
		decodePump = timer
	}

	private func pumpOneFrame() {
		guard let jitterBuffer else { return }

		// The pump is a dispatch timer while the speaker runs off the audio clock,
		// so the two drift apart. Refusing to pile up more than a few frames stops
		// that drift turning into creeping latency.
		if audio.playbackBufferedSamples >= maximumPlaybackBacklog {
			playbackDropCount += 1
		} else if let pcm = jitterBuffer.pop() {
			audio.enqueueForPlayback(pcm)
		}

		if CACurrentMediaTime() > peerTalkingExpiry, snapshot.peerIsTalking {
			update { $0.peerIsTalking = false }
		}
		publishStats()
	}

	private func publishStats() {
		guard let jitterBuffer else { return }
		var stats = snapshot.stats
		stats.apply(jitterBuffer.stats)
		stats.transmitDrops = transport.droppedAudioFrames
		stats.playbackDrops = playbackDropCount
		stats.jitterBufferDepth = jitterBuffer.depth
		stats.targetDepth = jitterBuffer.targetDepth
		guard stats != snapshot.stats else { return }
		update { $0.stats = stats }
	}

	// MARK: - Keepalive and round trip

	private func startKeepalive() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
		timer.setEventHandler { [weak self] in
			guard let self, transport.state == .connected else { return }
			nextPingID &+= 1
			pendingPings[nextPingID] = CACurrentMediaTime()
			// Keep the table from growing if replies stop arriving.
			if pendingPings.count > 8 {
				let cutoff = CACurrentMediaTime() - 10
				pendingPings = pendingPings.filter { $0.value > cutoff }
			}
			transport.sendControl(.ping(id: nextPingID))
		}
		timer.resume()
		keepalive = timer
	}

	// MARK: - Audio route

	private func handleRouteChange() {
		refreshRoute()
		guard audio.isRunning else { return }
		// The input format changes when AirPods come or go, and the converter built
		// for the old format is no longer valid.
		do {
			try audio.restart()
		} catch {
			update { $0.errorMessage = "Audio route change failed: \(error.localizedDescription)" }
		}
	}

	private func handleInterruption(_ interruption: AudioSessionManager.Interruption) {
		switch interruption {
		case .began:
			audio.stop()
			update { $0.isTransmitting = false }
		case .ended(let shouldResume):
			guard shouldResume else { return }
			do {
				try session.activate()
				try audio.start()
			} catch {
				update { $0.errorMessage = "Could not resume audio: \(error.localizedDescription)" }
			}
		}
	}

	private func refreshRoute() {
		let description = session.currentRouteDescription
		let bluetooth = session.isUsingBluetoothMicrophone
		update {
			$0.route = description
			$0.usingBluetoothMicrophone = bluetooth
		}
	}

	// MARK: - Snapshot plumbing

	/// Must be called on `queue`, which every path into it already guarantees.
	private func update(_ mutate: (inout CallSnapshot) -> Void) {
		dispatchPrecondition(condition: .onQueue(queue))
		var updated = snapshot
		mutate(&updated)
		guard updated != snapshot else { return }
		snapshot = updated
		DispatchQueue.main.async { [onSnapshot] in onSnapshot?(updated) }
	}
}

// MARK: - TransportDelegate

extension CallSession: TransportDelegate {
	func transportDidChangeState(_ transport: any Transport) {
		let state = transport.state
		let peer = (transport as? BLETransport)?.peerName

		if state != .connected {
			jitterBuffer?.reset()
			audio.flushPlayback()
			isTransmitting = false
		}
		update {
			$0.connection = state
			$0.peerName = peer
			if state != .connected {
				$0.peerIsTalking = false
				$0.peerIsMuted = false
				$0.isTransmitting = false
			}
		}
	}

	func transport(_ transport: any Transport, didReceiveAudio packet: Packet, arrivalTime: Double) {
		jitterBuffer?.push(
			sequence: packet.sequence,
			payload: packet.payload,
			isTalkspurtStart: packet.flags.contains(.talkspurtStart),
			arrivalTime: arrivalTime)

		peerTalkingExpiry = CACurrentMediaTime() + 0.4
		if !snapshot.peerIsTalking {
			update { $0.peerIsTalking = true }
		}
	}

	func transport(_ transport: any Transport, didReceiveControl message: ControlMessage) {
		switch message {
		case .hello(_, let name):
			update { $0.peerName = name }
		case .talkStart:
			peerTalkingExpiry = CACurrentMediaTime() + 0.4
			update { $0.peerIsTalking = true }
		case .talkEnd:
			update { $0.peerIsTalking = false }
		case .mute(let muted):
			update { $0.peerIsMuted = muted }
		case .ping(let id):
			transport.sendControl(.pong(id: id))
		case .pong(let id):
			guard let sentAt = pendingPings.removeValue(forKey: id) else { return }
			let rtt = (CACurrentMediaTime() - sentAt) * 1000
			update { $0.stats.roundTripMilliseconds = rtt }
		case .bye:
			jitterBuffer?.reset()
			audio.flushPlayback()
			update { $0.peerIsTalking = false }
		}
	}
}
