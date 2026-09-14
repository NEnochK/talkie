import CryptoKit
import Foundation

/// A named room. Two devices talk only if they derived the same channel.
///
/// The name is hashed into the BLE **service UUID** rather than carried in the
/// advertisement payload, and that is not a stylistic choice: iOS strips
/// manufacturer data, service data and the local name as soon as the app
/// backgrounds, leaving only service UUIDs (in the overflow area). A channel ID in
/// the payload would work in the foreground and silently stop working the moment
/// the screen locked.
///
/// Encoding it in the UUID also makes channels unlisted — a scanner has to already
/// know the name to look for it, because `scanForPeripherals` is given the exact
/// UUID to match.
public struct Channel: Hashable, Sendable, Identifiable {
	/// Fixed namespace so the same name always derives the same UUID, on every
	/// device and every build.
	public static let namespace = UUID(uuidString: "873C6B88-66C4-4D96-8893-B4971BAF310C")!

	public static let maxNameLength = 32
	public static let urlScheme = "talkie"

	/// Used until someone picks something else.
	public static let general = Channel(name: "General")!

	/// Exactly as the user typed it, for display.
	public let name: String
	/// What the UUID is actually derived from.
	public let normalizedName: String
	public let serviceUUID: UUID

	public var id: UUID { serviceUUID }

	/// Returns nil for a name that is empty once normalized, or longer than
	/// `maxNameLength`. Length is rejected rather than truncated: silently
	/// shortening on one device and not another would derive two different
	/// channels that look identical in the UI.
	public init?(name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.count <= Self.maxNameLength else { return nil }

		let normalized = Self.normalize(trimmed)
		guard !normalized.isEmpty else { return nil }

		self.name = trimmed
		self.normalizedName = normalized
		self.serviceUUID = Self.deriveUUID(from: normalized)
	}

	/// Case- and whitespace-insensitive, and Unicode-normalized, so "My Crew",
	/// "my  crew" and a decomposed-accent variant all reach the same room.
	public static func normalize(_ name: String) -> String {
		let folded = name
			.precomposedStringWithCanonicalMapping
			.lowercased()
		let parts = folded.split(whereSeparator: { $0.isWhitespace })
		return parts.joined(separator: " ")
	}

	/// SHA-256 over the namespace bytes plus the normalized name, shaped into a
	/// well-formed UUID. Version 8 is RFC 9562's "custom" form, which is what a
	/// hash-derived identifier like this actually is.
	static func deriveUUID(from normalizedName: String) -> UUID {
		var input = Data()
		withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
		input.append(contentsOf: Array(normalizedName.utf8))

		var digest = Array(SHA256.hash(data: input).prefix(16))
		digest[6] = (digest[6] & 0x0F) | 0x80
		digest[8] = (digest[8] & 0x3F) | 0x80

		return UUID(uuid: (
			digest[0], digest[1], digest[2], digest[3],
			digest[4], digest[5], digest[6], digest[7],
			digest[8], digest[9], digest[10], digest[11],
			digest[12], digest[13], digest[14], digest[15]))
	}

	// MARK: - Sharing

	/// `talkie://join?c=<name>`. Registered as a URL scheme, so the system Camera
	/// app can open one of these straight into the app.
	public var shareURL: URL {
		var components = URLComponents()
		components.scheme = Self.urlScheme
		components.host = "join"
		components.queryItems = [URLQueryItem(name: "c", value: name)]
		// The components above are always well formed.
		return components.url!
	}

	public init?(url: URL) {
		guard url.scheme?.lowercased() == Self.urlScheme,
		      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      let name = components.queryItems?.first(where: { $0.name == "c" })?.value
		else { return nil }
		self.init(name: name)
	}
}
