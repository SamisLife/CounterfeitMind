import SwiftUI
import CoreNFC
import CryptoKit


struct TreasuryPayload: Codable {
    let serial: String
    let currency: String
    let value: Int
    let sig: String  
}


struct RelayRegisterResponse: Codable {
    let ok: Bool
    let serial: String?
    let billHash: String?
    let txHash: String?
    let blockNumber: Int?
    let error: String?
}


final class TreasurySigner {

    private let seedB64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    lazy var privateKey: Curve25519.Signing.PrivateKey = {
        if let data = Data(base64Encoded: seedB64), data.count == 32 {
            return try! Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } else {
            return Curve25519.Signing.PrivateKey()
        }
    }()

    var publicKeyB64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    func message(serial: String, currency: String, value: Int) -> Data {
        let m = "serial=\(serial)|currency=\(currency)|value=\(value)"
        return Data(m.utf8)
    }

    func sign(serial: String, currency: String, value: Int) -> String {
        let msg = message(serial: serial, currency: currency, value: value)
        let sig = try! privateKey.signature(for: msg)
        return sig.base64EncodedString()
    }
}



final class TreasuryNFCWriter: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {

    @Published var isWriting = false
    @Published var statusText: String = "Ready"

    @Published var lastWrittenJSON: String = ""
    @Published var lastPublicKeyB64: String = ""

    @Published var isRegistering = false
    @Published var registerStatus: String = ""
    @Published var lastBillHash: String = ""
    @Published var lastTxHash: String = ""
    @Published var lastBlockNumber: String = ""

    private var session: NFCNDEFReaderSession?
    private var pendingText: String?

    private let signer = TreasurySigner()


    private let relayBaseURL = "http://35.23.152.107:8787"

    func beginWrite(serial: String, currency: String, value: Int) {
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurr = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        let sigB64 = signer.sign(serial: cleanSerial, currency: cleanCurr, value: value)
        let payload = TreasuryPayload(serial: cleanSerial, currency: cleanCurr, value: value, sig: sigB64)

        let jsonData = try! JSONEncoder().encode(payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        pendingText = jsonString
        lastWrittenJSON = jsonString
        lastPublicKeyB64 = signer.publicKeyB64

        Task { @MainActor in
            await self.registerOnChain(serial: cleanSerial, currency: cleanCurr, value: value, pubkeyB64: self.lastPublicKeyB64)
        }

        guard NFCNDEFReaderSession.readingAvailable else {
            isWriting = false
            statusText = "NFC not available (use another NFC app). JSON ready ✅"
            return
        }

        isWriting = true
        statusText = "Hold iPhone near NFC tag…"

        let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        s.alertMessage = "Hold your iPhone near the NFC sticker to write Treasury data."
        session = s
        s.begin()
    }

    @MainActor
    private func registerOnChain(serial: String, currency: String, value: Int, pubkeyB64: String) async {
        isRegistering = true
        registerStatus = "Registering bill on blockchain…"
        lastBillHash = ""
        lastTxHash = ""
        lastBlockNumber = ""

        guard let url = URL(string: "\(relayBaseURL)/register") else {
            isRegistering = false
            registerStatus = "Relay URL invalid."
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "serial": serial,
            "currency": currency,
            "value": value,
            "pubkeyB64": pubkeyB64
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

            let (data, resp) = try await URLSession.shared.data(for: req)
            let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? -1

            if let decoded = try? JSONDecoder().decode(RelayRegisterResponse.self, from: data),
               decoded.ok == true {

                registerStatus = "✅ Registered on-chain"
                lastBillHash = decoded.billHash ?? ""
                lastTxHash = decoded.txHash ?? ""
                if let bn = decoded.blockNumber {
                    lastBlockNumber = "\(bn)"
                } else {
                    lastBlockNumber = ""
                }
            } else {
                let raw = String(data: data, encoding: .utf8) ?? "(no body)"
                registerStatus = "❌ Relay failed (HTTP \(httpCode)): \(raw)"
            }
        } catch {
            registerStatus = "❌ Network error: \(error.localizedDescription)"
        }

        isRegistering = false
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async {
            self.isWriting = false
            self.session = nil

            let ns = error as NSError
            if ns.domain == NFCReaderError.errorDomain,
               ns.code == NFCReaderError.Code.readerSessionInvalidationErrorUserCanceled.rawValue {
                self.statusText = "Canceled"
                return
            }

            self.statusText = "NFC session ended: \(error.localizedDescription)"
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {

    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }

        session.connect(to: tag) { [weak self] err in
            guard let self else { return }

            if let err {
                session.invalidate(errorMessage: "Connect failed: \(err.localizedDescription)")
                DispatchQueue.main.async { self.isWriting = false }
                return
            }

            tag.queryNDEFStatus { status, capacity, err in
                if let err {
                    session.invalidate(errorMessage: "Status failed: \(err.localizedDescription)")
                    DispatchQueue.main.async { self.isWriting = false }
                    return
                }

                guard status != .notSupported else {
                    session.invalidate(errorMessage: "Tag is not NDEF.")
                    DispatchQueue.main.async { self.isWriting = false; self.statusText = "Tag not NDEF" }
                    return
                }

                guard status == .readWrite else {
                    session.invalidate(errorMessage: "Tag is read-only.")
                    DispatchQueue.main.async { self.isWriting = false; self.statusText = "Tag not writable" }
                    return
                }

                guard let text = self.pendingText else {
                    session.invalidate(errorMessage: "No pending payload.")
                    DispatchQueue.main.async { self.isWriting = false }
                    return
                }

                // NDEF Text record payload: [status][lang][text]
                let payloadData = self.makeNDEFTextPayload(text: text, lang: "en")
                let record = NFCNDEFPayload(
                    format: .nfcWellKnown,
                    type: Data([0x54]), // "T"
                    identifier: Data(),
                    payload: payloadData
                )

                let message = NFCNDEFMessage(records: [record])

                if message.length > capacity {
                    session.invalidate(errorMessage: "Tag too small (\(capacity) bytes). Need \(message.length).")
                    DispatchQueue.main.async { self.isWriting = false; self.statusText = "Tag too small" }
                    return
                }

                tag.writeNDEF(message) { err in
                    if let err {
                        session.invalidate(errorMessage: "Write failed: \(err.localizedDescription)")
                        DispatchQueue.main.async { self.isWriting = false; self.statusText = "Write failed" }
                        return
                    }

                    session.alertMessage = "Treasury data written ✅"
                    session.invalidate()

                    DispatchQueue.main.async {
                        self.isWriting = false
                        self.statusText = "Written ✅ (and relay registration attempted)"
                    }
                }
            }
        }
    }

    private func makeNDEFTextPayload(text: String, lang: String) -> Data {
        let langData = Data(lang.utf8)
        let textData = Data(text.utf8)
        let status: UInt8 = UInt8(langData.count & 0x3F) // UTF-8 + lang length
        var payload = Data([status])
        payload.append(langData)
        payload.append(textData)
        return payload
    }
}
