import COpusShim
import Foundation

public enum OpusError: Error, Equatable {
	case encoderCreateFailed(Int32)
	case decoderCreateFailed(Int32)
	case configureFailed(Int32)
	case encodeFailed(Int32)
	case decodeFailed(Int32)

	public var describedByOpus: String {
		switch self {
		case .encoderCreateFailed(let code), .decoderCreateFailed(let code),
			 .configureFailed(let code), .encodeFailed(let code), .decodeFailed(let code):
			return String(cString: talkie_opus_error_string(code))
		}
	}
}

/// Opus encoder pinned to Talkie's operating point: 16 kHz mono, 20 ms frames.
public final class OpusEncoder {
	/// With DTX on, a silent frame encodes to one or two bytes. Opus says such a
	/// packet need not be transmitted, but we send it anyway: at 2 bytes per frame
	/// it is a 25x saving over speech while keeping sequence numbers contiguous,
	/// which is what lets the receiver tell silence apart from packet loss.
	public static let maxDTXFrameBytes = 2

	private let handle: UnsafeMutableRawPointer
	private var output: [UInt8]

	public init(
		sampleRate: Int = AudioConfig.sampleRate,
		channels: Int = AudioConfig.channels,
		bitrate: Int = AudioConfig.bitrate,
		inbandFEC: Bool = true,
		packetLossPercent: Int = AudioConfig.expectedPacketLossPercent,
		dtx: Bool = true,
		complexity: Int = 5
	) throws {
		var error: Int32 = 0
		guard let created = talkie_opus_encoder_create(Int32(sampleRate), Int32(channels), &error) else {
			throw OpusError.encoderCreateFailed(error)
		}
		handle = created
		output = [UInt8](repeating: 0, count: AudioConfig.maxEncodedFrameBytes)

		let status = talkie_opus_encoder_configure(
			handle,
			Int32(bitrate),
			inbandFEC ? 1 : 0,
			Int32(packetLossPercent),
			dtx ? 1 : 0,
			Int32(complexity))
		guard status == 0 else {
			talkie_opus_encoder_destroy(handle)
			throw OpusError.configureFailed(status)
		}
	}

	deinit { talkie_opus_encoder_destroy(handle) }

	/// Encodes exactly one frame. `pcm` must hold `AudioConfig.samplesPerFrame`
	/// interleaved samples.
	public func encode(_ pcm: [Int16]) throws -> Data {
		precondition(pcm.count == AudioConfig.samplesPerFrame,
		             "expected \(AudioConfig.samplesPerFrame) samples, got \(pcm.count)")

		let written: Int32 = pcm.withUnsafeBufferPointer { input in
			output.withUnsafeMutableBufferPointer { out in
				talkie_opus_encode(handle,
				                   input.baseAddress,
				                   Int32(AudioConfig.samplesPerFrame),
				                   out.baseAddress,
				                   Int32(out.count))
			}
		}
		guard written > 0 else { throw OpusError.encodeFailed(written) }
		return Data(output[0..<Int(written)])
	}

	/// True when Opus decided the frame was silence and emitted a DTX packet.
	public static func isSilenceFrame(_ payload: Data) -> Bool {
		payload.count <= maxDTXFrameBytes
	}
}

/// Opus decoder, including the two loss paths.
public final class OpusDecoder: FrameDecoding {
	private let handle: UnsafeMutableRawPointer
	private var pcm: [Int16]

	public init(
		sampleRate: Int = AudioConfig.sampleRate,
		channels: Int = AudioConfig.channels
	) throws {
		var error: Int32 = 0
		guard let created = talkie_opus_decoder_create(Int32(sampleRate), Int32(channels), &error) else {
			throw OpusError.decoderCreateFailed(error)
		}
		handle = created
		pcm = [Int16](repeating: 0, count: AudioConfig.samplesPerFrame)
	}

	deinit { talkie_opus_decoder_destroy(handle) }

	public func decode(_ payload: Data) throws -> [Int16] {
		try run(payload: payload, decodeFEC: false)
	}

	public func packetCarriesFEC(_ payload: Data) -> Bool {
		payload.withUnsafeBytes { raw in
			guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
			return talkie_opus_packet_has_lbrr(base, Int32(payload.count)) == 1
		}
	}

	public func conceal() throws -> [Int16] {
		try run(payload: nil, decodeFEC: false)
	}

	/// Rebuilds the previous frame from the FEC copy inside `nextPayload`.
	///
	/// Check `packetCarriesFEC` first. With no FEC copy present Opus falls back to
	/// concealment internally and still returns a full frame, so a caller that does
	/// not check cannot tell a genuine repair from plain loss.
	public func decodeFEC(from nextPayload: Data) throws -> [Int16] {
		try run(payload: nextPayload, decodeFEC: true)
	}

	private func run(payload: Data?, decodeFEC: Bool) throws -> [Int16] {
		let decoded: Int32 = pcm.withUnsafeMutableBufferPointer { out in
			let frameSize = Int32(AudioConfig.samplesPerFrame)
			let fecFlag: Int32 = decodeFEC ? 1 : 0
			if let payload {
				return payload.withUnsafeBytes { raw in
					talkie_opus_decode(handle,
					                   raw.bindMemory(to: UInt8.self).baseAddress,
					                   Int32(payload.count),
					                   out.baseAddress,
					                   frameSize,
					                   fecFlag)
				}
			}
			return talkie_opus_decode(handle, nil, 0, out.baseAddress, frameSize, fecFlag)
		}
		guard decoded > 0 else { throw OpusError.decodeFailed(decoded) }
		return Array(pcm[0..<Int(decoded)])
	}
}
