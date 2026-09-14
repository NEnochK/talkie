import Foundation

/// The three ways a frame can reach the speaker.
///
/// `JitterBuffer` is written against this rather than against Opus directly, so
/// its reordering and loss logic can be tested with a stub that just records which
/// path was taken.
public protocol FrameDecoding: AnyObject {
	/// Normal path: decode a packet that arrived on time.
	func decode(_ payload: Data) throws -> [Int16]

	/// Packet-loss concealment for a frame that never arrived and cannot be
	/// recovered. Opus synthesises a plausible continuation.
	func conceal() throws -> [Int16]

	/// Whether `payload` actually carries an in-band FEC copy of the frame before
	/// it. Ask before calling `decodeFEC`: Opus returns a full frame either way,
	/// silently substituting plain concealment when no copy is present, so this is
	/// the only way to tell a real repair from ordinary loss.
	func packetCarriesFEC(_ payload: Data) -> Bool

	/// Reconstruct the *previous* frame from the in-band FEC copy carried inside
	/// `nextPayload`. Better than concealment, and costs nothing extra here because
	/// the buffer already holds a frame of lookahead.
	func decodeFEC(from nextPayload: Data) throws -> [Int16]
}
