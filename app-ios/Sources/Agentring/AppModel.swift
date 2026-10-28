import SwiftUI
import UserNotifications
import AVFAudio

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var credentials: Credentials?
    @Published var messages: [Message] = []
    @Published var status: RelayStatus?
    @Published var connection = "Disconnected"
    @Published var error: String?
    @Published var busy = false
    @Published var notificationsEnabled = false
    @Published var pushRegistration = "Not registered"
    lazy var calls = CallManager(model: self)
    var apnsToken: String?
    var voipToken: String?
    private var stream: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var lastSeq: Int64 = 0
    private var foreground = false

    init() {
        credentials = KeychainStore.load()
        if credentials != nil, let data = try? Data(contentsOf: Self.cacheURL) {
            messages = (try? RelayJSON.decoder().decode([Message].self, from: data)) ?? []
        }
    }

    var api: RelayAPI? {
        guard let credentials else { return nil }
        return try? RelayAPI(url: credentials.relayUrl, jwt: credentials.deviceJwt)
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("messages.json")
    }

    func pair(raw: String) async {
        busy = true
        defer { busy = false }
        do {
            let qr = try RelayJSON.decoder().decode(PairingQR.self, from: Data(raw.utf8))
            guard qr.v == 1, !qr.pairingToken.isEmpty else { throw RelayValidationError.invalidQR }
            let client = try RelayAPI(url: qr.relayUrl)
            let result: PairResponse = try await client.value("/v1/pair", method: "POST", body: [
                "pairing_token": qr.pairingToken, "platform": "ios", "device_name": "iPhone",
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
            ])
            let saved = Credentials(relayUrl: qr.relayUrl, deviceId: result.deviceId, deviceJwt: result.deviceJwt,
                pushSecret: result.pushSecret, relayId: result.relayId, agentName: result.agentName)
            try KeychainStore.save(saved)
            credentials = saved
            messages = []
            lastSeq = 0
            error = nil
            await registerTokens()
            await permissions()
            setForeground(true)
        } catch { present(error) }
    }

    func permissions() async {
        do {
            notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { error = "Enable microphone access in Settings to talk on calls." }
        } catch { present(error) }
    }

    func registerTokens(clearVoip: Bool = false) async {
        guard let api else { return }
        var body: [String: Any] = ["environment": Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String == "production" ? "production" : "sandbox"]
        if let apnsToken { body["apns_token"] = apnsToken }
        if clearVoip { body["voip_token"] = NSNull() }
        else if let voipToken { body["voip_token"] = voipToken }
        guard body.count > 1 else { return }
        do {
            _ = try await api.request("/v1/device/apns", method: "POST", body: body)
            pushRegistration = voipToken == nil ? "Messages only" : "VoIP registered"
        } catch { pushRegistration = "Registration failed"; present(error) }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            startStream()
            Task { await refresh(); await registerTokens() }
        } else if !calls.hasCall {
            stopStream()
        }
    }

    func callFinished() { if !foreground { stopStream() } }

    func refresh() async {
        guard let api else { return }
        do {
            let status: RelayStatus = try await api.value("/v1/status")
            self.status = status
            var after: String? = messages.last?.msgId
            while true {
                let page: MessagePage = try await api.value("/v1/messages?limit=200" + (after.map { "&after=\($0)" } ?? ""))
                for message in page.messages { upsert(message) }
                guard page.hasMore, let last = page.messages.last else { break }
                after = last.msgId
            }
        } catch { present(error) }
    }

    func send(_ text: String, replyTo: String? = nil, clientId: String = UUID().uuidString) async throws {
        guard let api else { throw RelayAPIError(status: 401, message: "Pair your relay first.") }
        var body: [String: Any] = ["text": text, "client_msg_id": clientId]
        if let replyTo { body["reply_to"] = replyTo }
        let message: Message = try await api.value("/v1/messages", method: "POST", body: body)
        upsert(message)
    }

    func markRead(_ message: Message) async {
        guard message.from == "agent", let api else { return }
        do { _ = try await api.request("/v1/messages/\(message.msgId)/read", method: "POST") }
        catch { present(error) }
    }

    func receive(_ event: RelayEvent) async throws {
        switch event.type {
        case "msg.new":
            // Fetch the authoritative full message: push text can be truncated.
            if let id = event.msgId, let api {
                let message: Message = try await api.value("/v1/messages/\(id)")
                upsert(message)
            }
        case "agent.presence":
            Task { await refresh() }
        default: await calls.receive(event)
        }
        // Only WebSocket events advance the cursor; a later push must not skip replay.
    }

    func startStream() {
        guard stream == nil, let api else { return }
        stream = Task {
            var delay: UInt64 = 1
            while !Task.isCancelled {
                let ws = api.socket(after: lastSeq)
                socket = ws
                ws.resume()
                connection = "Connecting…"
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        let event = try RelayJSON.decoder().decode(RelayEvent.self, from: data)
                        connection = "Connected"
                        delay = 1
                        try await receive(event)
                        if let seq = event.seq { lastSeq = max(lastSeq, seq) }
                    }
                } catch {
                    if Task.isCancelled { break }
                    ws.cancel(with: .goingAway, reason: nil)
                    if ws.closeCode.rawValue == 4401 {
                        self.error = "This device was revoked. Pair it again."
                        connection = "Pairing expired"
                        break
                    }
                    connection = "Reconnecting…"
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    func stopStream() {
        stream?.cancel(); stream = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connection = "Disconnected"
    }

    func forget() async {
        guard !calls.hasCall else { error = "End your call before disconnecting."; return }
        if let api {
            do {
                _ = try await api.request("/v1/device/apns", method: "POST", body: [
                    "environment": Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String == "production" ? "production" : "sandbox",
                    "apns_token": NSNull(), "voip_token": NSNull()
                ])
            } catch { present(error); return }
        }
        stopStream()
        KeychainStore.clear()
        credentials = nil; messages = []; status = nil; lastSeq = 0
        try? FileManager.default.removeItem(at: Self.cacheURL)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func present(_ error: Error) { self.error = error.localizedDescription }

    private func upsert(_ message: Message) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else { messages.append(message); messages.sort { $0.msgId < $1.msgId } }
        do {
            try FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RelayJSON.encoder().encode(messages).write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { present(error) }
    }
}
