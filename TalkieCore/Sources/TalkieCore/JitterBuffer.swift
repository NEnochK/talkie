import Foundation

public struct JitterBufferStats: Equatable, Sendable {
	public var received: Int = 0
	public var duplicates: Int = 0
	/// Arrived after their playout slot had already passed.
	public var late: Int = 0
	/// Never arrived, hidden by Opus concealment.
	public var concealed: Int = 0
	/// Never arrived, and genuinely rebuilt from an in-band FEC copy carried in the
	/// following packet — verified present, not merely attempted.
	public var fecRecovered: Int = 0
	/// Playout stalled because the buffer ran dry and had to re-prime.
	public var rebuffers: Int = 0

	public var lossPercent: Double {
		let expected = received + concealed + fecRecovered
		guard expected > 0 else { return 0 }
		return Double(concealed + fecRecovered) / Double(expected) * 100
	}
}

/// Reorders incoming Opus frames, hides loss, and hands the decode pump exactly
/// one frame per call.
///
/// Not thread-safe by design. Push and pop must happen on the same serial queue —
/// the app points the Core Bluetooth delegate queue and the decode pump at one
/// queue, which is cheaper and easier to reason about than locking a structure
/// that sits one step from the realtime path.
public final class JitterBuffer {
	/// Frames held before playout starts. 3 frames = 60 ms.
	public static let minDepth = 3
	/// Ceiling on adaptive growth. 8 frames = 160 ms.
	public static let maxDepth = 8
	/// Consecutive concealments before we give up and rebuild depth. 5 = 100 ms.
	public static let maxConsecutiveConcealments = 5

	private let capacity = 32
	private let mask: Int
	private let decoder: FrameDecoding

	private var slotSequence: [UInt16]
	private var slotPayload: [Data?]

	private var playoutSequence: UInt16?
	private var consecutiveConcealments = 0

	/// RFC 3550-style smoothed interarrival jitter, in seconds.
	private var jitterEstimate: Double = 0
	private var lastArrival: Double?
	private var lastArrivalSequence: UInt16?

	public private(set) var stats = JitterBufferStats()

	public init(decoder: FrameDecoding) {
		self.decoder = decoder
		self.mask = capacity - 1
		self.slotSequence = Array(repeating: 0, count: capacity)
		self.slotPayload = Array(repeating: nil, count: capacity)
	}

	/// Frames currently buffered and still ahead of the playout cursor.
	public var depth: Int {
		slotPayload.indices.reduce(into: 0) { total, index in
			guard slotPayload[index] != nil else { return }
			guard let playout = playoutSequence else { total += 1; return }
			if seqDelta(slotSequence[index], playout) >= 0 { total += 1 }
		}
	}

	/// Grows with measured jitter, shrinks back as the link settles.
	public var targetDepth: Int {
		// Rounded to nearest, not up: any nonzero jitter at all would otherwise
		// push the target off its floor, and real links are never perfectly spaced.
		let extra = Int((jitterEstimate / AudioConfig.frameDuration).rounded())
		return min(max(Self.minDepth + extra, Self.minDepth), Self.maxDepth)
	}

	public func push(sequence: UInt16, payload: Data, isTalkspurtStart: Bool = false, arrivalTime: Double) {
		stats.received += 1
		updateJitter(sequence: sequence, arrivalTime: arrivalTime)

		// A new talkspurt follows a deliberate gap (PTT release, DTX silence).
		// Restart playout there instead of concealing across the pause.
		if isTalkspurtStart {
			flush()
			playoutSequence = sequence
		}

		if let playout = playoutSequence {
			let delta = seqDelta(sequence, playout)
			if delta < 0 {
				stats.late += 1
				return
			}
			// So far ahead that the ring cannot hold it: the stream jumped. Restart.
			if delta >= capacity {
				flush()
				playoutSequence = sequence
			}
		}

		let index = Int(sequence) & mask
		if slotPayload[index] != nil && slotSequence[index] == sequence {
			stats.duplicates += 1
			return
		}
		slotSequence[index] = sequence
		slotPayload[index] = payload

		if playoutSequence == nil && depth >= targetDepth {
			playoutSequence = oldestBufferedSequence()
		}
	}

	/// One frame of PCM, or `nil` while priming — the caller renders nothing and the
	/// ring buffer's own underrun handling produces silence.
	public func pop() -> [Int16]? {
		guard let playout = playoutSequence else { return nil }

		let index = Int(playout) & mask
		if let payload = slotPayload[index], slotSequence[index] == playout {
			slotPayload[index] = nil
			playoutSequence = playout &+ 1
			consecutiveConcealments = 0
			return (try? decoder.decode(payload)) ?? silence()
		}

		// The frame is missing. Try to rebuild it from the next packet's FEC copy,
		// but only when that packet genuinely carries one — otherwise Opus would
		// hand back concealment dressed up as a recovery.
		let nextIndex = Int(playout &+ 1) & mask
		if let nextPayload = slotPayload[nextIndex], slotSequence[nextIndex] == playout &+ 1,
		   decoder.packetCarriesFEC(nextPayload),
		   let recovered = try? decoder.decodeFEC(from: nextPayload) {
			stats.fecRecovered += 1
			playoutSequence = playout &+ 1
			consecutiveConcealments = 0
			return recovered
		}

		stats.concealed += 1
		consecutiveConcealments += 1
		playoutSequence = playout &+ 1

		// Concealing indefinitely just emits artefacts. Drop back to priming so the
		// buffer rebuilds depth before speaking again.
		if consecutiveConcealments >= Self.maxConsecutiveConcealments && depth == 0 {
			stats.rebuffers += 1
			flush()
		}
		return (try? decoder.conceal()) ?? silence()
	}

	public func reset() {
		flush()
		stats = JitterBufferStats()
		jitterEstimate = 0
		lastArrival = nil
		lastArrivalSequence = nil
	}

	private func flush() {
		for index in slotPayload.indices { slotPayload[index] = nil }
		playoutSequence = nil
		consecutiveConcealments = 0
	}

	private func oldestBufferedSequence() -> UInt16? {
		var oldest: UInt16?
		for index in slotPayload.indices where slotPayload[index] != nil {
			let candidate = slotSequence[index]
			if oldest == nil || seqDelta(candidate, oldest!) < 0 { oldest = candidate }
		}
		return oldest
	}

	/// Smoothed deviation between when a frame should have arrived and when it did.
	private func updateJitter(sequence: UInt16, arrivalTime: Double) {
		defer {
			lastArrival = arrivalTime
			lastArrivalSequence = sequence
		}
		guard let previousArrival = lastArrival, let previousSequence = lastArrivalSequence else { return }

		let gap = seqDelta(sequence, previousSequence)
		guard gap > 0 else { return }

		let expected = Double(gap) * AudioConfig.frameDuration
		let deviation = abs((arrivalTime - previousArrival) - expected)
		jitterEstimate += (deviation - jitterEstimate) / 16
	}

	private func silence() -> [Int16] {
		Array(repeating: 0, count: AudioConfig.samplesPerFrame)
	}
}
