import CoreBluetooth
import Foundation
import QuartzCore
import TalkieCore

protocol BLEPeripheralRoleDelegate: AnyObject {
	func peripheralRoleDidChangeLink(_ role: BLEPeripheralRole)
	func peripheralRole(_ role: BLEPeripheralRole, didReceiveAudio packet: Packet, arrivalTime: Double)
	func peripheralRole(_ role: BLEPeripheralRole, didReceiveControl message: ControlMessage)
}

/// The GATT server half. Publishes the service, advertises it, and talks to
/// whichever central subscribes.
///
/// Background behaviour worth knowing: once the app is backgrounded iOS stops
/// advertising the local name and moves the service UUID into the advertisement's
/// "overflow" area, which only an iOS device explicitly scanning for that exact
/// UUID can see. Both ends of Talkie do exactly that, so discovery still works —
/// but it is why no identifying data is carried in the advertisement, and why the
/// peer's name arrives later over the control characteristic instead.
final class BLEPeripheralRole: NSObject {
	weak var delegate: BLEPeripheralRoleDelegate?

	private let queue: DispatchQueue
	private let serviceUUID: CBUUID
	private var manager: CBPeripheralManager?

	private var audioDownlink: CBMutableCharacteristic?
	private var control: CBMutableCharacteristic?

	private var subscribedCentral: CBCentral?
	private var serviceAdded = false
	/// Control messages that hit backpressure. Unlike audio these must not be lost.
	private var pendingControl: [Data] = []

	private(set) var droppedAudioFrames = 0

	/// True once a central has subscribed to the audio downlink.
	var isLinkUp: Bool { subscribedCentral != nil }

	/// Largest notification the subscribed central will accept.
	var maximumPayloadLength: Int {
		subscribedCentral?.maximumUpdateValueLength ?? BLEConstants.fallbackWriteLength
	}

	init(queue: DispatchQueue, serviceUUID: CBUUID) {
		self.queue = queue
		self.serviceUUID = serviceUUID
		super.init()
	}

	func start() {
		guard manager == nil else { return }
		manager = CBPeripheralManager(delegate: self, queue: queue)
	}

	func stop() {
		manager?.stopAdvertising()
		manager?.removeAllServices()
		manager = nil
		subscribedCentral = nil
		serviceAdded = false
		pendingControl.removeAll()
	}

	@discardableResult
	func sendAudio(_ data: Data) -> Bool {
		guard let manager, let audioDownlink, subscribedCentral != nil else {
			droppedAudioFrames += 1
			return false
		}
		// Never queue audio behind backpressure. A frame that arrives late is worse
		// than one the receiver conceals, so drop it and keep the clock moving.
		let sent = manager.updateValue(data, for: audioDownlink, onSubscribedCentrals: nil)
		if !sent { droppedAudioFrames += 1 }
		return sent
	}

	func sendControl(_ data: Data) {
		guard let manager, let control, subscribedCentral != nil else { return }
		if !manager.updateValue(data, for: control, onSubscribedCentrals: nil) {
			pendingControl.append(data)
		}
	}

	private func buildService() -> CBMutableService {
		let readPermissions: CBAttributePermissions =
			BLEConstants.requireEncryption ? .readEncryptionRequired : .readable
		let writePermissions: CBAttributePermissions =
			BLEConstants.requireEncryption ? .writeEncryptionRequired : .writeable

		let downlink = CBMutableCharacteristic(
			type: BLEConstants.audioDownlinkUUID,
			properties: [.notify],
			value: nil,
			permissions: readPermissions)

		let uplink = CBMutableCharacteristic(
			type: BLEConstants.audioUplinkUUID,
			properties: [.writeWithoutResponse],
			value: nil,
			permissions: writePermissions)

		let controlCharacteristic = CBMutableCharacteristic(
			type: BLEConstants.controlUUID,
			properties: [.write, .notify],
			value: nil,
			permissions: [readPermissions, writePermissions])

		audioDownlink = downlink
		control = controlCharacteristic

		let service = CBMutableService(type: serviceUUID, primary: true)
		service.characteristics = [downlink, uplink, controlCharacteristic]
		return service
	}

	private func startAdvertising() {
		// Service UUIDs only. Anything else is dropped the moment we background.
		manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
	}
}

extension BLEPeripheralRole: CBPeripheralManagerDelegate {
	func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
		guard peripheral.state == .poweredOn else {
			subscribedCentral = nil
			serviceAdded = false
			delegate?.peripheralRoleDidChangeLink(self)
			return
		}
		guard !serviceAdded else { return }
		peripheral.add(buildService())
	}

	func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
		guard error == nil else { return }
		serviceAdded = true
		startAdvertising()
	}

	func peripheralManager(
		_ peripheral: CBPeripheralManager,
		central: CBCentral,
		didSubscribeTo characteristic: CBCharacteristic
	) {
		guard characteristic.uuid == BLEConstants.audioDownlinkUUID else { return }
		subscribedCentral = central
		delegate?.peripheralRoleDidChangeLink(self)
	}

	func peripheralManager(
		_ peripheral: CBPeripheralManager,
		central: CBCentral,
		didUnsubscribeFrom characteristic: CBCharacteristic
	) {
		guard characteristic.uuid == BLEConstants.audioDownlinkUUID else { return }
		subscribedCentral = nil
		delegate?.peripheralRoleDidChangeLink(self)
	}

	func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
		let arrival = CACurrentMediaTime()
		for request in requests {
			guard let value = request.value, let packet = try? Packet.decode(value) else { continue }
			switch packet.type {
			case .audio:
				delegate?.peripheralRole(self, didReceiveAudio: packet, arrivalTime: arrival)
			case .control:
				guard let message = try? ControlMessage.decode(packet.payload) else { continue }
				delegate?.peripheralRole(self, didReceiveControl: message)
			}
		}
		// Core Bluetooth expects exactly one response per batch of requests.
		if let first = requests.first {
			peripheral.respond(to: first, withResult: .success)
		}
	}

	func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
		guard let control else { return }
		while let next = pendingControl.first {
			guard peripheral.updateValue(next, for: control, onSubscribedCentrals: nil) else { return }
			pendingControl.removeFirst()
		}
	}
}
