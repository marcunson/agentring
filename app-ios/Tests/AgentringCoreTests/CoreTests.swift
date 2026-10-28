import XCTest
@testable import AgentringCore

final class CoreTests: XCTestCase {
    private var protocolURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/examples")
    }

    func testEverySharedEventFixtureDecodes() throws {
        let directory = protocolURL.appendingPathComponent("events")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let event = try RelayJSON.decoder().decode(RelayEvent.self, from: Data(contentsOf: file))
            XCTAssertFalse(event.type.isEmpty, file.lastPathComponent)
            XCTAssertFalse(event.id.isEmpty, file.lastPathComponent)
        }
    }

    func testSharedSignatureVectorAndTampering() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: protocolURL.appendingPathComponent("push/signature-vector.json"))) as! [String: Any]
        var payload = object["data"] as! [String: String]
        let credentials = Credentials(relayUrl: "https://relay.test", deviceId: "dev", deviceJwt: "jwt",
            pushSecret: object["push_secret"] as! String, relayId: payload["relay_id"]!, agentName: "Agent")
        XCTAssertEqual(PushVerifier.verify(payload, credentials: credentials)?.text, "Build finished ✅")
        payload["event"] = payload["event"]! + " "
        XCTAssertNil(PushVerifier.verify(payload, credentials: credentials))
        payload = object["data"] as! [String: String]
        payload["relay_id"] = "another-relay"
        XCTAssertNil(PushVerifier.verify(payload, credentials: credentials))
        payload["sig"] = "!bad!"
        XCTAssertNil(PushVerifier.verify(payload, credentials: credentials))
    }

    func testTransportPolicy() throws {
        for value in ["https://relay.example.com", "http://192.168.1.4:8080", "http://100.100.1.1:8080", "http://localhost:8080"] {
            XCTAssertNoThrow(try RelayURLPolicy.validate(value), value)
        }
        for value in ["http://relay.example.com", "file:///tmp/x", "https://user:secret@relay.test", "http://192.168.1.999", "http://192.168.1.1.evil.com", "https://relay.test/path", "https://relay.test?token=x"] {
            XCTAssertThrowsError(try RelayURLPolicy.validate(value), value)
        }
        XCTAssertNoThrow(try RelayURLPolicy.validate("wss://relay.test", websocket: true))
        XCTAssertThrowsError(try RelayURLPolicy.validate("ws://relay.test", websocket: true))
    }

    func testCallIdentifiersAreStableAndDistinct() {
        XCTAssertEqual(PushVerifier.callUUID("call_1"), PushVerifier.callUUID("call_1"))
        XCTAssertNotEqual(PushVerifier.callUUID("call_1"), PushVerifier.callUUID("call_2"))
    }

    func testKeychainSnapshotRoundTripAndUnknownFields() throws {
        let value = Credentials(relayUrl: "https://relay.test", deviceId: "dev", deviceJwt: "jwt", pushSecret: "secret", relayId: "relay", agentName: "Agent")
        let roundTrip = try RelayJSON.decoder().decode(Credentials.self, from: RelayJSON.encoder().encode(value))
        XCTAssertEqual(roundTrip.deviceJwt, value.deviceJwt)
        let raw = #"{"device_id":"dev","device_jwt":"jwt","push_secret":"secret","relay_id":"relay","agent_name":"Agent","push_config":null,"future_field":true}"#
        let result = try RelayJSON.decoder().decode(PairResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(result.deviceId, "dev")
    }
}
