import Synchronization

/// Single-producer / single-consumer ring of 16-bit PCM samples.
///
/// The consumer is the `AVAudioSourceNode` render block, which runs on a realtime
/// thread: `read(into:)` must never allocate, lock, or block. Storage is allocated
/// once up front and the two cursors are plain atomics, so the read path is a
/// couple of atomic loads plus a memcpy.
///
/// Exactly one thread may call `write`, and exactly one (different) thread may call
/// `read`. Cursors are monotonic 64-bit counters, so they do not wrap in any
/// realistic runtime, and `write - read` is always the true fill level.
public final class PCMRingBuffer: @unchecked Sendable {
	private let storage: UnsafeMutablePointer<Int16>
	private let capacity: Int
	private let mask: Int

	private let writeIndex = Atomic<Int>(0)
	private let readIndex = Atomic<Int>(0)

	/// Capacity is rounded up to a power of two so the wrap is a mask, not a modulo.
	public init(capacitySamples: Int) {
		precondition(capacitySamples > 0, "capacity must be positive")
		var rounded = 1
		while rounded < capacitySamples { rounded <<= 1 }
		capacity = rounded
		mask = rounded - 1
		storage = UnsafeMutablePointer<Int16>.allocate(capacity: rounded)
		storage.initialize(repeating: 0, count: rounded)
	}

	deinit {
		storage.deinitialize(count: capacity)
		storage.deallocate()
	}

	public var capacitySamples: Int { capacity }

	public var availableToRead: Int {
		let write = writeIndex.load(ordering: .acquiring)
		let read = readIndex.load(ordering: .acquiring)
		return write - read
	}

	public var availableToWrite: Int { capacity - availableToRead }

	/// Producer side. Writes as much as fits and returns the count actually written;
	/// a short return means the consumer is behind and the tail was dropped.
	@discardableResult
	public func write(_ samples: UnsafeBufferPointer<Int16>) -> Int {
		guard let source = samples.baseAddress, !samples.isEmpty else { return 0 }

		let write = writeIndex.load(ordering: .relaxed)
		let read = readIndex.load(ordering: .acquiring)
		let free = capacity - (write - read)
		let count = min(samples.count, free)
		guard count > 0 else { return 0 }

		let offset = write & mask
		let firstChunk = min(count, capacity - offset)
		storage.advanced(by: offset).update(from: source, count: firstChunk)
		if count > firstChunk {
			storage.update(from: source.advanced(by: firstChunk), count: count - firstChunk)
		}

		// Release so the consumer sees the samples before it sees the new cursor.
		writeIndex.store(write + count, ordering: .releasing)
		return count
	}

	@discardableResult
	public func write(_ samples: [Int16]) -> Int {
		samples.withUnsafeBufferPointer { write($0) }
	}

	/// Consumer side, realtime-safe. Always fills `destination` completely: any
	/// shortfall is zero-filled, which is the underrun behaviour the audio graph
	/// wants. Returns the number of real samples delivered.
	@discardableResult
	public func read(into destination: UnsafeMutableBufferPointer<Int16>) -> Int {
		guard let target = destination.baseAddress, !destination.isEmpty else { return 0 }

		let read = readIndex.load(ordering: .relaxed)
		let write = writeIndex.load(ordering: .acquiring)
		let count = min(destination.count, write - read)

		if count > 0 {
			let offset = read & mask
			let firstChunk = min(count, capacity - offset)
			target.update(from: storage.advanced(by: offset), count: firstChunk)
			if count > firstChunk {
				target.advanced(by: firstChunk).update(from: storage, count: count - firstChunk)
			}
			readIndex.store(read + count, ordering: .releasing)
		}

		if count < destination.count {
			target.advanced(by: count).update(repeating: 0, count: destination.count - count)
		}
		return count
	}

	/// Drops everything buffered. Only safe when neither side is mid-call, e.g.
	/// between calls or on a route change.
	public func reset() {
		readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
	}
}
