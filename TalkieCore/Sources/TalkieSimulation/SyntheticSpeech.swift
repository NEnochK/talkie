import Foundation
import TalkieCore

/// Deterministic speech-like signal, so tests need no audio fixture on disk and
/// no `say` binary.
///
/// Not real speech, but it has the properties that matter to this pipeline: a
/// voiced fundamental with harmonics for Opus's SILK mode to model, a syllabic
/// amplitude envelope, and genuine silent gaps so DTX engages the way it does on
/// a real call.
public enum SyntheticSpeech {
	public static func make(seconds: Double, sampleRate: Int = AudioConfig.sampleRate) -> [Int16] {
		let total = Int(seconds * Double(sampleRate))
		var samples = [Int16](repeating: 0, count: total)
		// Deterministic noise source for the fricatives.
		var noise = SeededGenerator(seed: 0xC0FFEE)

		let fundamental = 118.0
		// Rough formant-ish weighting; enough structure to be more than a tone.
		let harmonics: [(multiple: Double, level: Double)] = [
			(1, 1.0), (2, 0.55), (3, 0.32), (4, 0.18), (5, 0.10), (7, 0.06),
		]

		for index in 0..<total {
			let t = Double(index) / Double(sampleRate)

			// Four syllables a second, with a silent beat every two seconds.
			let syllable = max(0, sin(2 * .pi * 4 * t))
			let phrase = t.truncatingRemainder(dividingBy: 2.0) < 1.45 ? 1.0 : 0.0
			let envelope = syllable * syllable * phrase
			guard envelope > 0 else { continue }

			// Slow pitch drift keeps it from sounding like a static chord.
			let pitch = fundamental * (1 + 0.04 * sin(2 * .pi * 0.7 * t))

			var value = 0.0
			for harmonic in harmonics {
				value += harmonic.level * sin(2 * .pi * pitch * harmonic.multiple * t)
			}
			value /= harmonics.reduce(0) { $0 + $1.level }

			// A consonant burst at the head of each syllable. Onsets are the frames
			// Opus judges perceptually important, and therefore the ones it spends
			// LBRR (FEC) bits on — a purely periodic tone produces almost no FEC and
			// makes this a bad proxy for real speech.
			let intoSyllable = (t * 4).truncatingRemainder(dividingBy: 1.0)
			if intoSyllable < 0.10 {
				let burst = Double.random(in: -1...1, using: &noise) * 0.55
				value = value * 0.35 + burst
			}

			samples[index] = Int16(max(-1, min(1, value * envelope)) * 9000)
		}
		return samples
	}

	/// Mean square of a signal; used to check audio actually came out the far end.
	public static func energy(_ samples: [Int16]) -> Double {
		guard !samples.isEmpty else { return 0 }
		return samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
	}
}
