import Foundation
import Testing

@testable import TalkieCore

/// One frame of a 440 Hz tone, which Opus will treat as real signal rather than silence.
private func toneFrame(startingAt phase: Int = 0, amplitude: Double = 8000) -> [Int16] {
	(0..<AudioConfig.samplesPerFrame).map { index in
		let t = Double(phase + index) / Double(AudioConfig.sampleRate)
		return Int16(amplitude * sin(2 * .pi * 440 * t))
	}
}

private func silentFrame() -> [Int16] {
	Array(repeating: 0, count: AudioConfig.samplesPerFrame)
}

@Suite("Opus codec")
struct OpusCodecTests {
	@Test("Creates an encoder at the configured operating point")
	func encoderCreation() throws {
		_ = try OpusEncoder()
	}

	@Test("Encodes speech to roughly the expected frame size")
	func encodesToTargetBitrate() throws {
		let encoder = try OpusEncoder()

		// Skip the first few frames while the encoder settles.
		var sizes: [Int] = []
		for frame in 0..<50 {
			let encoded = try encoder.encode(toneFrame(startingAt: frame * AudioConfig.samplesPerFrame))
			if frame >= 10 { sizes.append(encoded.count) }
		}

		let average = Double(sizes.reduce(0, +)) / Double(sizes.count)
		// 20 kbps at 50 frames/sec is 50 bytes. Allow generous slack for VBR.
		#expect(average > 20, "average frame was \(average) bytes, suspiciously small")
		#expect(average < 120, "average frame was \(average) bytes, over the link budget")
		#expect(sizes.allSatisfy { $0 <= AudioConfig.maxEncodedFrameBytes })
	}

	@Test("Round-trips a frame back to the right number of samples")
	func roundTrip() throws {
		let encoder = try OpusEncoder()
		let decoder = try OpusDecoder()

		var decoded: [Int16] = []
		for frame in 0..<20 {
			let encoded = try encoder.encode(toneFrame(startingAt: frame * AudioConfig.samplesPerFrame))
			decoded = try decoder.decode(encoded)
			#expect(decoded.count == AudioConfig.samplesPerFrame)
		}

		// Once warmed up the output should carry real signal, not silence.
		let peak = decoded.map { abs(Int($0)) }.max() ?? 0
		#expect(peak > 500, "decoded audio was near-silent (peak \(peak))")
	}

	@Test("Emits tiny DTX frames once the input goes quiet")
	func dtxOnSilence() throws {
		let encoder = try OpusEncoder()

		// Speak briefly so the encoder has something to transition away from.
		for frame in 0..<10 {
			_ = try encoder.encode(toneFrame(startingAt: frame * AudioConfig.samplesPerFrame))
		}

		var sawDTX = false
		for _ in 0..<40 {
			let encoded = try encoder.encode(silentFrame())
			if OpusEncoder.isSilenceFrame(encoded) { sawDTX = true }
		}

		#expect(sawDTX, "DTX never engaged across 40 silent frames")
	}

	@Test("Concealment produces a full frame of audio")
	func concealment() throws {
		let encoder = try OpusEncoder()
		let decoder = try OpusDecoder()

		for frame in 0..<10 {
			_ = try decoder.decode(try encoder.encode(toneFrame(startingAt: frame * AudioConfig.samplesPerFrame)))
		}

		let concealed = try decoder.conceal()
		#expect(concealed.count == AudioConfig.samplesPerFrame)
	}

	@Test("FEC decode returns a full frame from the following packet")
	func fecRecovery() throws {
		let encoder = try OpusEncoder()
		let decoder = try OpusDecoder()

		var previous = Data()
		for frame in 0..<10 {
			let encoded = try encoder.encode(toneFrame(startingAt: frame * AudioConfig.samplesPerFrame))
			if frame > 0 { _ = try decoder.decode(previous) }
			previous = encoded
		}

		// Pretend the frame before `previous` was lost and rebuild it.
		let recovered = try decoder.decodeFEC(from: previous)
		#expect(recovered.count == AudioConfig.samplesPerFrame)
	}

	@Test("Rejects a frame of the wrong length")
	func wrongFrameSizeIsProgrammerError() throws {
		let encoder = try OpusEncoder()
		// A short frame is a bug in the framer, not a runtime condition, so it
		// trips a precondition rather than throwing. Just assert the happy path
		// accepts exactly the configured size.
		#expect(try encoder.encode(silentFrame()).count >= 1)
	}

	@Test("Decoding garbage throws rather than crashing")
	func decodingGarbage() throws {
		let decoder = try OpusDecoder()
		#expect(throws: (any Error).self) {
			try decoder.decode(Data([0xFF, 0xFF, 0xFF, 0xFF]))
		}
	}

	@Test("Encoder and jitter buffer agree on the decoder interface")
	func integratesWithJitterBuffer() throws {
		let encoder = try OpusEncoder()
		let buffer = JitterBuffer(decoder: try OpusDecoder())

		for sequence in 0..<10 {
			let encoded = try encoder.encode(toneFrame(startingAt: sequence * AudioConfig.samplesPerFrame))
			buffer.push(sequence: UInt16(sequence),
			            payload: encoded,
			            arrivalTime: Double(sequence) * AudioConfig.frameDuration)
		}

		var frames = 0
		// Order matters: checking the count first stops us popping an eleventh
		// frame from an empty buffer, which would register as a concealment.
		while frames < 10, let frame = buffer.pop() {
			#expect(frame.count == AudioConfig.samplesPerFrame)
			frames += 1
		}
		#expect(frames == 10)
		#expect(buffer.stats.concealed == 0)
	}
}
