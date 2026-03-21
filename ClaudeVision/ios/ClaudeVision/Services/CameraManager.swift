import Foundation
import AVFoundation
import UIKit

class CameraManager: NSObject, ObservableObject, FrameSource {
    @Published var latestFrame: Data?
    @Published var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .iPhone

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "camera.processing")
    private var lastCaptureTime: Date = .distantPast
    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var isConfigured = false

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    func start() throws {
        guard !isRunning else { return }

        if !isConfigured {
            captureSession.beginConfiguration()
            // Use 1080p for sharp preview
            captureSession.sessionPreset = .hd1920x1080

            // Clear any existing inputs/outputs
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                captureSession.commitConfiguration()
                throw CameraError.noCameraAvailable
            }

            // Set 30fps on the camera device
            do {
                try camera.lockForConfiguration()
                camera.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 30)
                camera.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 30)
                // Enable auto-focus for clarity
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                // Enable auto-exposure
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            } catch {
                print("[Camera] Could not configure device: \(error)")
            }

            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            // Request high-quality pixel format
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]

            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }

            captureSession.commitConfiguration()
            isConfigured = true
        }

        connectionStatus = .connecting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
                self?.connectionStatus = .connected
                print("[Camera] Started — capturing frames every \(self?.frameInterval ?? 1)s")
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        captureSession.stopRunning()
        isRunning = false
        connectionStatus = .disconnected
    }

    func consumeFrame() -> Data? {
        // Return latest frame but DON'T nil it — keep it available
        // until a new frame replaces it
        let frame = latestFrame
        if frame != nil {
            print("[Camera] Consuming frame (\(frame!.count) bytes)")
        } else {
            print("[Camera] No frame available to consume")
        }
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
            self?.latestImage = uiImage
            self?.frameCount += 1
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
