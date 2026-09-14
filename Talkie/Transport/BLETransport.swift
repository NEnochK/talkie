import CoreBluetooth
import Foundation
import TalkieCore

/// Runs both GATT roles at once and presents them as a single duplex link.
///
/// Both devices advertise and scan simultaneously, so both may connect to each
/// other at the same moment. One connection has to go, and the decision must be
/// made without a coordinator and be identical on both sides.
///
/// The advertisement cannot carry the tiebreaker: iOS strips manufacturer data and
/// the local name once the app is backgrounded, leaving only the service UUID. So
/// each side sends a persistent per-install identity in its `hello` over the
/// control characteristic, and whichever side has the higher identity drops its own
/// outbound (central) connection. Both compute the same answer, exactly one link
/// survives, and it works in every app state.
final class BLETransport: NSObject, Transport {
	weak var delegate: TransportDelegate?

	private(set) var state: TransportState = .idle {
		didSet {
			guard state != oldValue else { return }
			delegate?.transportDidChangeState(self)
		}
	}

	var queue: DispatchQueue { BLEConstants.queue }

	var droppedAudioFrames: Int {
		peripheralRole.droppedAudioFrames + centralRole.droppedAudioFrames
	}

	/// Stable across launches so the tiebreak does not flip between sessions.
	let identity: UUID
	let localName: String
	/// Only peers that derived this same channel are discoverable at all.
	let channel: Channel

	private(set) var peerIdentity: UUID?
	private(set) var peerName: String?

	private let peripheralRole: BLEPeripheralRole
	private let centralRole: BLECentralRole
	private var isRunning = false

	private enum Link { case none, central, peripheral }

	init(
		identity: UUID = BLETransport.persistentIdentity(),
		localName: String,
		channel: Channel
	) {
		self.identity = identity
		self.localName = localName
		self.channel = channel
		let serviceUUID = CBUUID(nsuuid: channel.serviceUUID)
		self.peripheralRole = BLEPeripheralRole(queue: BLEConstants.queue, serviceUUID: serviceUUID)
		self.centralRole = BLECentralRole(queue: BLEConstants.queue, serviceUUID: serviceUUID)
		super.init()
		peripheralRole.delegate = self
		centralRole.delegate = self
	}

	static func persistentIdentity() -> UUID {
		let key = "com.talkie.identity"
		if let stored = UserDefaults.standard.string(forKey: key), let existing = UUID(uuidString: stored) {
			return existing
		}
		let fresh = UUID()
		UserDefaults.standard.set(fresh.uuidString, forKey: key)
		return fresh
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true
		peripheralRole.start()
		centralRole.start()
		refreshState()
	}

	func stop() {
		isRunning = false
		peripheralRole.stop()
		centralRole.stop()
		peerIdentity = nil
		peerName = nil
		state = .idle
	}

	/// Largest audio payload the live link will carry.
	var maximumPayloadLength: Int {
		switch activeLink {
		case .central: return centralRole.maximumPayloadLength
		case .peripheral: return peripheralRole.maximumPayloadLength
		case .none: return BLEConstants.fallbackWriteLength
		}
	}

	@discardableResult
	func sendAudio(_ packet: Packet) -> Bool {
		guard let data = try? packet.encoded() else { return false }
		switch activeLink {
		case .central: return centralRole.sendAudio(data)
		case .peripheral: return peripheralRole.sendAudio(data)
		case .none: return false
		}
	}

	func sendControl(_ message: ControlMessage) {
		let packet = Packet(type: .control, sequence: 0, payload: message.encoded())
		guard let data = try? packet.encoded() else { return }
		switch activeLink {
		case .central: centralRole.sendControl(data)
		case .peripheral: peripheralRole.sendControl(data)
		case .none: break
		}
	}

	/// Which of the two links carries traffic right now.
	///
	/// While both are momentarily up, this already reflects the tiebreak result, so
	/// audio never flows over the link that is about to be torn down.
	private var activeLink: Link {
		let central = centralRole.isLinkUp
		let peripheral = peripheralRole.isLinkUp

		switch (central, peripheral) {
		case (true, false): return .central
		case (false, true): return .peripheral
		case (false, false): return .none
		case (true, true):
			guard let peerIdentity else { return .central }
			return identity.uuidString < peerIdentity.uuidString ? .central : .peripheral
		}
	}

	/// Tears down the redundant connection once both sides have identified themselves.
	private func resolveCrossedConnection() {
		guard centralRole.isLinkUp, peripheralRole.isLinkUp, let peerIdentity else { return }
		if identity.uuidString > peerIdentity.uuidString {
			centralRole.disconnectAndStopScanning()
		}
		// The lower identity keeps its central link; the peer drops its own.
	}

	private func refreshState() {
		guard isRunning else {
			state = .idle
			return
		}
		if centralRole.isLinkUp || peripheralRole.isLinkUp {
			state = .connected
		} else if centralRole.isConnecting {
			state = .connecting
		} else {
			state = .searching
		}
	}

	private func handleLinkChange() {
		let wasConnected = state == .connected
		refreshState()

		if state == .connected && !wasConnected {
			// Announce ourselves so the peer can name us and run the tiebreak.
			sendControl(.hello(identity: identity, name: localName))
		}
		if state != .connected {
			peerIdentity = nil
			peerName = nil
			centralRole.resumeScanning()
		}
	}

	private func handleControl(_ message: ControlMessage) {
		if case .hello(let peer, let name) = message {
			peerIdentity = peer
			peerName = name
			resolveCrossedConnection()
			refreshState()
		}
		delegate?.transport(self, didReceiveControl: message)
	}
}

extension BLETransport: BLEPeripheralRoleDelegate {
	func peripheralRoleDidChangeLink(_ role: BLEPeripheralRole) {
		handleLinkChange()
	}

	func peripheralRole(_ role: BLEPeripheralRole, didReceiveAudio packet: Packet, arrivalTime: Double) {
		delegate?.transport(self, didReceiveAudio: packet, arrivalTime: arrivalTime)
	}

	func peripheralRole(_ role: BLEPeripheralRole, didReceiveControl message: ControlMessage) {
		handleControl(message)
	}
}

extension BLETransport: BLECentralRoleDelegate {
	func centralRoleDidChangeLink(_ role: BLECentralRole) {
		handleLinkChange()
	}

	func centralRole(_ role: BLECentralRole, didReceiveAudio packet: Packet, arrivalTime: Double) {
		delegate?.transport(self, didReceiveAudio: packet, arrivalTime: arrivalTime)
	}

	func centralRole(_ role: BLECentralRole, didReceiveControl message: ControlMessage) {
		handleControl(message)
	}
}
