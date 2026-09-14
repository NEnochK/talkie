import Foundation
import TalkieCore

/// Everything the debug panel shows about link health.
struct LinkStats: Equatable {
	/// Round trip measured by the 1 Hz control ping.
	var roundTripMilliseconds: Double?
	/// Frames the receiver had to conceal or rebuild, as a percentage.
	var lossPercent: Double = 0
	/// Frames we discarded because the radio could not accept them.
	var transmitDrops: Int = 0
	/// Frames dropped because the playback ring was already full.
	var playbackDrops: Int = 0
	var concealed: Int = 0
	var fecRecovered: Int = 0
	var late: Int = 0
	var rebuffers: Int = 0
	var jitterBufferDepth: Int = 0
	var targetDepth: Int = JitterBuffer.minDepth

	mutating func apply(_ jitter: JitterBufferStats) {
		lossPercent = jitter.lossPercent
		concealed = jitter.concealed
		fecRecovered = jitter.fecRecovered
		late = jitter.late
		rebuffers = jitter.rebuffers
	}
}
