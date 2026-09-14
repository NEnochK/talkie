import Foundation

/// Minimal 16-bit mono PCM WAV reader/writer. Enough for this harness, not a
/// general-purpose implementation.
public enum WAV {
	public static func read(_ url: URL) throws -> (samples: [Int16], sampleRate: Int) {
		let data = try Data(contentsOf: url)
		guard data.count > 44 else { throw Failure.tooShort }

		func u32(_ offset: Int) -> UInt32 {
			data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
		}
		func u16(_ offset: Int) -> UInt16 {
			data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
		}

		guard data[0..<4].elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) else {
			throw Failure.notWAV
		}

		// Walk the chunk list rather than assuming a 44-byte header.
		var offset = 12
		var sampleRate = 0
		var bitsPerSample = 0
		var channels = 0
		var payload: Data?

		while offset + 8 <= data.count {
			let id = data[offset..<(offset + 4)]
			let size = Int(u32(offset + 4))
			let body = offset + 8

			if id.elementsEqual("fmt ".utf8) {
				channels = Int(u16(body + 2))
				sampleRate = Int(u32(body + 4))
				bitsPerSample = Int(u16(body + 14))
			} else if id.elementsEqual("data".utf8) {
				payload = data[body..<min(body + size, data.count)]
			}
			offset = body + size + (size % 2)
		}

		guard let payload else { throw Failure.noData }
		guard bitsPerSample == 16 else { throw Failure.unsupported("\(bitsPerSample)-bit; need 16") }
		guard channels == 1 else { throw Failure.unsupported("\(channels) channels; need mono") }

		let samples = payload.withUnsafeBytes { raw -> [Int16] in
			let count = raw.count / 2
			return (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
		}
		return (samples, sampleRate)
	}

	public static func write(_ samples: [Int16], sampleRate: Int, to url: URL) throws {
		var out = Data()
		func append(_ string: String) { out.append(contentsOf: string.utf8) }
		func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
		func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }

		let byteCount = UInt32(samples.count * 2)
		append("RIFF"); append(36 + byteCount); append("WAVE")
		append("fmt "); append(UInt32(16))
		append(UInt16(1))                             // PCM
		append(UInt16(1))                             // mono
		append(UInt32(sampleRate))
		append(UInt32(sampleRate * 2))                // byte rate
		append(UInt16(2))                             // block align
		append(UInt16(16))                            // bits per sample
		append("data"); append(byteCount)
		samples.withUnsafeBufferPointer { out.append(contentsOf: UnsafeRawBufferPointer($0)) }

		try out.write(to: url)
	}

	public enum Failure: Error, CustomStringConvertible {
		case tooShort, notWAV, noData
		case unsupported(String)

		public var description: String {
			switch self {
			case .tooShort: return "file is too short to be a WAV"
			case .notWAV: return "not a RIFF/WAVE file"
			case .noData: return "no data chunk"
			case .unsupported(let detail): return "unsupported format: \(detail)"
			}
		}
	}
}
