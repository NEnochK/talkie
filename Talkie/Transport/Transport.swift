import Foundation
import TalkieCore

enum TransportState: Equatable {
	case idle
	/// Advertising and scanning, no peer yet.
	case searching
	case connecting
	case connected
}

protocol TransportDelegate: AnyObject {
	func transportDidChangeState(_ transport: any Transport)
	func transport(_ transport: any Transport, didReceiveAudio packet: Packet, arrivalTime: Double)
	func transport(_ transport: any Transport, didReceiveControl message: ControlMessage)
}

/// A duplex link to exactly one peer.
///
/// Every delegate callback is delivered on `queue`, and every method must be
/// called on it. That single serial queue is also where the jitter buffer and
/// decode pump live, which is what lets those stay lock-free.
protocol Transport: AnyObject {
	var delegate: TransportDelegate? { get set }
	var state: TransportState { get }
	var queue: DispatchQueue { get }

	/// Frames the link could not accept and deliberately discarded. Audio is
	/// never queued behind backpressure: a late frame is worse than a concealed one.
	var droppedAudioFrames: Int { get }

	func start()
	func stop()

	/// Unreliable and unordered. Returns false when the frame was dropped.
	@discardableResult
	func sendAudio(_ packet: Packet) -> Bool

	/// Reliable and ordered.
	func sendControl(_ message: ControlMessage)
}
