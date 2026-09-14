import Foundation
import QuartzCore
import TalkieCore

/// Pretends to be a peer by echoing everything back after a configurable delay,
/// with optional loss, jitter and reordering.
///
/// This is how the audio chain gets exercised on one device: mic -> encode ->
/// lossy "network" -> jitter buffer -> decode -> AirPods. Tuning concealment and
/// buffer depth against a reproducible impairment here is far easier than chasing
/// them over a live radio.
final class LoopbackTransport: Transport {
	weak var delegate: TransportDelegate?

	private(set) var state: TransportState = .idle {
		didSet {
			guard state != oldValue else { return }
			delegate?.transportDidChangeState(self)
		}
	}

	let queue: DispatchQueue
	private(set) var droppedAudioFrames = 0

	/// Fraction of audio frames to discard outright, 0...1.
	var lossProbability: Double = 0
	/// Consecutive frames discarded per loss event.
	///
	/// This matters more than the loss rate. Opus in-band FEC carries a copy of
	/// frame N inside frame N+1, so an isolated drop is repaired almost perfectly —
	/// measured offline, 10% uniform loss recovers 44 of 51 drops and is
	/// indistinguishable from a clean call. A *run* of drops defeats FEC, and a run
	/// is what radio contention actually produces.
	var burstLength: Int = 1
	/// Baseline one-way delay applied to every frame.
	var baseDelay: Double = 0.02
	/// Extra uniformly-random delay on top of `baseDelay`, which is what makes
	/// frames arrive out of order.
	var jitter: Double = 0

	private let peerName: String
	private var burstRemaining = 0

	init(queue: DispatchQueue = BLEConstants.queue, peerName: String = "Loopback") {
		self.queue = queue
		self.peerName = peerName
	}

	func start() {
		state = .connected
		queue.async { [weak self] in
			guard let self else { return }
			delegate?.transport(self, didReceiveControl: .hello(identity: UUID(), name: peerName))
		}
	}

	func stop() {
		state = .idle
	}

	@discardableResult
	func sendAudio(_ packet: Packet) -> Bool {
		guard state == .connected else { return false }

		// Scale the trigger by burst length so the overall loss rate still matches
		// what the slider says.
		if burstRemaining == 0,
		   Double.random(in: 0..<1) < lossProbability / Double(max(burstLength, 1)) {
			burstRemaining = max(burstLength, 1)
		}
		if burstRemaining > 0 {
			burstRemaining -= 1
			droppedAudioFrames += 1
			return false
		}

		let delay = baseDelay + (jitter > 0 ? Double.random(in: 0...jitter) : 0)
		queue.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self, state == .connected else { return }
			delegate?.transport(self, didReceiveAudio: packet, arrivalTime: CACurrentMediaTime())
		}
		return true
	}

	func sendControl(_ message: ControlMessage) {
		guard state == .connected else { return }
		queue.asyncAfter(deadline: .now() + baseDelay) { [weak self] in
			guard let self else { return }
			delegate?.transport(self, didReceiveControl: message)
		}
	}
}
