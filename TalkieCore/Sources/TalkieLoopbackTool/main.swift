import Foundation
import TalkieCore
import TalkieSimulation

/// Command-line front end for `LoopbackSimulation`: WAV in, WAV out, statistics
/// on stdout. All the pipeline logic lives in the simulation so the tests
/// exercise exactly the same code.
///
///   talkie-loopback --input speech.wav --output out.wav --loss 10 --burst 6
struct Options {
	var input = ""
	var output = ""
	var settings = LoopbackSimulation.Settings()
	/// Synthesise input instead of reading a file, for a quick check with no fixture.
	var syntheticSeconds: Double?
}

func parseOptions() -> Options {
	var options = Options()
	var arguments = Array(CommandLine.arguments.dropFirst())
	while let flag = arguments.first {
		arguments.removeFirst()
		func next() -> String { arguments.isEmpty ? "" : arguments.removeFirst() }
		switch flag {
		case "--input": options.input = next()
		case "--output": options.output = next()
		case "--loss": options.settings.lossPercent = Double(next()) ?? 0
		case "--burst": options.settings.burstLength = max(1, Int(next()) ?? 1)
		case "--jitter": options.settings.jitter = (Double(next()) ?? 0) / 1000
		case "--seed": options.settings.seed = UInt64(next()) ?? 1
		case "--expected-loss": options.settings.expectedPacketLossPercent = max(0, Int(next()) ?? 0)
		case "--synthetic": options.syntheticSeconds = Double(next()) ?? 10
		default:
			FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
			exit(2)
		}
	}
	return options
}

let options = parseOptions()
guard !options.output.isEmpty, !options.input.isEmpty || options.syntheticSeconds != nil else {
	print("""
	usage: talkie-loopback --output <wav> (--input <wav> | --synthetic <seconds>)
	                       [--loss <pct>] [--burst <frames>] [--jitter <ms>] [--seed <n>]
	""")
	exit(2)
}

let input: [Int16]
if let seconds = options.syntheticSeconds {
	input = SyntheticSpeech.make(seconds: seconds)
} else {
	let (samples, rate) = try WAV.read(URL(fileURLWithPath: options.input))
	guard rate == AudioConfig.sampleRate else {
		FileHandle.standardError.write(Data(
			"input must be \(AudioConfig.sampleRate) Hz mono; got \(rate) Hz\n".utf8))
		exit(2)
	}
	input = samples
}

let result = try LoopbackSimulation.run(input: input, settings: options.settings)
try WAV.write(result.output, sampleRate: AudioConfig.sampleRate, to: URL(fileURLWithPath: options.output))

let stats = result.stats
let seconds = Double(result.frameCount) * AudioConfig.frameDuration

print("""
input          \(options.input.isEmpty ? "synthetic" : options.input)  \
(\(result.frameCount) frames, \(String(format: "%.1f", seconds))s)
loss \(String(format: "%.0f", options.settings.lossPercent))%  \
burst \(options.settings.burstLength)  \
jitter \(String(format: "%.0f", options.settings.jitter * 1000))ms
---
dropped in transit   \(result.droppedInTransit)   \
(\(String(format: "%.1f", Double(result.droppedInTransit) / Double(max(result.frameCount, 1)) * 100))%)
delivered            \(stats.received)
concealed            \(stats.concealed)
recovered via FEC    \(stats.fecRecovered)   \
(\(String(format: "%.0f", result.fecRecoveryRatio * 100))% of hidden frames)
arrived too late     \(stats.late)
rebuffers            \(stats.rebuffers)
---
encoded bitrate      \(String(format: "%.1f", result.bitrateKbps)) kbps
DTX (silence) frames \(result.dtxFrames)
output               \(options.output)
""")
