import AVFoundation
import Foundation
import TalkieCore

enum AudioEngineError: Error {
	case noInputAvailable
	case converterUnavailable
}

/// Capture and playback for one call.
///
/// Capture: microphone -> `AVAudioConverter` -> 16 kHz mono Int16 -> exact 20 ms
/// frames handed to `onCapturedFrame`.
///
/// Playback: an `AVAudioSourceNode` pulls from a lock-free ring that the decode
/// pump fills. The render block runs on a realtime thread, so it never allocates,
/// locks, or calls back into Swift machinery — it reads the ring into a
/// preallocated scratch buffer and converts to float in place.
final class AudioEngineController {
	/// One 20 ms frame of 16 kHz mono PCM. Called on the audio capture thread,
	/// **not** the transport queue — the caller is responsible for hopping.
	var onCapturedFrame: (([Int16]) -> Void)?

	private let engine = AVAudioEngine()
	private let playbackRing: PCMRingBuffer
	private let scratch: UnsafeMutableBufferPointer<Int16>

	private var sourceNode: AVAudioSourceNode?
	private var converter: AVAudioConverter?
	private var captureAccumulator: [Int16] = []

	private(set) var isRunning = false

	/// Largest render request we will service without truncating. Comfortably above
	/// the ~320 frames a 20 ms buffer asks for.
	private static let maxRenderFrames = 4096

	/// Roughly 500 ms of slack, well beyond the jitter buffer's 160 ms ceiling.
	private static let ringCapacity = 8192

	private let playbackFormat = AVAudioFormat(
		commonFormat: .pcmFormatFloat32,
		sampleRate: Double(AudioConfig.sampleRate),
		channels: AVAudioChannelCount(AudioConfig.channels),
		interleaved: false)!

	private let captureFormat = AVAudioFormat(
		commonFormat: .pcmFormatInt16,
		sampleRate: Double(AudioConfig.sampleRate),
		channels: AVAudioChannelCount(AudioConfig.channels),
		interleaved: true)!

	init() {
		playbackRing = PCMRingBuffer(capacitySamples: Self.ringCapacity)
		scratch = UnsafeMutableBufferPointer<Int16>.allocate(capacity: Self.maxRenderFrames)
		scratch.initialize(repeating: 0)
		captureAccumulator.reserveCapacity(AudioConfig.samplesPerFrame * 4)
	}

	deinit {
		scratch.deallocate()
	}

	/// Samples underrun so far, i.e. render requests the decode pump could not
	/// keep up with. A few at call start are normal; a rising count is not.
	private(set) var underrunFrames = 0

	func start() throws {
		guard !isRunning else { return }

		let input = engine.inputNode
		// Must happen before the graph is built, or `.voiceChat` silently gives us
		// no echo cancellation and no automatic gain control.
		try input.setVoiceProcessingEnabled(true)
		try engine.outputNode.setVoiceProcessingEnabled(true)

		let inputFormat = input.outputFormat(forBus: 0)
		guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
			throw AudioEngineError.noInputAvailable
		}
		guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
			throw AudioEngineError.converterUnavailable
		}
		self.converter = converter

		let source = makeSourceNode()
		engine.attach(source)
		engine.connect(source, to: engine.mainMixerNode, format: playbackFormat)
		sourceNode = source

		input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
			self?.handleCapturedBuffer(buffer)
		}

		engine.prepare()
		try engine.start()
		isRunning = true
	}

	func stop() {
		guard isRunning else { return }
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		if let sourceNode {
			engine.detach(sourceNode)
			self.sourceNode = nil
		}
		converter = nil
		captureAccumulator.removeAll(keepingCapacity: true)
		playbackRing.reset()
		isRunning = false
	}

	/// Rebuilds the graph after a route change, where the input format may differ.
	func restart() throws {
		stop()
		try start()
	}

	/// Hands decoded PCM to the speaker. Called from the decode pump.
	func enqueueForPlayback(_ samples: [Int16]) {
		playbackRing.write(samples)
	}

	func flushPlayback() {
		playbackRing.reset()
	}

	/// How much decoded audio is waiting to be rendered. The decode pump watches
	/// this so a timer running slightly fast cannot inflate latency indefinitely.
	var playbackBufferedSamples: Int { playbackRing.availableToRead }

	private func makeSourceNode() -> AVAudioSourceNode {
		let ring = playbackRing
		let scratch = self.scratch

		return AVAudioSourceNode(format: playbackFormat) { _, _, frameCount, audioBufferList in
			let requested = Int(frameCount)
			let frames = min(requested, scratch.count)

			// `read` zero-fills whatever the decode pump has not supplied yet, so an
			// underrun renders silence rather than stale audio.
			let window = UnsafeMutableBufferPointer(rebasing: scratch[0..<frames])
			ring.read(into: window)

			let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
			for buffer in buffers {
				guard let output = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
				for index in 0..<frames {
					output[index] = Float(window[index]) / 32768
				}
				if requested > frames {
					for index in frames..<requested { output[index] = 0 }
				}
			}
			return noErr
		}
	}

	private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
		guard let converter else { return }

		let ratio = captureFormat.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
		guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

		var alreadySupplied = false
		var conversionError: NSError?
		converter.convert(to: output, error: &conversionError) { _, status in
			// The converter may ask more than once per output buffer; feed the input
			// exactly once and then report starvation.
			if alreadySupplied {
				status.pointee = .noDataNow
				return nil
			}
			alreadySupplied = true
			status.pointee = .haveData
			return buffer
		}

		guard conversionError == nil,
		      let channels = output.int16ChannelData,
		      output.frameLength > 0 else { return }

		let converted = UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength))
		emitFrames(from: converted)
	}

	/// Slices the converted stream into exactly-20 ms frames. Opus will not encode
	/// anything else, and the tap's buffer size has no relationship to our frame size.
	private func emitFrames(from samples: UnsafeBufferPointer<Int16>) {
		captureAccumulator.append(contentsOf: samples)

		let frameSize = AudioConfig.samplesPerFrame
		var offset = 0
		while captureAccumulator.count - offset >= frameSize {
			let frame = Array(captureAccumulator[offset..<(offset + frameSize)])
			offset += frameSize
			onCapturedFrame?(frame)
		}
		if offset > 0 {
			captureAccumulator.removeFirst(offset)
		}
	}
}
