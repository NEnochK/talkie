import Foundation

public enum PacketType: UInt8, Sendable, CaseIterable {
	case audio = 1
	case control = 2
}

public struct PacketFlags: OptionSet, Sendable, Hashable {
	public let rawValue: UInt8
	public init(rawValue: UInt8) { self.rawValue = rawValue }

	/// First frame of a talkspurt. The receiver resets its playout clock on this,
	/// so a gap caused by DTX or a released PTT button is not mistaken for loss.
	public static let talkspurtStart = PacketFlags(rawValue: 1 << 0)
}

public enum PacketError: Error, Equatable {
	case tooShort(got: Int)
	case unsupportedVersion(UInt8)
	case unknownType(UInt8)
	case payloadTooLarge(Int)
}

/// On-the-wire frame. Four-byte header, then the payload.
///
/// ```
///  byte 0   version (high nibble) | type (low nibble)
///  byte 1-2 sequence, big endian, wraps
///  byte 3   flags
///  byte 4+  payload
/// ```
///
/// Audio payloads are one Opus frame. Control payloads are a `ControlMessage`.
public struct Packet: Equatable, Sendable {
	public static let headerSize = 4
	public static let version: UInt8 = 1
	/// Keeps a packet inside the smallest BLE write we expect to negotiate.
	public static let maxPayloadBytes = 512 - headerSize

	public var type: PacketType
	public var sequence: UInt16
	public var flags: PacketFlags
	public var payload: Data

	public init(type: PacketType, sequence: UInt16, flags: PacketFlags = [], payload: Data) {
		self.type = type
		self.sequence = sequence
		self.flags = flags
		self.payload = payload
	}

	public func encoded() throws -> Data {
		guard payload.count <= Self.maxPayloadBytes else {
			throw PacketError.payloadTooLarge(payload.count)
		}
		var out = Data(capacity: Self.headerSize + payload.count)
		out.append(Self.version << 4 | type.rawValue)
		out.append(UInt8(truncatingIfNeeded: sequence >> 8))
		out.append(UInt8(truncatingIfNeeded: sequence))
		out.append(flags.rawValue)
		out.append(payload)
		return out
	}

	public static func decode(_ data: Data) throws -> Packet {
		guard data.count >= headerSize else { throw PacketError.tooShort(got: data.count) }
		let base = data.startIndex

		let versionAndType = data[base]
		let version = versionAndType >> 4
		guard version == Self.version else { throw PacketError.unsupportedVersion(version) }

		let rawType = versionAndType & 0x0F
		guard let type = PacketType(rawValue: rawType) else { throw PacketError.unknownType(rawType) }

		let sequence = UInt16(data[base + 1]) << 8 | UInt16(data[base + 2])
		let flags = PacketFlags(rawValue: data[base + 3])
		// Re-base the slice so the payload's indices start at zero.
		let payload = Data(data[(base + headerSize)...])

		return Packet(type: type, sequence: sequence, flags: flags, payload: payload)
	}
}
