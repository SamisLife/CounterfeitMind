import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraService()
    @StateObject private var ble = BLEManager()

    @State private var showTreasury = false
    @State private var blockchainCheckEnabled: Bool = false
    @State private var scanRequestID: UUID = UUID()

    var body: some View {
        ZStack {
            PremiumBackground().ignoresSafeArea()

            VStack(spacing: 18) {
                Header(showTreasury: $showTreasury)

                ScanWindow {
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay { ScanOverlay() }
                        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
                }

                Spacer()

                VStack(spacing: 10) {
                    Text(ble.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)

                    BottomPanel(
                        isRequesting: camera.isRequesting,
                        scanned: camera.scanned,
                        blockchainCheckEnabled: $blockchainCheckEnabled,
                        ble: ble,
                        onCapture: { camera.capture() }
                    )
                }
            }
            .padding(.top, 16)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .alert("Error", isPresented: $camera.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.errorMessage)
        }
        .sheet(isPresented: $showTreasury) { TreasuryView() }

        .onChange(of: camera.scanned) { scanned in
            guard let scanned else { return }

            let serial = (scanned.serial ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let currency = (scanned.currency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let denom = scanned.denomination ?? 0

            guard !serial.isEmpty, !currency.isEmpty, denom > 0 else { return }

            // Dedupe
            let key = "\(serial)|\(currency)|\(denom)|\(blockchainCheckEnabled)"
            if ble.lastSentKey == key { return }
            ble.lastSentKey = key

            let requestID = UUID()
            scanRequestID = requestID

            // ✅ Put BOTH sends into one Task so it always runs in-order
            Task {
                // 1) Send scan immediately (on main actor for BLE safety)
                let scanPayload: [String: Any] = [
                    "type": "scan",
                    "serial": serial,
                    "currency": currency,
                    "denomination": denom,
                    "blockchain_check": blockchainCheckEnabled
                ]

                await MainActor.run {
                    ble.send(json: scanPayload.toJSONString())
                    print("📤 BLE SENT scan:", scanPayload.toJSONString())
                }

                // 2) If blockchain enabled, ALWAYS send a chain packet (even on failure)
                guard blockchainCheckEnabled else { return }

                let result = await RelayClient.shared.lookupBill(serial: serial)

                // Ignore older async results
                guard scanRequestID == requestID else { return }

                var chainPayload: [String: Any] = [
                    "type": "chain",
                    "serial": serial
                ]

                switch result {
                case .issued(let billHash, let issuedAt):
                    let shortHash = billHash.count > 18 ? (String(billHash.prefix(18)) + "...") : billHash
                    chainPayload["ok"] = true
                    chainPayload["issued"] = true
                    chainPayload["billHash"] = shortHash
                    chainPayload["issuedAt"] = issuedAt

                case .notIssued:
                    chainPayload["ok"] = true          // ✅ request succeeded, just not issued
                    chainPayload["issued"] = false

                case .failed(let message):
                    let shortErr = message.count > 60 ? (String(message.prefix(60)) + "...") : message
                    chainPayload["ok"] = false         // ✅ request failed
                    chainPayload["issued"] = false
                    chainPayload["error"] = shortErr
                }

                await MainActor.run {
                    ble.send(json: chainPayload.toJSONString())
                    print("📤 BLE SENT chain:", chainPayload.toJSONString())
                }
            }
        }
    }
}


final class RelayClient {
    static let shared = RelayClient()
    private let baseURL = "http://35.23.152.107:8787"

    enum LookupResult {
        case issued(billHash: String, issuedAt: Int)
        case notIssued
        case failed(message: String)
    }

    struct LookupResponse: Decodable {
        let ok: Bool?
        let issued: Bool?
        let serial: String?
        let billHash: String?
        let issuedAt: Int?
        let error: String?
    }

    func lookupBill(serial: String) async -> LookupResult {
        let safeSerial = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial
        guard let url = URL(string: "\(baseURL)/bill/\(safeSerial)") else {
            return .failed(message: "Bad relay URL")
        }

        do {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 6

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            guard (200...299).contains(code) else {
                let raw = String(data: data, encoding: .utf8) ?? "(no body)"
                return .failed(message: "HTTP \(code): \(raw)")
            }

            guard let decoded = try? JSONDecoder().decode(LookupResponse.self, from: data) else {
                let raw = String(data: data, encoding: .utf8) ?? "(unreadable)"
                return .failed(message: "Decode failed: \(raw)")
            }

            if let ok = decoded.ok, ok == false {
                // server explicitly says ok=false
                return .failed(message: decoded.error ?? "Relay ok=false")
            }

            if decoded.issued == false {
                return .notIssued
            }

            if decoded.issued == true {
                guard let bh = decoded.billHash, let ia = decoded.issuedAt else {
                    return .failed(message: "Issued but missing billHash/issuedAt")
                }
                return .issued(billHash: bh, issuedAt: ia)
            }

            if let bh = decoded.billHash, let ia = decoded.issuedAt {
                return .issued(billHash: bh, issuedAt: ia)
            }

            return .notIssued
        } catch {

            return .failed(message: error.localizedDescription)
        }
    }
}

// MARK: - JSON helper
private extension Dictionary where Key == String, Value == Any {
    func toJSONString() -> String {
        guard JSONSerialization.isValidJSONObject(self),
              let data = try? JSONSerialization.data(withJSONObject: self, options: []),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}

// MARK: - Background
struct PremiumBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.10),
                Color(red: 0.03, green: 0.04, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}


struct Header: View {
    @Binding var showTreasury: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Counterfeit Eye")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Scan a banknote to verify")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button { showTreasury = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Treasury")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Scan Window
struct ScanWindow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 36, 520)
            let h = w / 2.2
            content
                .frame(width: w, height: h)
                .position(x: geo.size.width / 2, y: h / 2)
        }
        .frame(height: UIScreen.main.bounds.width * 0.88 / 2.2 + 8)
    }
}

// MARK: - Overlay
struct ScanOverlay: View {
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .stroke(Color.cyan.opacity(pulse ? 0.25 : 0.12), lineWidth: 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    pulse.toggle()
                }
            }
    }
}

// MARK: - Bottom Panel
struct BottomPanel: View {
    let isRequesting: Bool
    let scanned: BanknoteFields?
    @Binding var blockchainCheckEnabled: Bool
    let ble: BLEManager
    let onCapture: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Toggle(isOn: $blockchainCheckEnabled) {
                    Text("Blockchain verification")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.footnote)
                }
                .tint(.purple.opacity(0.95))
            }
            .padding(.horizontal, 4)

            Button(action: onCapture) {
                HStack(spacing: 10) {
                    Image(systemName: isRequesting ? "sparkles" : "camera.fill")
                    Text(isRequesting ? "Scanning…" : "Capture")
                }
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isRequesting)

            if let scanned {
                ResultCard(fields: scanned)
            } else {
                Text("Align banknote and tap Capture")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.footnote)
            }

            Button {
                let test: [String: Any] = [
                    "type": "scan",
                    "serial": "B17171999D",
                    "currency": "USD",
                    "denomination": 1,
                    "blockchain_check": blockchainCheckEnabled
                ]
                ble.send(json: test.toJSONString())
            } label: {
                Text("Send Test to ESP32")
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.purple.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }
}

struct ResultCard: View {
    let fields: BanknoteFields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan Result")
                .foregroundStyle(.white.opacity(0.9))
                .font(.headline)

            HStack {
                ResultItem(title: "Currency", value: fields.currency ?? "—")
                ResultItem(title: "Value", value: fields.denomination.map(String.init) ?? "—")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Serial Number")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.caption)
                Text(fields.serial ?? "—")
                    .foregroundStyle(.white)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ResultItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .foregroundStyle(.white.opacity(0.6))
                .font(.caption)
            Text(value)
                .foregroundStyle(.white)
                .font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
