import XCTest
@testable import AgentringCore

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RelayAPITests: XCTestCase {
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(bytes, count: count)
            }
            data = collected
        }
        return try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as! [String: Any]
    }

    private func api() throws -> RelayAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return try RelayAPI(url: "https://relay.test", jwt: "device-jwt", session: URLSession(configuration: config))
    }

    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func testCallButtonsRequestDistinctModesAndPreserveReturnedMode() async throws {
        var requested: [String] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/calls")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
            let body = try Self.body(request)
            let mode = try XCTUnwrap(body["voice_mode"] as? String)
            requested.append(mode)
            let response: [String: Any] = [
                "call": ["call_id": "call_test", "direction": "user_to_agent", "state": "ringing",
                         "agent_name": "Test", "created_at": 1, "voice_mode": mode],
                "join": ["livekit_url": "wss://lk.test", "livekit_token": "test-token", "expires_at": 2]
            ]
            return (201, try JSONSerialization.data(withJSONObject: response))
        }
        let api = try api()
        let agent = try await api.startCall(to: .agent)
        let direct = try await api.startCall(to: .mrVedsil)
        XCTAssertEqual(requested, ["elevenlabs", "openclaw_direct"])
        XCTAssertEqual(agent.call.voiceMode, "elevenlabs")
        XCTAssertEqual(direct.call.voiceMode, "openclaw_direct")
    }

    func testAuthenticatedRegistrationPreservesExplicitNullAndEnvironment() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://relay.test/v1/device/apns")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
            // URLSession may move the body to a stream before URLProtocol receives it.
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                var collected = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; collected.append(bytes, count: count) }
                data = collected
            }
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as! [String: Any]
            XCTAssertEqual(body["environment"] as? String, "sandbox")
            XCTAssertTrue(body["voip_token"] is NSNull)
            XCTAssertNil(body["apns_token"])
            return (204, Data())
        }
        _ = try await api().request("/v1/device/apns", method: "POST", body: ["environment": "sandbox", "voip_token": NSNull()])
    }

    func testRevokedDeviceErrorIsActionable() async throws {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"code":"unauthorized","message":"Device revoked"}}"#.utf8)) }
        do { _ = try await api().request("/v1/status"); XCTFail("Expected revoked credentials to fail") }
        catch let error as RelayAPIError { XCTAssertEqual(error.status, 401); XCTAssertEqual(error.localizedDescription, "Device revoked") }
    }
}
