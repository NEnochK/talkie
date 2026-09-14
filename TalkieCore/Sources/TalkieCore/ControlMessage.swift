import Foundation

/// Reliable, low-rate signalling that rides the control characteristic.
///
/// Hand-encoded rather than `Codable`: these go over a `.write`-with-response
/// characteristic roughly once a second, and a compact fixed layout keeps them
/// well inside a single BLE write with no framing surprises.
public enum ControlMessage: Equatable, Sendable {
	/// Identity is a per-install UUID. Both peers need a value they can compare
	/// symmetrically to decide which of two crossed connections to keep, and
	/// Core Bluetooth's own identifiers cannot do that: each side only ever sees
	/// a locally-scoped id for the *other* device.
	case hello(identity: UUID, name: String)
	case talkStart
	case talkEnd
	case mute(Bool)
	case ping(id: UInt32)
	case pong(id: UInt32)
	case bye

	/// UTF-8 bytes; longer names are truncated on a character boundary.
	public static let maxNameBytes = 63

	private enum Opcode: UInt8 {
		case hello = 1, talkStart = 2, talkEnd = 3, mute = 4, ping = 5, pong = 6, bye = 7
	}

	public func encoded() -> Data {
		var out = Data()
		switch self {
		case .hello(let identity, let name):
			out.append(Opcode.hello.rawValue)
			out.append(contentsOf: bytes(of: identity))
			out.append(Self.truncatedNameBytes(name))
		case .talkStart:
			out.append(Opcode.talkStart.rawValue)
		case .talkEnd:
			out.append(Opcode.talkEnd.rawValue)
		case .mute(let muted):
			out.append(Opcode.mute.rawValue)
			out.append(muted ? 1 : 0)
		case .ping(let id):
			out.append(Opcode.ping.rawValue)
			out.append(bigEndianBytes(id))
		case .pong(let id):
			out.append(Opcode.pong.rawValue)
			out.append(bigEndianBytes(id))
		case .bye:
			out.append(Opcode.bye.rawValue)
		}
		return out
	}

	public static func decode(_ payload: Data) throws -> ControlMessage {
		guard let first = payload.first else { throw ControlMessageError.empty }
		guard let opcode = Opcode(rawValue: first) else { throw ControlMessageError.unknownOpcode(first) }
		let body = Data(payload[(payload.startIndex + 1)...])

		switch opcode {
		case .hello:
			guard body.count >= 16 else { throw ControlMessageError.truncated(opcode: first) }
			let identityBytes = Data(body[body.startIndex..<(body.startIndex + 16)])
			let nameBytes = Data(body[(body.startIndex + 16)...])
			// Invalid trailing bytes are replaced rather than failing the message.
			return .hello(identity: uuid(from: identityBytes),
			              name: String(decoding: nameBytes, as: UTF8.self))
		case .talkStart:
			return .talkStart
		case .talkEnd:
			return .talkEnd
		case .mute:
			guard let flag = body.first else { throw ControlMessageError.truncated(opcode: first) }
			return .mute(flag != 0)
		case .ping, .pong:
			guard body.count >= 4 else { throw ControlMessageError.truncated(opcode: first) }
			let id = UInt32(body[body.startIndex]) << 24
				| UInt32(body[body.startIndex + 1]) << 16
				| UInt32(body[body.startIndex + 2]) << 8
				| UInt32(body[body.startIndex + 3])
			return opcode == .ping ? .ping(id: id) : .pong(id: id)
		case .bye:
			return .bye
		}
	}

	/// Truncates to `maxNameBytes` without splitting a UTF-8 scalar.
	static func truncatedNameBytes(_ name: String) -> Data {
		var candidate = name
		while candidate.utf8.count > maxNameBytes {
			candidate.removeLast()
		}
		return Data(candidate.utf8)
	}
}

public enum ControlMessageError: Error, Equatable {
	case empty
	case unknownOpcode(UInt8)
	case truncated(opcode: UInt8)
}

private func bytes(of identity: UUID) -> Data {
	withUnsafeBytes(of: identity.uuid) { Data($0) }
}

private func uuid(from data: Data) -> UUID {
	var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	withUnsafeMutableBytes(of: &raw) { destination in
		data.copyBytes(to: destination.bindMemory(to: UInt8.self), count: min(16, data.count))
	}
	return UUID(uuid: raw)
}

private func bigEndianBytes(_ value: UInt32) -> Data {
	Data([
		UInt8(truncatingIfNeeded: value >> 24),
		UInt8(truncatingIfNeeded: value >> 16),
		UInt8(truncatingIfNeeded: value >> 8),
		UInt8(truncatingIfNeeded: value),
	])
}
