import Foundation
import Testing

@testable import TalkieCore

@Suite("Control messages")
struct ControlMessageTests {
	@Test("Round-trips every case", arguments: [
		ControlMessage.hello(identity: UUID(uuidString: "2F1A9B44-0C3E-4B1D-9A77-5E6D8C0F1234")!, name: "Enoch's iPhone"),
		.talkStart,
		.talkEnd,
		.mute(true),
		.mute(false),
		.ping(id: 0),
		.ping(id: 0xDEAD_BEEF),
		.pong(id: 0xDEAD_BEEF),
		.bye,
	])
	func roundTrip(message: ControlMessage) throws {
		#expect(try ControlMessage.decode(message.encoded()) == message)
	}

	@Test("Survives a round trip nested in a control packet")
	func throughPacket() throws {
		let message = ControlMessage.ping(id: 12345)
		let packet = Packet(type: .control, sequence: 1, payload: message.encoded())

		let decodedPacket = try Packet.decode(try packet.encoded())

		#expect(decodedPacket.type == .control)
		#expect(try ControlMessage.decode(decodedPacket.payload) == message)
	}

	@Test("Truncates a long name on a character boundary")
	func nameTruncation() throws {
		// Four bytes per emoji, so 20 of them is 80 bytes against a 63-byte cap.
		let long = String(repeating: "🎧", count: 20)
		let encoded = ControlMessage.hello(identity: UUID(), name: long).encoded()

		// Opcode byte, 16-byte identity, then at most the name cap.
		#expect(encoded.count <= 1 + 16 + ControlMessage.maxNameBytes)

		guard case .hello(_, let name) = try ControlMessage.decode(encoded) else {
			Issue.record("expected a hello")
			return
		}
		// A clean boundary means every scalar survived intact.
		#expect(name.allSatisfy { $0 == "🎧" })
		#expect(name.count == 15)
	}

	@Test("Keeps a short unicode name intact")
	func shortName() throws {
		let message = ControlMessage.hello(identity: UUID(), name: "Café 🎧")
		guard case .hello(_, let name) = try ControlMessage.decode(message.encoded()) else {
			Issue.record("expected a hello")
			return
		}
		#expect(name == "Café 🎧")
	}

	@Test("Rejects an empty payload")
	func empty() {
		#expect(throws: ControlMessageError.empty) {
			try ControlMessage.decode(Data())
		}
	}

	@Test("Rejects an unknown opcode")
	func unknownOpcode() {
		#expect(throws: ControlMessageError.unknownOpcode(99)) {
			try ControlMessage.decode(Data([99]))
		}
	}

	@Test("Preserves the identity UUID exactly")
	func identityRoundTrip() throws {
		let identity = UUID()
		guard case .hello(let decoded, let name) = try ControlMessage.decode(
			ControlMessage.hello(identity: identity, name: "Pixel").encoded()) else {
			Issue.record("expected a hello")
			return
		}
		#expect(decoded == identity)
		#expect(name == "Pixel")
	}

	@Test("Rejects a hello whose identity is truncated")
	func truncatedHello() {
		#expect(throws: ControlMessageError.truncated(opcode: 1)) {
			try ControlMessage.decode(Data([1] + [UInt8](repeating: 0, count: 10)))
		}
	}

	@Test("Rejects a ping with a short body")
	func truncatedPing() {
		#expect(throws: ControlMessageError.truncated(opcode: 5)) {
			try ControlMessage.decode(Data([5, 0x00, 0x01]))
		}
	}
}
