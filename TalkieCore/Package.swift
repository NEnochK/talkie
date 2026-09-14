// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "TalkieCore",
	platforms: [
		.iOS(.v18),
		.macOS(.v15),
	],
	products: [
		.library(name: "TalkieCore", targets: ["TalkieCore"]),
		.executable(name: "talkie-loopback", targets: ["TalkieLoopbackTool"]),
	],
	dependencies: [
		.package(url: "https://github.com/sbooth/opus-binary-xcframework", from: "0.3.0"),
		// Not used directly. The prebuilt opus.framework bundles opusfile and
		// libopusenc alongside core Opus, so its binary hard-links @rpath/ogg.framework
		// and will not load without it. Small, and the alternative is building
		// libopus from source.
		.package(url: "https://github.com/sbooth/ogg-binary-xcframework", from: "0.1.3"),
	],
	targets: [
		// Non-variadic wrappers around libopus, because Swift cannot call
		// `opus_encoder_ctl(enc, request, ...)` directly.
		.target(
			name: "COpusShim",
			dependencies: [
				.product(name: "opus", package: "opus-binary-xcframework"),
				.product(name: "ogg", package: "ogg-binary-xcframework"),
			],
			// The framework's module map also declares an `opusfile` submodule, which
			// includes <ogg/ogg.h>. We only use core Opus and libogg is not present, so
			// building the module fails. Textual includes sidestep the whole module.
			cSettings: [.unsafeFlags(["-fno-modules"])]),
		.target(
			name: "TalkieCore",
			dependencies: ["COpusShim"]),
		// Offline harness: runs real audio through the production codec and jitter
		// buffer with simulated loss and jitter, so the effect is measurable and
		// listenable without any hardware. Not shipped in the app.
		.target(
			name: "TalkieSimulation",
			dependencies: ["TalkieCore"]),
		.executableTarget(
			name: "TalkieLoopbackTool",
			dependencies: ["TalkieCore", "TalkieSimulation"]),
		.testTarget(
			name: "TalkieCoreTests",
			dependencies: ["TalkieCore", "TalkieSimulation"]),
	]
)
