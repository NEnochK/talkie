import Foundation
import TalkieCore

/// Deterministic, offline replica of `LoopbackTransport` plus the decode pump.
///
/// Drives the real `OpusEncoder`, `JitterBuffer` and `OpusDecoder`; only the
/// transport and the clock are simulated. That makes a run repeatable for a given
/// seed, which is what lets the audio path be asserted on in tests rather than
/// only listened to.
///
/// Not part of the shipping library — the app target does not depend on this.
public enum LoopbackSimulation {
	public struct Settings: Sendable {
		/// Overall share of frames to discard, 0...100.
		public var lossPercent: Double
		/// Consecutive frames discarded per loss event. Opus in-band FEC carries a
		/// copy of frame N inside frame N+1, so it repairs isolated drops but not
		/// runs of them.
		public var burstLength: Int
		/// Extra uniformly-random delay on top of `baseDelay`, in seconds. This is
		/// what reorders frames.
		public var jitter: Double
		/// Baseline one-way delay, matching `LoopbackTransport.baseDelay`.
		public var baseDelay: Double
		public var seed: UInt64
		/// What the encoder is told to expect, via OPUS_SET_PACKET_LOSS_PERC. This
		/// governs how often Opus spends bits on an LBRR (FEC) copy.
		public var expectedPacketLossPercent: Int

		public init(
			lossPercent: Double = 0,
			burstLength: Int = 1,
			jitter: Double = 0,
			baseDelay: Double = 0.020,
			seed: UInt64 = 1,
			expectedPacketLossPercent: Int = AudioConfig.expectedPacketLossPercent
		) {
			self.lossPercent = lossPercent
			self.burstLength = max(1, burstLength)
			self.jitter = jitter
			self.baseDelay = baseDelay
			self.seed = seed
			self.expectedPacketLossPercent = expectedPacketLossPercent
		}
	}

	public struct Result: Sendable {
		public var output: [Int16]
		public var frameCount: Int
		public var droppedInTransit: Int
		public var encodedBytes: Int
		public var dtxFrames: Int
		public var stats: JitterBufferStats

		public var bitrateKbps: Double {
			let seconds = Double(frameCount) * AudioConfig.frameDuration
			guard seconds > 0 else { return 0 }
			return Double(encodedBytes * 8) / seconds / 1000
		}

		/// Share of dropped frames the receiver rebuilt from the next packet's FEC,
		/// rather than having to conceal outright.
		public var fecRecoveryRatio: Double {
			let hidden = stats.fecRecovered + stats.concealed
			guard hidden > 0 else { return 0 }
			return Double(stats.fecRecovered) / Double(hidden)
		}
	}

	public static func run(input: [Int16], settings: Settings) throws -> Result {
		let frameSize = AudioConfig.samplesPerFrame
		let frameCount = input.count / frameSize
		var generator = SeededGenerator(seed: settings.seed)

		let encoder = try OpusEncoder(packetLossPercent: settings.expectedPacketLossPercent)
		let jitterBuffer = JitterBuffer(decoder: try OpusDecoder())

		struct Arrival {
			let time: Double
			let sequence: UInt16
			let payload: Data
		}

		var arrivals: [Arrival] = []
		var droppedInTransit = 0
		var encodedBytes = 0
		var dtxFrames = 0
		var burstRemaining = 0

		for index in 0..<frameCount {
			let start = index * frameSize
			let payload = try encoder.encode(Array(input[start..<(start + frameSize)]))
			encodedBytes += payload.count
			if OpusEncoder.isSilenceFrame(payload) { dtxFrames += 1 }

			// Scale the trigger by burst length so the overall loss rate still
			// matches what was asked for.
			if burstRemaining == 0,
			   Double.random(in: 0..<1, using: &generator)
				< settings.lossPercent / 100 / Double(settings.burstLength) {
				burstRemaining = settings.burstLength
			}
			if burstRemaining > 0 {
				burstRemaining -= 1
				droppedInTransit += 1
				continue
			}

			let extra = settings.jitter > 0
				? Double.random(in: 0...settings.jitter, using: &generator)
				: 0
			arrivals.append(Arrival(
				time: Double(index) * AudioConfig.frameDuration + settings.baseDelay + extra,
				sequence: UInt16(truncatingIfNeeded: index),
				payload: payload))
		}

		arrivals.sort { $0.time < $1.time }

		// Play out on a virtual 20 ms clock, exactly like the decode pump.
		var output: [Int16] = []
		output.reserveCapacity(frameCount * frameSize)
		var nextArrival = 0
		var now = 0.0
		let ticks = frameCount + JitterBuffer.maxDepth + 10

		for _ in 0..<ticks {
			now += AudioConfig.frameDuration
			while nextArrival < arrivals.count, arrivals[nextArrival].time <= now {
				let arrival = arrivals[nextArrival]
				jitterBuffer.push(
					sequence: arrival.sequence,
					payload: arrival.payload,
					arrivalTime: arrival.time)
				nextArrival += 1
			}
			if let pcm = jitterBuffer.pop() {
				output.append(contentsOf: pcm)
			} else {
				output.append(contentsOf: [Int16](repeating: 0, count: frameSize))
			}
		}

		return Result(
			output: output,
			frameCount: frameCount,
			droppedInTransit: droppedInTransit,
			encodedBytes: encodedBytes,
			dtxFrames: dtxFrames,
			stats: jitterBuffer.stats)
	}
}

/// Seeded xorshift. `Double.random` without a generator would make runs
/// unrepeatable, which would make every assertion here flaky.
public struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	public init(seed: UInt64) {
		state = seed &* 6_364_136_223_846_793_005 &+ 1
	}

	public mutating func next() -> UInt64 {
		state ^= state << 13
		state ^= state >> 7
		state ^= state << 17
		return state
	}
}
