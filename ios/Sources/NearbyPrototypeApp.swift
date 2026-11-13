import SwiftUI

@main
struct NearbyPrototypeApp: App {
    var body: some Scene { WindowGroup { TransferView() } }
}

struct TransferView: View {
    @StateObject private var model = TransferModel()
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Offline transfer prototype").font(.title.bold())
                    Text("Receive one file from the Android app. Keep both apps open. This build does not yet send files or connect two iPhones.")
                    Button("Scan Android pairing code") { scanning = true }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    if let pairing = model.pairing {
                        Text("Connect to \(pairing.ssid)?").font(.headline)
                        Text("Your iPhone will ask before joining this temporary Wi-Fi network. It has no internet connection.")
                        Button("Join and inspect file") { Task { await model.connect() } }
                            .disabled(model.busy || model.manifest != nil)
                    }
                    if let file = model.manifest {
                        Text(file.name).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        Button("Accept and receive file") { Task { await model.receive() } }
                            .buttonStyle(.borderedProminent).disabled(model.busy || model.received != nil)
                    }
                    if model.busy {
                        ProgressView(value: model.progress)
                        Button("Cancel") { model.cancel() }
                    }
                    Text(model.status).textSelection(.enabled)
                    if let url = model.received {
                        ShareLink(item: url) { Label("Save or share received file", systemImage: "square.and.arrow.up") }
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
                model.scan(result)
            }
        }
        .onChange(of: model.busy) { busy in UIApplication.shared.isIdleTimerDisabled = busy }
    }
}
