import Foundation
import AVFoundation
import UIKit

class CameraManager: NSObject, ObservableObject, FrameSource {
    @Published var latestFrame: Data?
    @Published private(set) var isRunning: Bool = false

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "camera.processing")
    private var lastCaptureTime: Date = .distantPast
    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    func start() throws {
        guard !isRunning else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .medium

        // Add camera input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            throw CameraError.noCameraAvailable
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        // Add video output
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        captureSession.stopRunning()
        isRunning = false
        latestFrame = nil
    }

    func consumeFrame() -> Data? {
        let frame = latestFrame
        latestFrame = nil
        return frame
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) >= frameInterval else { return }
        lastCaptureTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: jpegQuality) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.latestFrame = jpegData
        }
    }
}

enum CameraError: LocalizedError {
    case noCameraAvailable

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available on this device"
        }
    }
}
