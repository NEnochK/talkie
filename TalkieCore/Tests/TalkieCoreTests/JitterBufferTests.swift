import Foundation
import Testing

@testable import TalkieCore

/// Records which recovery path the buffer chose, and returns PCM tagged with the
/// frame it came from so ordering is checkable.
private final class StubDecoder: FrameDecoding {
	enum Call: Equatable {
		case decode(UInt8)
		case conceal
		case fec(UInt8)
	}

	static let concealMarker: Int16 = -1
	private(set) var calls: [Call] = []
	/// Whether stub packets claim to carry an FEC copy. Real Opus packets only
	/// sometimes do, and the buffer must check before claiming a repair.
	var packetsCarryFEC = true

	func packetCarriesFEC(_ payload: Data) -> Bool { packetsCarryFEC }

	func decode(_ payload: Data) throws -> [Int16] {
		let tag = payload.first ?? 0
		calls.append(.decode(tag))
		return frame(Int16(tag))
	}

	func conceal() throws -> [Int16] {
		calls.append(.conceal)
		return frame(Self.concealMarker)
	}

	func decodeFEC(from nextPayload: Data) throws -> [Int16] {
		let tag = nextPayload.first ?? 0
		calls.append(.fec(tag))
		// FEC rebuilds the frame *before* the one it was carried in.
		return frame(Int16(tag) - 1)
	}

	private func frame(_ value: Int16) -> [Int16] {
		Array(repeating: value, count: AudioConfig.samplesPerFrame)
	}
}

private func payload(_ sequence: UInt8) -> Data { Data([sequence]) }

/// The tag every sample in a popped frame carries, or nil if the buffer was priming.
private func tag(_ frame: [Int16]?) -> Int16? {
	guard let frame else { return nil }
	#expect(frame.count == AudioConfig.samplesPerFrame)
	return frame.first
}

@Suite("Jitter buffer")
struct JitterBufferTests {
	private func primed(_ decoder: StubDecoder) -> JitterBuffer {
		let buffer = JitterBuffer(decoder: decoder)
		for sequence in 0..<UInt8(JitterBuffer.minDepth) {
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(sequence),
			            arrivalTime: Double(sequence) * AudioConfig.frameDuration)
		}
		return buffer
	}

	@Test("Holds playout until the target depth is reached")
	func primesBeforePlaying() {
		let decoder = StubDecoder()
		let buffer = JitterBuffer(decoder: decoder)

		buffer.push(sequence: 0, payload: payload(0), arrivalTime: 0)
		#expect(buffer.pop() == nil, "must not start playing on a single frame")
		buffer.push(sequence: 1, payload: payload(1), arrivalTime: 0.02)
		#expect(buffer.pop() == nil)

		buffer.push(sequence: 2, payload: payload(2), arrivalTime: 0.04)
		#expect(tag(buffer.pop()) == 0, "should start once three frames are held")
	}

	@Test("Plays in-order frames in order")
	func inOrder() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
		#expect(tag(buffer.pop()) == 2)
		#expect(decoder.calls == [.decode(0), .decode(1), .decode(2)])
	}

	@Test("Reorders frames that arrive out of order")
	func reordersArrivals() {
		let decoder = StubDecoder()
		let buffer = JitterBuffer(decoder: decoder)

		for (sequence, time) in [(0, 0.0), (2, 0.02), (1, 0.04)] {
			buffer.push(sequence: UInt16(sequence), payload: payload(UInt8(sequence)), arrivalTime: time)
		}

		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
		#expect(tag(buffer.pop()) == 2)
		#expect(buffer.stats.concealed == 0)
	}

	@Test("Rebuilds a lost frame from the next packet's FEC")
	func recoversWithFEC() {
		let decoder = StubDecoder()
		let buffer = JitterBuffer(decoder: decoder)

		// Frame 2 never arrives, but frame 3 does and carries its FEC copy.
		for sequence in [0, 1, 3] {
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(UInt8(sequence)),
			            arrivalTime: Double(sequence) * AudioConfig.frameDuration)
		}

		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
		#expect(tag(buffer.pop()) == 2, "FEC should reconstruct frame 2 from frame 3")
		#expect(tag(buffer.pop()) == 3, "frame 3 still plays normally afterwards")

		#expect(decoder.calls == [.decode(0), .decode(1), .fec(3), .decode(3)])
		#expect(buffer.stats.fecRecovered == 1)
		#expect(buffer.stats.concealed == 0)
	}

	@Test("Conceals rather than claiming a repair when the next packet has no FEC copy")
	func concealsWhenSuccessorHasNoFEC() {
		let decoder = StubDecoder()
		decoder.packetsCarryFEC = false
		let buffer = JitterBuffer(decoder: decoder)

		// Frame 2 is missing and frame 3 carries no FEC copy of it.
		for sequence in [0, 1, 3] {
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(UInt8(sequence)),
			            arrivalTime: Double(sequence) * AudioConfig.frameDuration)
		}

		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
		#expect(tag(buffer.pop()) == StubDecoder.concealMarker)

		#expect(buffer.stats.fecRecovered == 0, "must not report a repair that did not happen")
		#expect(buffer.stats.concealed == 1)
	}

	@Test("Conceals a gap when no FEC carrier is available")
	func concealsWhenNothingFollows() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
		#expect(tag(buffer.pop()) == 2)

		// Nothing left, and no successor to recover from.
		#expect(tag(buffer.pop()) == StubDecoder.concealMarker)
		#expect(buffer.stats.concealed == 1)
		#expect(decoder.calls.last == .conceal)
	}

	@Test("Discards a frame that arrives after its slot has passed")
	func discardsLateFrames() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)
		#expect(tag(buffer.pop()) == 0)

		buffer.push(sequence: 0, payload: payload(0), arrivalTime: 1.0)

		#expect(buffer.stats.late == 1)
		#expect(tag(buffer.pop()) == 1, "a late frame must not displace the real next frame")
	}

	@Test("Counts a repeated frame as a duplicate")
	func countsDuplicates() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		buffer.push(sequence: 1, payload: payload(1), arrivalTime: 0.05)

		#expect(buffer.stats.duplicates == 1)
		#expect(tag(buffer.pop()) == 0)
		#expect(tag(buffer.pop()) == 1)
	}

	@Test("Restarts playout at a talkspurt boundary instead of concealing the pause")
	func talkspurtRestartsPlayout() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)
		#expect(tag(buffer.pop()) == 0)

		// PTT released, then pressed again much later. The sequence jumps.
		buffer.push(sequence: 900, payload: payload(90), isTalkspurtStart: true, arrivalTime: 30.0)
		buffer.push(sequence: 901, payload: payload(91), arrivalTime: 30.02)
		buffer.push(sequence: 902, payload: payload(92), arrivalTime: 30.04)

		#expect(tag(buffer.pop()) == 90, "playout should jump to the new talkspurt")
		#expect(buffer.stats.concealed == 0, "must not conceal across a deliberate pause")
	}

	@Test("Re-primes after a sustained outage rather than concealing forever")
	func rebuffersAfterSustainedLoss() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)
		for _ in 0..<JitterBuffer.minDepth { _ = buffer.pop() }

		for _ in 0..<JitterBuffer.maxConsecutiveConcealments { _ = buffer.pop() }

		#expect(buffer.stats.rebuffers == 1)
		#expect(buffer.pop() == nil, "should be back to priming")
	}

	@Test("Holds the minimum depth on a perfectly paced link")
	func steadyLinkKeepsMinimumDepth() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		for sequence in 3..<60 {
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(UInt8(sequence % 256)),
			            arrivalTime: Double(sequence) * AudioConfig.frameDuration)
			_ = buffer.pop()
		}

		#expect(buffer.targetDepth == JitterBuffer.minDepth)
	}

	@Test("Grows the target depth when arrivals get jittery")
	func jitteryLinkGrowsDepth() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		// Alternating +40 ms arrival offsets, i.e. a steady 40 ms of jitter.
		for sequence in 3..<70 {
			let nominal = Double(sequence) * AudioConfig.frameDuration
			let arrival = nominal + (sequence.isMultiple(of: 2) ? 0.04 : 0)
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(UInt8(sequence % 256)),
			            arrivalTime: arrival)
			_ = buffer.pop()
		}

		#expect(buffer.targetDepth > JitterBuffer.minDepth)
		#expect(buffer.targetDepth <= JitterBuffer.maxDepth)
	}

	@Test("Never lets the target depth exceed the ceiling")
	func depthIsCapped() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)

		// Wild arrival times, far beyond anything the cap should allow.
		for sequence in 3..<200 {
			buffer.push(sequence: UInt16(sequence),
			            payload: payload(UInt8(sequence % 256)),
			            arrivalTime: Double(sequence) * 5.0)
			_ = buffer.pop()
		}

		#expect(buffer.targetDepth == JitterBuffer.maxDepth)
	}

	@Test("reset() clears both buffered frames and statistics")
	func resetClearsEverything() {
		let decoder = StubDecoder()
		let buffer = primed(decoder)
		_ = buffer.pop()

		buffer.reset()

		#expect(buffer.stats == JitterBufferStats())
		#expect(buffer.pop() == nil)
		#expect(buffer.targetDepth == JitterBuffer.minDepth)
	}

	@Test("Reports loss as a percentage of expected frames")
	func lossPercentage() {
		var stats = JitterBufferStats()
		#expect(stats.lossPercent == 0)

		stats.received = 90
		stats.concealed = 8
		stats.fecRecovered = 2
		#expect(stats.lossPercent == 10)
	}
}
