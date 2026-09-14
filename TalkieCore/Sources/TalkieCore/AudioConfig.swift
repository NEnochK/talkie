import Foundation

/// Fixed audio parameters for the whole app.
///
/// These are not tunable at runtime on purpose: the AirPods mic path is capped at
/// 16 kHz mono by HFP, and Opus wideband at 20 ms frames is the matching operating
/// point. Both peers must agree, and there is no negotiation in the protocol.
public enum AudioConfig {
	/// Hard ceiling imposed by the AirPods HFP input device.
	public static let sampleRate: Int = 16_000
	public static let channels: Int = 1

	public static let frameDuration: Double = 0.020
	/// 16000 Hz * 20 ms.
	public static let samplesPerFrame: Int = 320
	/// Frames emitted (and consumed) per second.
	public static let framesPerSecond: Int = 50

	public static let bitrate: Int = 20_000
	/// Tells the encoder how much loss to plan FEC around.
	public static let expectedPacketLossPercent: Int = 10

	/// Generous upper bound for one encoded frame; real frames run ~50 bytes.
	public static let maxEncodedFrameBytes: Int = 256
}
