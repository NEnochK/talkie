import Foundation
import Observation
import TalkieCore

/// Remembers the current channel and the handful most recently used.
///
/// Only names are persisted; the UUID is re-derived on load. Storing the derived
/// UUID would risk a stale value outliving a change to the derivation.
@MainActor
@Observable
final class ChannelStore {
	static let maxRecents = 8

	private(set) var current: Channel
	private(set) var recents: [Channel]

	private let defaults: UserDefaults
	private let currentKey = "com.talkie.channel.current"
	private let recentsKey = "com.talkie.channel.recents"

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults

		let storedCurrent = defaults.string(forKey: currentKey).flatMap(Channel.init(name:))
		current = storedCurrent ?? .general

		let storedRecents = defaults.stringArray(forKey: recentsKey) ?? []
		recents = storedRecents.compactMap(Channel.init(name:))
		if recents.isEmpty { recents = [current] }
	}

	func select(_ channel: Channel) {
		current = channel
		// Compare by identity, not display name, so "Crew" replaces "crew".
		recents.removeAll { $0.serviceUUID == channel.serviceUUID }
		recents.insert(channel, at: 0)
		if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
		persist()
	}

	func forget(_ channel: Channel) {
		guard channel.serviceUUID != current.serviceUUID else { return }
		recents.removeAll { $0.serviceUUID == channel.serviceUUID }
		persist()
	}

	private func persist() {
		defaults.set(current.name, forKey: currentKey)
		defaults.set(recents.map(\.name), forKey: recentsKey)
	}
}
