import Foundation

/// Device-local contact matching for CallKit; never part of the relay protocol.
struct CallerIdentity: Codable, Equatable {
    enum Kind: String, Codable { case email, phone }

    let kind: Kind
    let address: String
    let displayName: String
    let contactIdentifier: String

    init?(kind: Kind, address: String, displayName: String, contactIdentifier: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !contactIdentifier.isEmpty else { return nil }
        self.kind = kind
        self.address = address
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.isEmpty ? address : name
        self.contactIdentifier = contactIdentifier
    }
}

enum CallerIdentityPreferences {
    private static func key(_ relayId: String) -> String { "agentring.caller-contact.\(relayId)" }

    static func load(relayId: String, defaults: UserDefaults = .standard) -> CallerIdentity? {
        guard let data = defaults.data(forKey: key(relayId)),
              let saved = try? JSONDecoder().decode(CallerIdentity.self, from: data) else { return nil }
        return CallerIdentity(kind: saved.kind, address: saved.address, displayName: saved.displayName,
                              contactIdentifier: saved.contactIdentifier)
    }

    static func save(_ identity: CallerIdentity?, relayId: String, defaults: UserDefaults = .standard) {
        guard let identity else { defaults.removeObject(forKey: key(relayId)); return }
        defaults.set(try? JSONEncoder().encode(identity), forKey: key(relayId))
    }
}
