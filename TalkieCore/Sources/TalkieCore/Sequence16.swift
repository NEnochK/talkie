/// Signed distance between two wrapping 16-bit sequence numbers.
///
/// Returns how far `a` is ahead of `b`: positive if `a` is newer, negative if older.
/// Correct across the 65535 -> 0 wraparound as long as the two values are within
/// 32767 of each other, which at 50 frames/sec is about 10 minutes of drift.
@inlinable
public func seqDelta(_ a: UInt16, _ b: UInt16) -> Int {
	Int(Int16(bitPattern: a &- b))
}
