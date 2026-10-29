import XCTest
@testable import AgentringCore

final class CallerIdentityTests: XCTestCase {
    func testContactSelectionRequiresAMatchableIdentity() throws {
        XCTAssertNil(CallerIdentity(kind: .email, address: " \n", displayName: "Agent", contactIdentifier: "contact"))
        XCTAssertNil(CallerIdentity(kind: .phone, address: "+34 600 000 000", displayName: "Agent", contactIdentifier: ""))
        let identity = try XCTUnwrap(CallerIdentity(kind: .email, address: " agent@example.test \n",
                                                   displayName: " My agent ", contactIdentifier: "contact"))
        XCTAssertEqual(identity.address, "agent@example.test")
        XCTAssertEqual(identity.displayName, "My agent")
        XCTAssertEqual(CallerIdentity(kind: .phone, address: "+34 600 000 000", displayName: "",
                                      contactIdentifier: "contact")?.displayName, "+34 600 000 000")
    }

    func testChoicePersistsForOneRelayAndCanBeRemoved() throws {
        let suite = "agentring.caller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(CallerIdentity(kind: .email, address: "agent@example.test",
                                                   displayName: "Agent", contactIdentifier: "contact"))
        CallerIdentityPreferences.save(identity, relayId: "relay_one", defaults: defaults)
        XCTAssertEqual(CallerIdentityPreferences.load(relayId: "relay_one", defaults: defaults), identity)
        XCTAssertNil(CallerIdentityPreferences.load(relayId: "relay_two", defaults: defaults))
        CallerIdentityPreferences.save(nil, relayId: "relay_one", defaults: defaults)
        XCTAssertNil(CallerIdentityPreferences.load(relayId: "relay_one", defaults: defaults))
    }

    func testCorruptOrEmptySavedIdentityFallsBackToDefaultCaller() throws {
        let suite = "agentring.caller-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for data in [Data("invalid".utf8), Data(#"{"kind":"email","address":"","displayName":"Agent","contactIdentifier":"contact"}"#.utf8)] {
            defaults.set(data, forKey: "agentring.caller-contact.relay")
            XCTAssertNil(CallerIdentityPreferences.load(relayId: "relay", defaults: defaults))
        }
    }
}
