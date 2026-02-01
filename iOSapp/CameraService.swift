import Foundation
import AVFoundation
import UIKit

struct BanknoteFields: Decodable, Equatable {
    let currency: String?
    let denomination: Int?
    let serial: String?
}

@MainActor
final class CameraService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {

    @Published var showError = false
    @Published var errorMessage = ""

    @Published var isRequesting = false
    @Published var scanned: BanknoteFields? = nil

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false

    private let gemini = GeminiClient(apiKey: "API_Key_HERE")

    func start() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status != .authorized {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted { fail("Camera permission denied"); return }
            }

            configureIfNeeded()
            session.startRunning()
        }
    }

    func stop() {
        session.stopRunning()
    }

    func capture() {
        scanned = nil
        isRequesting = true
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else { fail("Camera unavailable"); return }

        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {

        if let error = error { fail(error.localizedDescription); return }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data),
              let cropped = centerCrop(image: image, aspect: 2.2) else {
            fail("Capture failed"); return
        }

        Task {
            do {
                let json = try await gemini.extractBanknoteFields(image: cropped)
                let clean = extractJSON(from: json)
                let decoded = try JSONDecoder().decode(BanknoteFields.self, from: clean)
                scanned = decoded
            } catch {
                fail("AI parsing failed")
            }
            isRequesting = false
        }
    }

    private func centerCrop(image: UIImage, aspect: CGFloat) -> UIImage? {
        let cg = image.cgImage!
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)

        var cw = w
        var ch = w / aspect
        if ch > h { ch = h; cw = ch * aspect }

        let rect = CGRect(x: (w - cw)/2, y: (h - ch)/2, width: cw, height: ch)
        return cg.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    private func extractJSON(from s: String) -> Data {
        let start = s.firstIndex(of: "{")!
        let end = s.lastIndex(of: "}")!
        return Data(s[start...end].utf8)
    }

    private func fail(_ msg: String) {
        errorMessage = msg
        showError = true
        isRequesting = false
    }
}
