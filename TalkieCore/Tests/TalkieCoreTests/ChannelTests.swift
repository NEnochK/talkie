import Foundation
import Testing

@testable import TalkieCore

@Suite("Channels")
struct ChannelTests {
	@Test("Derives the same UUID for the same name")
	func deterministic() throws {
		let first = try #require(Channel(name: "crew"))
		let second = try #require(Channel(name: "crew"))
		#expect(first.serviceUUID == second.serviceUUID)
	}

	@Test("Derives different UUIDs for different names")
	func distinct() throws {
		let kitchen = try #require(Channel(name: "kitchen"))
		let garage = try #require(Channel(name: "garage"))
		#expect(kitchen.serviceUUID != garage.serviceUUID)
	}

	@Test("Treats case, padding and repeated spaces as the same channel", arguments: [
		"crew", "Crew", "CREW", "  crew  ", "crew\n",
	])
	func normalizationVariants(name: String) throws {
		let canonical = try #require(Channel(name: "crew"))
		let variant = try #require(Channel(name: name))
		#expect(variant.serviceUUID == canonical.serviceUUID)
	}

	@Test("Collapses runs of internal whitespace")
	func internalWhitespace() throws {
		let single = try #require(Channel(name: "my crew"))
		let double = try #require(Channel(name: "my  crew"))
		let tabbed = try #require(Channel(name: "my\tcrew"))
		#expect(double.serviceUUID == single.serviceUUID)
		#expect(tabbed.serviceUUID == single.serviceUUID)
	}

	@Test("Matches across Unicode composition forms")
	func unicodeNormalization() throws {
		// "café" precomposed vs. "cafe" + combining acute.
		let precomposed = try #require(Channel(name: "caf\u{00E9}"))
		let decomposed = try #require(Channel(name: "cafe\u{0301}"))
		#expect(decomposed.serviceUUID == precomposed.serviceUUID)
	}

	@Test("Keeps the typed name for display")
	func preservesDisplayName() throws {
		let channel = try #require(Channel(name: "  My Crew  "))
		#expect(channel.name == "My Crew", "display name should be trimmed but not folded")
		#expect(channel.normalizedName == "my crew")
	}

	@Test("Rejects an empty or whitespace-only name", arguments: ["", "   ", "\n\t"])
	func rejectsEmpty(name: String) {
		#expect(Channel(name: name) == nil)
	}

	@Test("Rejects a name past the length cap")
	func rejectsOverlongName() throws {
		let atCap = String(repeating: "a", count: Channel.maxNameLength)
		let overCap = String(repeating: "a", count: Channel.maxNameLength + 1)
		#expect(Channel(name: atCap) != nil)
		#expect(Channel(name: overCap) == nil, "truncating would derive a different room on each device")
	}

	@Test("Produces a well-formed RFC 9562 version 8 UUID")
	func uuidIsWellFormed() throws {
		let channel = try #require(Channel(name: "crew"))
		let bytes = withUnsafeBytes(of: channel.serviceUUID.uuid) { Array($0) }
		#expect(bytes[6] >> 4 == 0x8, "expected version 8 (custom)")
		#expect(bytes[8] >> 6 == 0b10, "expected RFC 4122 variant")
	}

	@Test("Does not collide with the derivation namespace")
	func differsFromNamespace() throws {
		let channel = try #require(Channel(name: "crew"))
		#expect(channel.serviceUUID != Channel.namespace)
	}

	@Test("Round-trips through a share URL")
	func shareURLRoundTrip() throws {
		let original = try #require(Channel(name: "My Crew"))
		let restored = try #require(Channel(url: original.shareURL))
		#expect(restored.serviceUUID == original.serviceUUID)
		#expect(restored.name == original.name)
	}

	@Test("Percent-encodes names that need it")
	func shareURLEncoding() throws {
		let original = try #require(Channel(name: "crew & co"))
		let url = original.shareURL
		#expect(url.scheme == Channel.urlScheme)
		let restored = try #require(Channel(url: url))
		#expect(restored.serviceUUID == original.serviceUUID)
	}

	@Test("Rejects URLs that are not channel links", arguments: [
		"https://example.com/join?c=crew",
		"talkie://join",
		"talkie://join?x=crew",
		"talkie://join?c=",
	])
	func rejectsBadURLs(raw: String) throws {
		let url = try #require(URL(string: raw))
		#expect(Channel(url: url) == nil)
	}

	@Test("Accepts a link whose scheme is capitalised")
	func schemeIsCaseInsensitive() throws {
		let url = try #require(URL(string: "TALKIE://join?c=crew"))
		let channel = try #require(Channel(url: url))
		#expect(channel.serviceUUID == Channel(name: "crew")?.serviceUUID)
	}

	@Test("Ships a usable default channel")
	func defaultChannel() {
		#expect(Channel.general.name == "General")
	}
}
