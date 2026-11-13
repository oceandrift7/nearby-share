import SwiftUI

@main
struct NearbyPrototypeApp: App {
    var body: some Scene { WindowGroup { TransferView() } }
}

struct TransferView: View {
    @StateObject private var model = TransferModel()
    @State private var scanning = false
    @State private var showPassword = false
    @State private var manualExpanded = false
    @State private var returningFromSettings = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("nearby.").font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Spacer()
                        Label("Offline sharing", systemImage: "wifi").font(.caption.weight(.semibold))
                            .padding(10).background(Color.blue.opacity(0.08), in: Capsule())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Across the room.").font(.title2.bold())
                        Text("Directly between your devices.").foregroundStyle(.secondary)
                    }
                    ReceiverHero(connected: model.manifest != nil, paired: model.pairing != nil)
                    Button { scanning = true } label: {
                        Label("Scan Android pairing code", systemImage: "qrcode.viewfinder")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                    DisclosureGroup("How to connect") {
                        Text("First scan Android’s step 1 Wi-Fi code with the iPhone Camera to join its hotspot. Then scan the step 2 Nearby pairing code here. Keep both apps open. This version receives one Android file; iPhone sending and iPhone-to-iPhone are still in development.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                    }.nearbyCard()
                    if let pairing = model.pairing, model.manifest == nil {
                        Text("Connect to \(pairing.ssid)?").font(.headline)
                        Text("For the direct offline connection, scan Android's step 1 Wi-Fi code with the iPhone Camera, or join in Settings below. Keep Android open.")
                        Button("Inspect current connection") { Task { await model.connect(joinNetwork: false) } }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                        if JoinSettings.canRequestAutomaticJoin(profile: model.profileStatus) {
                            Button("Ask iPhone to join automatically") { Task { await model.connect() } }
                                .disabled(model.busy)
                        }
                        DisclosureGroup("Join in Wi-Fi Settings", isExpanded: $manualExpanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("1. Open Settings → Wi-Fi and select this network:")
                                Text(pairing.ssid).font(.headline).textSelection(.enabled)
                                Button(showPassword ? "Hide Wi-Fi password" : "Show Wi-Fi password") { showPassword.toggle() }
                                if showPassword { Text(pairing.password).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                                Button("Copy Wi-Fi password") {
                                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: pairing.password]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(90)])
                                }
                                Text("2. Enter the password and stay connected even though the network has no internet. Keep the Android app open.")
                                Text("3. Return here. Nearby will check the connection automatically.")
                                Button("I joined in Settings — inspect file") { Task { await model.connect(joinNetwork: false) } }
                                    .disabled(model.busy || model.manifest != nil)
                                if model.profileStatus == .missing {
                                    Text("Use Camera or Settings to join with this installation. No paid account is needed for this transfer.").font(.footnote)
                                }
                            }.padding(.top, 8)
                        }
                    }
                    if let file = model.manifest {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Incoming file", systemImage: "doc.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(file.name).font(.title3.bold()).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary)
                        if model.received == nil {
                            Button("Accept and receive file") { Task { await model.receive() } }
                                .buttonStyle(.borderedProminent).disabled(model.busy)
                        }
                        }.nearbyCard()
                    }
                    if model.busy && model.manifest == nil {
                        ProgressView("Checking connection…")
                        Button("Cancel") { model.cancel() }
                    }
                    if model.busy && model.manifest != nil {
                        Text(model.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                        ProgressView(value: model.progress).tint(.blue)
                        Button("Cancel") { model.cancel() }
                    }
                    Text(model.status).font(.subheadline).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).nearbyCard()
                    if let url = model.received {
                        ShareLink(item: url) { Label("Save or share received file", systemImage: "square.and.arrow.up") }
                        Button("Receive another copy") { Task { await model.receive() } }.disabled(model.busy)
                    }
                    if !model.diagnosticReport.isEmpty {
                        DisclosureGroup("Connection and speed details") {
                            Text(model.diagnosticReport).font(.footnote.monospaced()).textSelection(.enabled)
                            ShareLink(item: model.diagnosticReport) { Label("Share diagnostic report", systemImage: "square.and.arrow.up") }
                            Text("The report excludes the file name, Wi-Fi password, pairing code and account identifiers.").font(.footnote)
                        }
                    }
                    if model.pairing != nil {
                        Button("Disconnect and clear pairing") { model.disconnect() }.disabled(model.busy)
                    }
                    Text("Nearby 0.1.5 · Android → iPhone").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground))
                .toolbar(.hidden, for: .navigationBar)
                .tint(.blue)
        }
        .sheet(isPresented: $scanning) {
            QRScanner { result in
                scanning = false
                showPassword = false
                manualExpanded = false
                returningFromSettings = false
                model.scan(result)
                manualExpanded = model.pairing != nil && model.profileStatus == .missing
            }
        }
        .onChange(of: model.busy) { busy in UIApplication.shared.isIdleTimerDisabled = busy }
        .onChange(of: model.manualJoinSuggested) { suggested in if suggested { manualExpanded = true } }
        .onChange(of: model.manifest != nil) { connected in if connected { manualExpanded = false; showPassword = false } }
        .onChange(of: scenePhase) { phase in
            if phase == .background { returningFromSettings = manualExpanded && model.pairing != nil && model.manifest == nil }
            if phase == .active && returningFromSettings {
                returningFromSettings = false
                if !model.busy && model.manifest == nil { Task { await model.connect(joinNetwork: false) } }
            }
        }
    }
}

private struct ReceiverHero: View {
    let connected: Bool
    let paired: Bool
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Your connection").font(.subheadline.weight(.semibold))
                Spacer()
                Text(connected ? "Verified" : paired ? "Pairing scanned" : "Ready to pair")
                    .font(.caption.weight(.semibold)).padding(8)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 160, height: 160)
                Circle().stroke(.white.opacity(0.18), lineWidth: 1).frame(width: 110, height: 110)
                Image(systemName: connected ? "checkmark.shield.fill" : "iphone")
                    .font(.system(size: 34)).padding(22)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 24))
            }.frame(height: 165).accessibilityHidden(true)
            Text(connected ? "Connected to Android" : "Receive from Android").font(.title3.bold())
            Text(connected ? "Certificate verified. Review the file below." : "Join the hotspot, then scan its pairing code.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
        }.foregroundStyle(.white).padding(20).frame(maxWidth: .infinity)
            .background(Color(red: 0.11, green: 0.31, blue: 0.94), in: RoundedRectangle(cornerRadius: 28))
    }
}

private extension View {
    func nearbyCard() -> some View {
        padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}
