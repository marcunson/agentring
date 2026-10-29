import AVFAudio
import CallKit
import Combine
import LiveKit

@MainActor
final class CallManager: NSObject, ObservableObject, @preconcurrency CXProviderDelegate {
    @Published private(set) var phase = ""
    @Published private(set) var hasCall = false
    @Published private(set) var starting = false
    @Published private(set) var displayName = ""
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    private let provider: CXProvider
    private let controller = CXCallController()
    private unowned let model: AppModel
    private var callId: String?
    private var uuid: UUID?
    private var incoming = false
    private var joined = false
    private var audioActive = false
    private var room: Room?
    private var poll: Task<Void, Never>?
    private var joinTarget: String?
    private var destination: CallDestination = .agent
    private var pendingIncoming: Set<String> = []
    private let ringback = OutgoingRingback()

    init(model: AppModel) {
        self.model = model
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic, .emailAddress, .phoneNumber]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    }

    /// Report before any network request; PushKit requires a prompt CallKit response.
    func incomingCall(_ event: RelayEvent, completion: @escaping () -> Void = {}) {
        guard let id = event.callId else { completion(); return }
        if callId == id || pendingIncoming.contains(id) { completion(); return }
        pendingIncoming.insert(id)
        let callUUID = PushVerifier.callUUID(id)
        let update = CXCallUpdate()
        update.remoteHandle = callerHandle(fallback: event.agentName ?? "Agent")
        // Let iOS resolve the selected contact's name, photo and Contact Poster.
        if model.callerIdentity == nil { update.localizedCallerName = event.agentName ?? "Agent" }
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            Task { @MainActor in
                defer { completion() }
                guard let self else { return }
                self.pendingIncoming.remove(id)
                guard error == nil else { self.model.present(error!); return }
                if (event.expiresAt ?? 0) <= Int64(Date().timeIntervalSince1970 * 1000) {
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .unanswered)
                    return
                }
                // A second invite must not overwrite an existing CallKit session.
                guard !self.hasCall else {
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
                    return
                }
                self.callId = id; self.uuid = callUUID; self.incoming = true
                self.hasCall = true; self.phase = "Incoming call"
                self.displayName = event.agentName ?? "Agent"
                self.model.startStream()
                self.monitor(id: id, expiresAt: event.expiresAt)
                if let api = self.model.api {
                    Task {
                        do { _ = try await api.request("/v1/calls/\(id)/ringing", method: "POST") }
                        catch { self.model.present(error) }
                    }
                }
            }
        }
    }

    /// Even an invalid/stale VoIP payload must finish its PushKit lifecycle through CallKit.
    func rejectPush(completion: @escaping () -> Void) {
        let id = UUID()
        let update = CXCallUpdate()
        update.localizedCallerName = "agentring"
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] _ in
            Task { @MainActor in
                self?.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
                completion()
            }
        }
    }

    func start(to destination: CallDestination = .agent, join: String? = nil) async {
        guard !hasCall, !starting else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            model.error = "Enable microphone access in Settings before calling."; return
        }
        starting = true
        self.destination = destination
        joinTarget = join
        let id = UUID()
        do {
            let action = CXStartCallAction(call: id, handle: callerHandle(fallback: destination.name))
            action.contactIdentifier = model.callerIdentity?.contactIdentifier
            try await controller.request(CXTransaction(action: action))
        } catch { starting = false; joinTarget = nil; model.present(error) }
    }

    func hangUp() async {
        guard let uuid else { return }
        do { try await controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) }
        catch { model.present(error) }
    }

    func toggleMute() async {
        guard let uuid else { return }
        do { try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: !muted))) }
        catch { model.present(error) }
    }

    func toggleSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .none : .speaker)
            speaker.toggle()
        } catch { model.present(error) }
    }

    func receive(_ event: RelayEvent) async {
        if event.type == "call.invite", event.direction == "agent_to_user",
           (event.expiresAt ?? 0) > Int64(Date().timeIntervalSince1970 * 1000), !hasCall {
            incomingCall(event)
        } else if event.callId == callId {
            if event.type == "call.end" || event.type == "call.missed" {
                await finish(reason: event.type == "call.missed" ? .unanswered : .remoteEnded)
            } else if event.type == "call.accept", event.by == "agent", let uuid {
                phase = "Connected"
                provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
        }
    }

    func reconcile(_ call: RelayCall?) async {
        guard let callId else { return }
        if call?.callId != callId || call?.isOpen != true { await finish(reason: .remoteEnded) }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard !hasCall, let api = model.api else { starting = false; action.fail(); return }
        uuid = action.callUUID; hasCall = true; incoming = false; phase = "Calling…"
        starting = false
        let target = joinTarget; joinTarget = nil
        let selectedDestination = destination
        displayName = target == nil ? selectedDestination.name : model.status?.activeCall?.agentName ?? "Agent"
        let playTones = target == nil && RingbackTone.ringCount() == 2
        do {
            try configureAudio()
            if playTones { try ringback.prepare() }
        } catch {
            action.fail(); model.present(error)
            Task { await failAndEnd() }
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        // Fulfill initiation promptly so CallKit activates audio for local ringback.
        action.fulfill()
        Task {
            do {
                if playTones {
                    if audioActive { ringback.start() }
                    // A missing activation/delegate callback must not leave a call stuck.
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 12_000_000_000) }
                        catch { return }
                        if self?.uuid == action.callUUID { self?.ringback.stop() }
                    }
                    let finished = await ringback.waitForCompletion()
                    timeout.cancel()
                    guard uuid == action.callUUID else { return }
                    guard finished else {
                        throw NSError(domain: "AgentringAudio", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Could not play calling tones. Try again or select None in Settings."])
                    }
                }
                guard uuid == action.callUUID else { return }
                let result: CallWithJoin
                if let target {
                    result = try await api.value("/v1/calls/\(target)/join", method: "POST")
                } else {
                    result = try await api.startCall(to: selectedDestination)
                }
                guard uuid == action.callUUID else { _ = try? await api.request("/v1/calls/\(result.call.callId)/end", method: "POST"); return }
                callId = result.call.callId
                try await connect(result.join, uuid: action.callUUID)
                joined = true
                model.startStream()
                if result.call.state == "active" {
                    phase = "Connected"
                    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                }
                monitor(id: result.call.callId)
            } catch {
                guard uuid == action.callUUID else { return }
                model.present(error); await failAndEnd()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard uuid == action.callUUID, let id = callId, let api = model.api else { action.fail(); return }
        phase = "Connecting…"
        Task {
            do {
                try configureAudio()
                let result: CallWithJoin = try await api.value("/v1/calls/\(id)/accept", method: "POST")
                guard uuid == action.callUUID else { _ = try? await api.request("/v1/calls/\(id)/end", method: "POST"); action.fail(); return }
                try await connect(result.join, uuid: action.callUUID)
                joined = true; phase = "Connected"
                action.fulfill()
            } catch { action.fail(); model.present(error); await failAndEnd() }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == uuid else { action.fulfill(); return }
        let id = callId
        let decline = incoming && !joined
        action.fulfill()
        Task {
            await finish(reason: .remoteEnded, report: false)
            if let id, let api = model.api {
                do { _ = try await api.request("/v1/calls/\(id)/\(decline ? "decline" : "end")", method: "POST") }
                catch { model.present(error) }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard uuid == action.callUUID else { action.fail(); return }
        Task {
            do {
                try await room?.localParticipant.setMicrophone(enabled: !action.isMuted)
                muted = action.isMuted; action.fulfill()
            } catch { action.fail(); model.present(error) }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        ringback.start()
        Task {
            do { try await room?.localParticipant.setMicrophone(enabled: !muted) }
            catch { model.present(error); await failAndEnd() }
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        ringback.pause()
        Task { try? await room?.localParticipant.setMicrophone(enabled: false) }
    }

    func providerDidReset(_ provider: CXProvider) { Task { await failAndEnd() } }

    private func callerHandle(fallback: String) -> CXHandle {
        guard let identity = model.callerIdentity else { return CXHandle(type: .generic, value: fallback) }
        return CXHandle(type: identity.kind == .email ? .emailAddress : .phoneNumber, value: identity.address)
    }

    private func configureAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        // CallKit activates the session in didActivate; never setActive here.
    }

    private func connect(_ info: JoinInfo, uuid expected: UUID) async throws {
        _ = try RelayURLPolicy.validate(info.livekitUrl, websocket: true)
        let next = Room()
        room = next
        try await next.connect(url: info.livekitUrl, token: info.livekitToken)
        guard uuid == expected else { await next.disconnect(); throw CancellationError() }
        if audioActive { try await next.localParticipant.setMicrophone(enabled: !muted) }
    }

    private func monitor(id: String, expiresAt: Int64? = nil) {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled, callId == id {
                do {
                    guard let api = model.api else { return }
                    let call: RelayCall = try await api.value("/v1/calls/\(id)")
                    guard callId == id else { return }
                    if !call.isOpen { await finish(reason: .remoteEnded); return }
                    if incoming && !joined, let expiresAt, expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) {
                        await finish(reason: call.state == "active" ? .answeredElsewhere : .unanswered); return
                    }
                    if !incoming && call.state == "active", let uuid {
                        phase = "Connected"; provider.reportOutgoingCall(with: uuid, connectedAt: Date())
                    }
                } catch {
                    if let error = error as? RelayAPIError, error.status == 401 || error.status == 404 {
                        await finish(reason: .failed); return
                    }
                    // A lost network must not leave a stale ringing call indefinitely.
                    if incoming && !joined, let expiresAt, expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) {
                        await finish(reason: .unanswered); return
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func failAndEnd() async {
        let id = callId
        await finish(reason: .failed)
        if let id, let api = model.api { _ = try? await api.request("/v1/calls/\(id)/end", method: "POST") }
    }

    private func finish(reason: CXCallEndedReason, report: Bool = true) async {
        poll?.cancel(); poll = nil
        ringback.stop()
        if report, let uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: reason) }
        let oldRoom = room
        room = nil; uuid = nil; callId = nil; hasCall = false; joined = false
        incoming = false; muted = false; speaker = false; audioActive = false; phase = ""
        starting = false; displayName = ""; destination = .agent; joinTarget = nil
        await oldRoom?.disconnect()
        model.callFinished()
    }
}
