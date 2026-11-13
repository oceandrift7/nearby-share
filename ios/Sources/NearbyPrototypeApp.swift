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
                    Text("Nearby 0.1.4").font(.title.bold())
                    Text("First scan Android’s Wi-Fi code with the iPhone Camera to join its hotspot. Then scan the Nearby pairing code here. Receive one file from the Android app. Keep both apps open. This build does not yet send files or connect two iPhones.")
                    Button("Scan Android pairing code") { scanning = true }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
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
                        Text(file.name).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        if model.received == nil {
                            Button("Accept and receive file") { Task { await model.receive() } }
                                .buttonStyle(.borderedProminent).disabled(model.busy)
                        }
                    }
                    if model.busy {
                        ProgressView(value: model.progress)
                        Button("Cancel") { model.cancel() }
                    }
                    Text(model.status).textSelection(.enabled)
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
                }.padding()
            }.navigationTitle("Nearby")
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
