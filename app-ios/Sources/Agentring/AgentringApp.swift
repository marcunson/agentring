import SwiftUI
import VisionKit

@main
struct AgentringApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.mint)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in model.setForeground(phase == .active) }
                .task { model.setForeground(true) }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        Group {
            if model.credentials == nil { PairingView(model: model) }
            else {
                TabView(selection: $tab) {
                    HomeView(model: model, calls: model.calls).tabItem { Label("Agent", systemImage: "waveform") }.tag(0)
                    MessagesView(model: model, onBack: { tab = 0 }).tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }.tag(1)
                    SettingsView(model: model).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
                }
            }
        }
        .alert("agentring", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct BrandMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(.mint.opacity(0.12), lineWidth: 1).frame(width: 164, height: 164)
            Circle().stroke(.mint.opacity(0.25), lineWidth: 1).frame(width: 130, height: 130)
            Circle().fill(.mint.opacity(0.12)).frame(width: 96, height: 96)
            Image(systemName: "waveform").font(.system(size: 38, weight: .medium)).foregroundStyle(.mint)
        }
        .accessibilityHidden(true)
    }
}

struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var raw = ""
    @State private var relay = ""
    @State private var token = ""
    @State private var scanning = false
    @State private var manual = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("agentring").font(.system(size: 22, weight: .semibold, design: .rounded)).padding(.top, 28)
                    BrandMark().padding(.top, 20)
                    VStack(spacing: 12) {
                        Text("Your agent.\nA call away.").font(.system(size: 36, weight: .semibold)).multilineTextAlignment(.center)
                        Text("Talk through a decision, get an update,\nor let your agent reach you when it matters.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        Button {
                            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable { scanning = true }
                            else { model.error = "The camera is unavailable. Use manual pairing, or enable camera access in Settings." }
                        } label: {
                            Label("Scan pairing code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                        Button("Pair manually") { manual.toggle() }.font(.subheadline)
                    }.padding(.top, 8)
                    if manual {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Relay URL · https://…", text: $relay).textContentType(.URL).keyboardType(.URL)
                            SecureField("Pairing token · pt_…", text: $token)
                            Text("Or paste the complete pairing QR contents:").font(.caption).foregroundStyle(.secondary)
                            TextField("Pairing JSON", text: $raw, axis: .vertical).lineLimit(2...4)
                            Button("Connect relay") {
                                let payload: String
                                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload = raw }
                                else {
                                    let object: [String: Any] = ["v": 1, "relay_url": relay.trimmingCharacters(in: .whitespacesAndNewlines), "pairing_token": token.trimmingCharacters(in: .whitespacesAndNewlines)]
                                    payload = String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? ""
                                }
                                Task { await model.pair(raw: payload) }
                            }.buttonStyle(.borderedProminent).disabled(model.busy)
                        }.textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            .padding().background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
                    }
                    if model.busy { ProgressView("Connecting…") }
                    Label("Connected to your own server", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                }.padding(.horizontal, 28).padding(.bottom, 30)
            }.background(Color(red: 0.035, green: 0.055, blue: 0.065))
                .sheet(isPresented: $scanning) {
                    NavigationStack {
                        QRScanner { code in scanning = false; Task { await model.pair(raw: code) } }
                            .ignoresSafeArea(edges: .bottom).navigationTitle("Scan pairing code")
                            .toolbar { Button("Cancel") { scanning = false } }
                    }
                }
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calls: CallManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    HStack(spacing: 7) {
                        Circle().fill(model.status?.agentOnline == true ? .mint : .gray).frame(width: 6, height: 6)
                        Text(model.status?.agentOnline == true ? "AGENT ONLINE" : "AGENT OFFLINE").font(.caption2.weight(.semibold)).tracking(2)
                    }.foregroundStyle(.secondary).padding(.top, 24)
                    BrandMark()
                    VStack(spacing: 9) {
                        Text(model.status?.agentName ?? model.credentials?.agentName ?? "Your agent").font(.largeTitle.weight(.semibold))
                        Text(calls.hasCall ? calls.phase : "Pick up where you left off.").foregroundStyle(.secondary)
                    }
                    if calls.hasCall {
                        HStack(spacing: 24) {
                            Button { Task { await calls.toggleMute() } } label: {
                                Label(calls.muted ? "Unmute" : "Mute", systemImage: calls.muted ? "mic.slash.fill" : "mic.fill")
                            }.buttonStyle(.bordered)
                            Button { calls.toggleSpeaker() } label: {
                                Label("Speaker", systemImage: calls.speaker ? "speaker.wave.3.fill" : "speaker.fill")
                            }.buttonStyle(.bordered)
                        }
                        Button(role: .destructive) { Task { await calls.hangUp() } } label: {
                            Label("End call", systemImage: "phone.down.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button { Task { await calls.start() } } label: {
                            Label("Call agent", systemImage: "phone.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.status?.agentOnline != true)
                        if let call = model.status?.activeCall, call.direction == "agent_to_user", call.isOpen {
                            Button("Join current call") { Task { await calls.start(join: call.callId) } }.buttonStyle(.bordered)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("A conversation that keeps work moving", systemImage: "sparkle").font(.subheadline.weight(.medium))
                        Text("Ask a question or talk through the next step. Your voice assistant can consult your agents during the call.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
                    Text(model.connection).font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }.navigationTitle("agentring").navigationBarTitleDisplayMode(.inline)
                .refreshable { await model.refresh() }
        }
    }
}

struct MessagesView: View {
    @ObservedObject var model: AppModel
    let onBack: () -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var clientId = UUID().uuidString
    @FocusState private var composerFocused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if model.messages.isEmpty {
                                ContentUnavailableView("A direct line to your agent", systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Messages and missed call updates will appear here.")).padding(.top, 60)
                            }
                            ForEach(model.messages) { message in
                                HStack {
                                    if message.from == "user" { Spacer(minLength: 40) }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(message.from == "agent" ? model.credentials?.agentName ?? "Agent" : "You")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(message.text).textSelection(.enabled)
                                        Text(Date(timeIntervalSince1970: Double(message.createdAt) / 1000), style: .time)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.padding(14).background(message.from == "user" ? Color.mint.opacity(0.15) : .white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 18))
                                    if message.from == "agent" { Spacer(minLength: 40) }
                                }.id(message.id).task { await model.markRead(message) }
                            }
                        }.padding()
                    }.scrollDismissesKeyboard(.interactively)
                        .onChange(of: model.messages.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                        .defaultScrollAnchor(.bottom)
                }
                HStack(alignment: .bottom) {
                    TextField("Message your agent", text: $text, axis: .vertical).lineLimit(1...5).padding(12)
                        .focused($composerFocused)
                        .accessibilityIdentifier("message-input")
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)).disabled(sending)
                    Button {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        sending = true
                        Task {
                            defer { sending = false }
                            do {
                                try await model.send(value, clientId: clientId)
                                text = ""; clientId = UUID().uuidString; composerFocused = false
                            }
                            catch { model.present(error) }
                        }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
                        .accessibilityLabel("Send message").disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000)
                }.padding()
            }.navigationTitle("Messages").navigationBarTitleDisplayMode(.inline)
                .refreshable { await model.refresh() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            composerFocused = false
                            onBack()
                        } label: { Label("Agent", systemImage: "chevron.left") }
                            .accessibilityLabel("Back to Agent")
                            .accessibilityIdentifier("messages-back")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { composerFocused = false }
                            .accessibilityIdentifier("dismiss-message-keyboard")
                    }
                }
                .onDisappear { composerFocused = false }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmForget = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Your relay") {
                    LabeledContent("Agent", value: model.credentials?.agentName ?? "")
                    Text(model.credentials?.relayUrl ?? "").font(.footnote).textSelection(.enabled)
                    LabeledContent("Connection", value: model.connection)
                }
                Section("Calls & notifications") {
                    LabeledContent("Apple push", value: model.pushRegistration)
                    LabeledContent("Relay push", value: model.status?.pushProvider ?? "Unknown")
                    Button("Enable microphone & notifications") { Task { await model.permissions() } }
                    Button("Open iPhone settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Text("Incoming calls use the iPhone call screen. Focus and silent mode follow your iPhone settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Your relay stores messages. Calls use your LiveKit server; AI call audio is also shared with the voice provider configured on your daemon.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Disconnect this iPhone", role: .destructive) { confirmForget = true }
                }
            }.navigationTitle("Settings")
                .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { Task { await model.forget() } }
                } message: { Text("You will need a new pairing code to connect again.") }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var completed = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    completed = true; dataScanner.stopScanning(); onCode(text); return
                }
            }
        }
    }
}
