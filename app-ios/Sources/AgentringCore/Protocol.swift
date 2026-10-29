import Foundation
import CryptoKit

enum RelayJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

struct PairingQR: Decodable {
    let v: Int
    let relayUrl: String
    let pairingToken: String
}

struct Credentials: Codable {
    let relayUrl: String
    let deviceId: String
    let deviceJwt: String
    let pushSecret: String
    let relayId: String
    let agentName: String
}

struct PairResponse: Decodable {
    let deviceId: String
    let deviceJwt: String
    let pushSecret: String
    let relayId: String
    let agentName: String
}

struct Message: Codable, Identifiable, Equatable {
    let msgId: String
    let from: String
    let text: String
    let replyTo: String?
    let createdAt: Int64
    var id: String { msgId }
}

struct MessagePage: Decodable {
    let messages: [Message]
    let hasMore: Bool
}

struct RelayCall: Decodable {
    let callId: String
    let direction: String
    let state: String
    let reason: String?
    let agentName: String
    let voiceMode: String?
    let createdAt: Int64
    var isOpen: Bool { state == "ringing" || state == "active" }
}

enum CallDestination: String, CaseIterable {
    case agent = "elevenlabs"
    case mrVedsil = "openclaw_direct"

    var name: String { self == .agent ? "Agent" : "MrVedsil" }
    var buttonTitle: String { self == .agent ? "Call agent" : "Call MrVedsil" }
    var requestBody: [String: Any] { ["voice_mode": rawValue] }
}

struct JoinInfo: Decodable {
    let livekitUrl: String
    let livekitToken: String
    let expiresAt: Int64
}

struct CallWithJoin: Decodable {
    let call: RelayCall
    let join: JoinInfo
}

struct RelayStatus: Decodable {
    let agentName: String
    let agentOnline: Bool
    let pushProvider: String
    let activeCall: RelayCall?
}

/// Forward-compatible event envelope. New event types must not break replay.
struct RelayEvent: Decodable {
    let type: String
    let id: String
    let ts: Int64
    let seq: Int64?
    let callId: String?
    let direction: String?
    let agentName: String?
    let reason: String?
    let expiresAt: Int64?
    let msgId: String?
    let from: String?
    let text: String?
    let replyTo: String?
    let online: Bool?
    let by: String?
    let deviceId: String?
}

enum RelayValidationError: LocalizedError {
    case invalidURL, invalidQR
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTPS relay URL (HTTP is allowed only on a private network)."
        case .invalidQR: return "This is not a valid agentring pairing code."
        }
    }
}

enum RelayURLPolicy {
    static func validate(_ raw: String, websocket: Bool = false) throws -> URL {
        guard let components = URLComponents(string: raw), let url = components.url,
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw RelayValidationError.invalidURL }
        if components.scheme == (websocket ? "wss" : "https") { return url }
        guard components.scheme == (websocket ? "ws" : "http"), isPrivate(host) else { throw RelayValidationError.invalidURL }
        return url
    }

    static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
}

enum PushVerifier {
    static func verify(_ payload: [AnyHashable: Any], credentials: Credentials) -> RelayEvent? {
        guard payload["v"] as? String == "1", payload["relay_id"] as? String == credentials.relayId,
              let raw = payload["event"] as? String, let signature = payload["sig"] as? String,
              let key = decodeBase64URL(credentials.pushSecret), let mac = decodeBase64URL(signature),
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(raw.utf8), using: SymmetricKey(data: key))
        else { return nil }
        return try? RelayJSON.decoder().decode(RelayEvent.self, from: Data(raw.utf8))
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }

    /// Stable CallKit identifier lets duplicate pushes update the same call.
    static func callUUID(_ id: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
