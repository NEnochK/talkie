import CoreBluetooth

enum BLEConstants {
	/// There is no fixed service UUID any more: it is derived per channel by
	/// `Channel`, because the service UUID is the only part of an advertisement
	/// that survives the app being backgrounded. The characteristic UUIDs below
	/// are fixed — they live inside whichever service we publish.

	/// Audio from the peripheral to the central, via notifications.
	static let audioDownlinkUUID = CBUUID(string: "0B228A3D-3091-48C3-9757-4611DAE829C0")
	/// Audio from the central to the peripheral, via write-without-response.
	static let audioUplinkUUID = CBUUID(string: "CC0AC312-6183-4290-8C15-08D4429DCB55")
	/// Reliable signalling, both directions.
	static let controlUUID = CBUUID(string: "A58D9433-EBB0-49FC-8CBD-6A648662A4A5")

	/// Forces LE Secure Connections pairing so voice is not in the clear over the
	/// air. Costs a one-time system pairing prompt. Set false only to isolate a
	/// pairing problem during bring-up.
	static let requireEncryption = true

	/// Shared serial queue for Core Bluetooth callbacks, the jitter buffer, and the
	/// decode pump. Keeping them on one queue removes the need to lock any of them.
	static let queue = DispatchQueue(label: "com.talkie.ble", qos: .userInitiated)

	/// Conservative payload ceiling until the real ATT MTU is known.
	static let fallbackWriteLength = 180
}
