import Foundation
import Testing

@testable import TalkieCore
@testable import TalkieSimulation

/// End-to-end tests over the real audio path: `OpusEncoder` -> a lossy, jittery,
/// reordering channel -> `JitterBuffer` -> `OpusDecoder`.
///
/// Only the transport and the clock are simulated, so these cover the interaction
/// the unit tests cannot: whether concealment, in-band FEC and the adaptive buffer
/// actually combine to keep audio flowing. They run headless in well under a
/// second and need no device.
///
/// A note on the clean baseline: the harness runs a few ticks past the last frame
/// to drain anything still in flight, and those trailing ticks conceal against an
/// empty buffer. So a handful of concealments at 0% loss is the harness, not the
/// pipeline.
@Suite("End-to-end audio")
struct EndToEndAudioTests {
	static let duration = 10.0
	static let tailSlack = 10

	private func speech() -> [Int16] {
		SyntheticSpeech.make(seconds: Self.duration)
	}

	private func run(
		_ settings: LoopbackSimulation.Settings,
		on input: [Int16]? = nil
	) throws -> LoopbackSimulation.Result {
		try LoopbackSimulation.run(input: input ?? speech(), settings: settings)
	}

	// MARK: - Clean path

	@Test("A clean link delivers every frame and hides nothing")
	func cleanRun() throws {
		let input = speech()
		let result = try run(.init(), on: input)

		#expect(result.droppedInTransit == 0)
		#expect(result.stats.received == result.frameCount)
		#expect(result.stats.late == 0)
		#expect(result.stats.fecRecovered == 0)
		#expect(result.stats.concealed < Self.tailSlack,
		        "clean link concealed \(result.stats.concealed) frames")
	}

	@Test("Playout never stalls: one frame out per tick, always")
	func outputIsContinuous() throws {
		let input = speech()
		let result = try run(.init(lossPercent: 20, burstLength: 4, jitter: 0.08), on: input)

		let expectedTicks = result.frameCount + JitterBuffer.maxDepth + 10
		#expect(result.output.count == expectedTicks * AudioConfig.samplesPerFrame)
		#expect(result.output.count >= input.count,
		        "output is shorter than input, so the pipeline dropped time on the floor")
	}

	@Test("Audio actually comes out the far end")
	func audioSurvives() throws {
		let input = speech()
		let inputEnergy = SyntheticSpeech.energy(input)
		let result = try run(.init(), on: input)
		let outputEnergy = SyntheticSpeech.energy(result.output)

		#expect(inputEnergy > 0)
		let ratio = outputEnergy / inputEnergy
		#expect(ratio > 0.2 && ratio < 5,
		        "output/input energy ratio was \(ratio); expected roughly comparable")
	}

	@Test("Stays inside the BLE link budget")
	func bitrateWithinBudget() throws {
		let result = try run(.init())
		// ~22 kbps is the design point; well under the 200+ kbps BLE can carry, and
		// the margin is what makes FEC and a deep buffer affordable.
		#expect(result.bitrateKbps > 1)
		#expect(result.bitrateKbps < 25,
		        "encoder produced \(result.bitrateKbps) kbps, over the budget")
	}

	@Test("DTX engages during the silent gaps")
	func dtxEngages() throws {
		let result = try run(.init())
		#expect(result.dtxFrames > 20,
		        "only \(result.dtxFrames) DTX frames; silence is being sent at full rate")
	}

	// MARK: - Determinism

	@Test("A seed makes the run reproducible")
	func deterministic() throws {
		let input = speech()
		let first = try run(.init(lossPercent: 15, seed: 42), on: input)
		let second = try run(.init(lossPercent: 15, seed: 42), on: input)

		#expect(first.output == second.output)
		#expect(first.droppedInTransit == second.droppedInTransit)
	}

	@Test("A different seed produces a different loss pattern")
	func seedsDiffer() throws {
		let input = speech()
		let first = try run(.init(lossPercent: 15, seed: 1), on: input)
		let second = try run(.init(lossPercent: 15, seed: 99), on: input)
		#expect(first.output != second.output)
	}

	// MARK: - Loss

	@Test("Drops frames at roughly the requested rate", arguments: [10.0, 30.0])
	func lossRateIsHonoured(requested: Double) throws {
		let result = try run(.init(lossPercent: requested, seed: 7))
		let actual = Double(result.droppedInTransit) / Double(result.frameCount) * 100
		#expect(abs(actual - requested) < 4,
		        "asked for \(requested)% loss, got \(actual)%")
	}

	@Test("Every dropped frame is either recovered or concealed, never skipped")
	func lossIsFullyAccountedFor() throws {
		let result = try run(.init(lossPercent: 20, seed: 3))
		let hidden = result.stats.concealed + result.stats.fecRecovered
		#expect(abs(hidden - result.droppedInTransit) <= Self.tailSlack,
		        "\(result.droppedInTransit) dropped but \(hidden) hidden — frames vanished")
	}

	/// The regression guard that matters most, and it has to be a causal A/B.
	///
	/// An absolute "FEC recovered N%" threshold is worthless here: `opus_decode`
	/// with `decode_fec=1` returns a full frame whether or not the packet actually
	/// carried an FEC copy, so a naive counter cannot fail. `JitterBuffer` now
	/// checks `packetCarriesFEC` first, and this compares against a build with LBRR
	/// generation switched off (`expectedPacketLossPercent: 0`).
	@Test("In-band FEC measurably reduces concealment")
	func fecReducesConcealment() throws {
		let input = SyntheticSpeech.make(seconds: Self.duration)
		let withFEC = try run(.init(lossPercent: 10, burstLength: 1, seed: 7), on: input)
		let withoutFEC = try run(
			.init(lossPercent: 10, burstLength: 1, seed: 7, expectedPacketLossPercent: 0),
			on: input)

		#expect(withoutFEC.stats.fecRecovered == 0,
		        "encoder told to expect no loss should emit no FEC copies")
		#expect(withFEC.stats.fecRecovered > 0,
		        "no frames were genuinely repaired from an FEC copy")
		#expect(withFEC.stats.concealed < withoutFEC.stats.concealed,
		        "FEC did not reduce concealment: \(withFEC.stats.concealed) vs \(withoutFEC.stats.concealed)")
		#expect(withFEC.droppedInTransit == withoutFEC.droppedInTransit,
		        "same seed should drop the same frames, or this is not a fair comparison")
	}

	@Test("FEC costs little bitrate")
	func fecIsCheap() throws {
		let input = SyntheticSpeech.make(seconds: Self.duration)
		let withFEC = try run(.init(), on: input)
		let withoutFEC = try run(.init(expectedPacketLossPercent: 0), on: input)
		let overhead = withFEC.bitrateKbps - withoutFEC.bitrateKbps
		#expect(overhead > 0, "FEC should cost something; it appears to be off")
		#expect(overhead < 4, "FEC overhead of \(overhead) kbps is more than budgeted")
	}

	@Test("Bursts defeat FEC, because the repair copy is lost along with the run")
	func burstsDefeatFEC() throws {
		let isolated = try run(.init(lossPercent: 10, burstLength: 1, seed: 7))
		let bursty = try run(.init(lossPercent: 10, burstLength: 6, seed: 7))

		#expect(bursty.fecRecoveryRatio < isolated.fecRecoveryRatio / 2,
		        "bursty \(bursty.fecRecoveryRatio) vs isolated \(isolated.fecRecoveryRatio)")
		#expect(bursty.fecRecoveryRatio < 0.10)
	}

	@Test("LBRR detection distinguishes packets that carry a repair copy")
	func lbrrDetectionIsMeaningful() throws {
		let input = SyntheticSpeech.make(seconds: 4)
		let frameSize = AudioConfig.samplesPerFrame

        func fecBearingFraction(expectedLoss: Int) throws -> Double {
			let encoder = try OpusEncoder(packetLossPercent: expectedLoss)
			let decoder = try OpusDecoder()
			var carrying = 0
			var total = 0
			for index in 0..<(input.count / frameSize) {
				let start = index * frameSize
				let payload = try encoder.encode(Array(input[start..<(start + frameSize)]))
				guard !OpusEncoder.isSilenceFrame(payload) else { continue }
				total += 1
				if decoder.packetCarriesFEC(payload) { carrying += 1 }
			}
			return total > 0 ? Double(carrying) / Double(total) : 0
		}

		#expect(try fecBearingFraction(expectedLoss: 0) == 0,
		        "no FEC copies should exist when the encoder expects no loss")
		#expect(try fecBearingFraction(expectedLoss: 10) > 0,
		        "no packet carried an LBRR copy; FEC is not actually enabled")
	}

	@Test("Heavy loss degrades rather than silencing the call")
	func heavyLossStillProducesAudio() throws {
		let input = speech()
		let clean = try run(.init(), on: input)
		let lossy = try run(.init(lossPercent: 30, burstLength: 3, seed: 5), on: input)

		let ratio = SyntheticSpeech.energy(lossy.output) / SyntheticSpeech.energy(clean.output)
		#expect(ratio > 0.3,
		        "30% loss collapsed output energy to \(ratio) of clean — concealment is not working")
	}

	// MARK: - Jitter

	@Test("Jitter inside the buffer's depth is absorbed completely")
	func jitterWithinDepthIsAbsorbed() throws {
		// 100 ms sits under the 160 ms ceiling (maxDepth of 8 frames).
		let result = try run(.init(jitter: 0.100, seed: 11))
		#expect(result.stats.late == 0,
		        "\(result.stats.late) frames arrived too late despite fitting in the buffer")
		#expect(result.stats.concealed < Self.tailSlack)
	}

	@Test("Jitter past the buffer's depth starts costing late frames")
	func jitterBeyondDepthCausesLateArrivals() throws {
		let result = try run(.init(jitter: 0.400, seed: 11))
		#expect(result.stats.late > 50,
		        "expected heavy lateness at 400 ms jitter, saw \(result.stats.late)")
	}

	/// Pins the boundary the UI's slider range depends on. If `maxDepth` changes,
	/// this should fail and the slider range should be revisited.
	@Test("The absorb/degrade boundary sits at the buffer's maximum depth")
	func jitterBoundaryMatchesBufferDepth() throws {
		let ceiling = Double(JitterBuffer.maxDepth) * AudioConfig.frameDuration
		#expect(ceiling == 0.160)

		let under = try run(.init(jitter: ceiling * 0.6, seed: 11))
		let over = try run(.init(jitter: ceiling * 2.5, seed: 11))

		#expect(under.stats.late == 0)
		#expect(over.stats.late > under.stats.late)
	}

	@Test("Reordering alone does not lose frames")
	func reorderingIsRecovered() throws {
		// Jitter reorders arrivals; within the buffer's depth nothing should be lost.
		let result = try run(.init(jitter: 0.080, seed: 21))
		#expect(result.stats.received == result.frameCount)
		#expect(result.stats.late == 0)
		#expect(result.stats.concealed < Self.tailSlack)
	}
}
