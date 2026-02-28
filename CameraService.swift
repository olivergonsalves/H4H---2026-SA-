import AVFoundation
import UIKit
import CoreVideo

final class CameraService: NSObject {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let frameQueue = DispatchQueue(label: "camera.frame.queue")

    private var videoOutput = AVCaptureVideoDataOutput()
    private var latestPixelBuffer: CVPixelBuffer?

    override init() {
        super.init()
    }

    func start() {
        sessionQueue.async {
            self.configureSession()
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // This lets us grab the latest camera frame whenever we want
    func currentFrame() -> CVPixelBuffer? {
        frameQueue.sync { latestPixelBuffer }
    }

    private func configureSession() {
        if session.isRunning { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                  for: .video,
                                                  position: .back) else {
            print("❌ No back camera found")
            session.commitConfiguration()
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: camera) else {
            print("❌ Could not create camera input")
            session.commitConfiguration()
            return
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            print("❌ Cannot add camera input")
            session.commitConfiguration()
            return
        }

        // Video output setup
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        // ✅ This line makes frames come to captureOutput(...)
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            print("❌ Cannot add video output")
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()
        print("✅ Camera session configured")
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestPixelBuffer = pb
    }
}
