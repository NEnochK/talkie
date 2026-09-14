import Foundation
import Testing

@testable import TalkieCore

@Suite("Packet wire format")
struct PacketTests {
	@Test("Round-trips an audio packet")
	func audioRoundTrip() throws {
		let payload = Data([0x11, 0x22, 0x33, 0x44, 0x55])
		let original = Packet(type: .audio, sequence: 4242, flags: .talkspurtStart, payload: payload)

		let decoded = try Packet.decode(try original.encoded())

		#expect(decoded == original)
		#expect(decoded.payload == payload)
		#expect(decoded.flags.contains(.talkspurtStart))
	}

	@Test("Header is exactly four bytes")
	func headerSize() throws {
		let encoded = try Packet(type: .audio, sequence: 1, payload: Data([0xAB])).encoded()
		#expect(encoded.count == Packet.headerSize + 1)
	}

	@Test("Survives sequence wraparound at 65535", arguments: [0, 1, 32767, 32768, 65534, 65535] as [UInt16])
	func sequenceWraparound(sequence: UInt16) throws {
		let decoded = try Packet.decode(
			try Packet(type: .audio, sequence: sequence, payload: Data([0x01])).encoded())
		#expect(decoded.sequence == sequence)
	}

	@Test("Decodes a payload-free control packet")
	func emptyPayload() throws {
		let decoded = try Packet.decode(
			try Packet(type: .control, sequence: 7, payload: Data()).encoded())
		#expect(decoded.payload.isEmpty)
		#expect(decoded.type == .control)
	}

	@Test("Decoding a re-based slice keeps payload indices sane")
	func slicedInput() throws {
		// Data arriving from Core Bluetooth is often a slice with a non-zero
		// startIndex; the decoder must not assume it starts at zero.
		let encoded = try Packet(type: .audio, sequence: 9, payload: Data([0xDE, 0xAD])).encoded()
		let padded = Data([0xFF, 0xFF]) + encoded
		let slice = padded.dropFirst(2)

		let decoded = try Packet.decode(slice)

		#expect(decoded.sequence == 9)
		#expect(decoded.payload == Data([0xDE, 0xAD]))
		#expect(decoded.payload.startIndex == 0)
	}

	@Test("Rejects a truncated header")
	func tooShort() {
		#expect(throws: PacketError.tooShort(got: 3)) {
			try Packet.decode(Data([0x11, 0x00, 0x00]))
		}
	}

	@Test("Rejects an unknown version")
	func badVersion() {
		#expect(throws: PacketError.unsupportedVersion(9)) {
			try Packet.decode(Data([0x91, 0x00, 0x00, 0x00]))
		}
	}

	@Test("Rejects an unknown type")
	func badType() {
		#expect(throws: PacketError.unknownType(15)) {
			try Packet.decode(Data([0x1F, 0x00, 0x00, 0x00]))
		}
	}

	@Test("Rejects an oversized payload")
	func oversized() {
		let packet = Packet(type: .audio, sequence: 0,
		                    payload: Data(repeating: 0, count: Packet.maxPayloadBytes + 1))
		#expect(throws: PacketError.payloadTooLarge(Packet.maxPayloadBytes + 1)) {
			try packet.encoded()
		}
	}
}

@Suite("Sequence arithmetic")
struct SequenceTests {
	@Test("Measures distance across the wrap boundary")
	func wrapDistance() {
		#expect(seqDelta(5, 3) == 2)
		#expect(seqDelta(3, 5) == -2)
		#expect(seqDelta(0, 65535) == 1)
		#expect(seqDelta(65535, 0) == -1)
		#expect(seqDelta(2, 65534) == 4)
		#expect(seqDelta(42, 42) == 0)
	}
}
