import CoreBluetooth
import Foundation
import QuartzCore
import TalkieCore

protocol BLECentralRoleDelegate: AnyObject {
	func centralRoleDidChangeLink(_ role: BLECentralRole)
	func centralRole(_ role: BLECentralRole, didReceiveAudio packet: Packet, arrivalTime: Double)
	func centralRole(_ role: BLECentralRole, didReceiveControl message: ControlMessage)
}

/// The GATT client half. Scans for a peer advertising our service, connects, and
/// subscribes to its audio and control characteristics.
final class BLECentralRole: NSObject {
	weak var delegate: BLECentralRoleDelegate?

	private let queue: DispatchQueue
	private let serviceUUID: CBUUID
	private var manager: CBCentralManager?

	private var peer: CBPeripheral?
	private var audioUplink: CBCharacteristic?
	private var control: CBCharacteristic?
	private var notificationsReady = false

	private(set) var droppedAudioFrames = 0
	private(set) var isScanning = false

	/// True once the peer's characteristics are discovered and notifications are on.
	var isLinkUp: Bool { peer?.state == .connected && notificationsReady }

	var isConnecting: Bool { peer != nil && peer?.state != .connected }

	var maximumPayloadLength: Int {
		peer?.maximumWriteValueLength(for: .withoutResponse) ?? BLEConstants.fallbackWriteLength
	}

	init(queue: DispatchQueue, serviceUUID: CBUUID) {
		self.queue = queue
		self.serviceUUID = serviceUUID
		super.init()
	}

	func start() {
		guard manager == nil else { return }
		manager = CBCentralManager(delegate: self, queue: queue)
	}

	func stop() {
		if let peer { manager?.cancelPeripheralConnection(peer) }
		manager?.stopScan()
		isScanning = false
		manager = nil
		clearPeer()
	}

	/// Drops our outbound connection. Used when both devices connected to each
	/// other at once and this side lost the tiebreak.
	func disconnectAndStopScanning() {
		if let peer { manager?.cancelPeripheralConnection(peer) }
		manager?.stopScan()
		isScanning = false
		clearPeer()
	}

	func resumeScanning() {
		guard let manager, manager.state == .poweredOn, peer == nil, !isScanning else { return }
		isScanning = true
		// Explicit service UUID is required twice over: a backgrounded iOS peripheral
		// advertises its service only in the overflow area, which a wildcard scan
		// cannot see — and matching the exact per-channel UUID is what keeps other
		// channels invisible.
		manager.scanForPeripherals(withServices: [serviceUUID], options: nil)
	}

	@discardableResult
	func sendAudio(_ data: Data) -> Bool {
		guard let peer, let audioUplink, peer.state == .connected else {
			droppedAudioFrames += 1
			return false
		}
		// Same rule as the peripheral side: drop rather than queue.
		guard peer.canSendWriteWithoutResponse else {
			droppedAudioFrames += 1
			return false
		}
		peer.writeValue(data, for: audioUplink, type: .withoutResponse)
		return true
	}

	func sendControl(_ data: Data) {
		guard let peer, let control, peer.state == .connected else { return }
		peer.writeValue(data, for: control, type: .withResponse)
	}

	private func clearPeer() {
		peer = nil
		audioUplink = nil
		control = nil
		notificationsReady = false
	}
}

extension BLECentralRole: CBCentralManagerDelegate {
	func centralManagerDidUpdateState(_ central: CBCentralManager) {
		if central.state == .poweredOn {
			resumeScanning()
		} else {
			isScanning = false
			clearPeer()
			delegate?.centralRoleDidChangeLink(self)
		}
	}

	func centralManager(
		_ central: CBCentralManager,
		didDiscover peripheral: CBPeripheral,
		advertisementData: [String: Any],
		rssi RSSI: NSNumber
	) {
		guard peer == nil else { return }
		central.stopScan()
		isScanning = false
		peer = peripheral
		peripheral.delegate = self
		central.connect(peripheral, options: nil)
		delegate?.centralRoleDidChangeLink(self)
	}

	func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		peripheral.discoverServices([serviceUUID])
	}

	func centralManager(
		_ central: CBCentralManager,
		didFailToConnect peripheral: CBPeripheral,
		error: (any Error)?
	) {
		clearPeer()
		delegate?.centralRoleDidChangeLink(self)
		resumeScanning()
	}

	func centralManager(
		_ central: CBCentralManager,
		didDisconnectPeripheral peripheral: CBPeripheral,
		error: (any Error)?
	) {
		clearPeer()
		delegate?.centralRoleDidChangeLink(self)
		resumeScanning()
	}
}

extension BLECentralRole: CBPeripheralDelegate {
	func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
		guard error == nil, let service = peripheral.services?.first(where: {
			$0.uuid == serviceUUID
		}) else { return }

		peripheral.discoverCharacteristics(
			[BLEConstants.audioDownlinkUUID, BLEConstants.audioUplinkUUID, BLEConstants.controlUUID],
			for: service)
	}

	func peripheral(
		_ peripheral: CBPeripheral,
		didDiscoverCharacteristicsFor service: CBService,
		error: (any Error)?
	) {
		guard error == nil, let characteristics = service.characteristics else { return }
		for characteristic in characteristics {
			switch characteristic.uuid {
			case BLEConstants.audioUplinkUUID:
				audioUplink = characteristic
			case BLEConstants.controlUUID:
				control = characteristic
				peripheral.setNotifyValue(true, for: characteristic)
			case BLEConstants.audioDownlinkUUID:
				peripheral.setNotifyValue(true, for: characteristic)
			default:
				continue
			}
		}
	}

	func peripheral(
		_ peripheral: CBPeripheral,
		didUpdateNotificationStateFor characteristic: CBCharacteristic,
		error: (any Error)?
	) {
		guard characteristic.uuid == BLEConstants.audioDownlinkUUID else { return }
		notificationsReady = error == nil && characteristic.isNotifying
		delegate?.centralRoleDidChangeLink(self)
	}

	func peripheral(
		_ peripheral: CBPeripheral,
		didUpdateValueFor characteristic: CBCharacteristic,
		error: (any Error)?
	) {
		guard error == nil, let value = characteristic.value,
		      let packet = try? Packet.decode(value) else { return }

		switch packet.type {
		case .audio:
			delegate?.centralRole(self, didReceiveAudio: packet, arrivalTime: CACurrentMediaTime())
		case .control:
			guard let message = try? ControlMessage.decode(packet.payload) else { return }
			delegate?.centralRole(self, didReceiveControl: message)
		}
	}
}
