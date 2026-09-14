import Testing
@testable import TalkieCore
@testable import TalkieSimulation

/// Diagnostic, not an assertion: prints how loss behaves across burst lengths.
/// Run with `swift test --filter FECProbe` when tuning.
@Suite("FECProbe", .disabled("diagnostic only; run explicitly when tuning"))
struct FECProbe {
	@Test func burstSweep() throws {
		let input = SyntheticSpeech.make(seconds: 10)
		for burst in [1, 2, 3, 6] {
			let r = try LoopbackSimulation.run(input: input, settings: .init(
				lossPercent: 10, burstLength: burst, seed: 7))
			print(String(format: "burst %d -> dropped %3d  FEC %3d (%4.1f%%)  concealed %3d",
			             burst, r.droppedInTransit, r.stats.fecRecovered,
			             r.fecRecoveryRatio * 100, r.stats.concealed))
		}
	}
}
