import Testing

@testable import TalkieCore

@Suite("PCM ring buffer")
struct PCMRingBufferTests {
	private func read(_ ring: PCMRingBuffer, count: Int) -> (samples: [Int16], real: Int) {
		var out = [Int16](repeating: -1, count: count)
		let real = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
		return (out, real)
	}

	@Test("Rounds capacity up to a power of two")
	func capacityRounding() {
		#expect(PCMRingBuffer(capacitySamples: 100).capacitySamples == 128)
		#expect(PCMRingBuffer(capacitySamples: 512).capacitySamples == 512)
		#expect(PCMRingBuffer(capacitySamples: 1).capacitySamples == 1)
	}

	@Test("Reads back exactly what was written")
	func basicRoundTrip() {
		let ring = PCMRingBuffer(capacitySamples: 64)
		let input: [Int16] = [1, 2, 3, 4, 5]

		#expect(ring.write(input) == 5)
		#expect(ring.availableToRead == 5)

		let (samples, real) = read(ring, count: 5)
		#expect(real == 5)
		#expect(samples == input)
		#expect(ring.availableToRead == 0)
	}

	@Test("Zero-fills the shortfall on underrun")
	func underrunProducesSilence() {
		let ring = PCMRingBuffer(capacitySamples: 64)
		ring.write([7, 7, 7])

		let (samples, real) = read(ring, count: 6)

		#expect(real == 3)
		#expect(samples == [7, 7, 7, 0, 0, 0])
	}

	@Test("Reading an empty buffer yields pure silence")
	func emptyIsSilence() {
		let ring = PCMRingBuffer(capacitySamples: 64)
		let (samples, real) = read(ring, count: 4)
		#expect(real == 0)
		#expect(samples == [0, 0, 0, 0])
	}

	@Test("Refuses to overwrite unread samples")
	func writeIsBoundedByCapacity() {
		let ring = PCMRingBuffer(capacitySamples: 8)
		#expect(ring.write([Int16](repeating: 1, count: 8)) == 8)
		// Full: the next write must drop everything rather than clobber.
		#expect(ring.write([9, 9]) == 0)

		let (samples, _) = read(ring, count: 8)
		#expect(samples.allSatisfy { $0 == 1 })
	}

	@Test("Stays correct across the wrap point")
	func wrapAround() {
		let ring = PCMRingBuffer(capacitySamples: 8)

		// Advance the cursors close to the end so the next write straddles the wrap.
		ring.write([Int16](repeating: 5, count: 6))
		_ = read(ring, count: 6)

		let payload: [Int16] = [10, 20, 30, 40, 50]
		#expect(ring.write(payload) == 5)

		let (samples, real) = read(ring, count: 5)
		#expect(real == 5)
		#expect(samples == payload)
	}

	@Test("reset() discards everything buffered")
	func resetDiscards() {
		let ring = PCMRingBuffer(capacitySamples: 16)
		ring.write([1, 2, 3, 4])
		ring.reset()

		#expect(ring.availableToRead == 0)
		let (samples, real) = read(ring, count: 2)
		#expect(real == 0)
		#expect(samples == [0, 0])
	}

	@Test("Never reorders or duplicates samples across threads")
	func concurrentProducerConsumer() async {
		let ring = PCMRingBuffer(capacitySamples: 4096)
		let totalFrames = 100
		let frameSize = 320

		// The producer writes a strictly increasing counter. Under overrun the ring
		// drops the tail of a write by design, so the consumer may see *gaps* -- what
		// it must never see is a sample out of order or repeated. Values stay under
		// Int16.max so the comparison does not have to reason about wrapping.
		async let producer: Int = {
			var written = 0
			var next: Int16 = 0
			for _ in 0..<totalFrames {
				var frame = [Int16](repeating: 0, count: frameSize)
				for index in 0..<frameSize {
					frame[index] = next
					next += 1
				}
				written += ring.write(frame)
				await Task.yield()
			}
			return written
		}()

		async let consumed: (ordered: Bool, count: Int) = {
			var previous: Int16?
			var seen = 0
			var idleSpins = 0
			var scratch = [Int16](repeating: 0, count: frameSize)

			while idleSpins < 10_000 {
				let real = scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
				if real == 0 {
					idleSpins += 1
					await Task.yield()
					continue
				}
				idleSpins = 0
				for index in 0..<real {
					if let previous, scratch[index] <= previous {
						return (false, seen)
					}
					previous = scratch[index]
				}
				seen += real
			}
			return (true, seen)
		}()

		let written = await producer
		let (ordered, count) = await consumed

		#expect(ordered, "samples came back out of order or duplicated")
		#expect(written > 0)
		#expect(count > 0, "consumer never observed any samples")
	}
}
