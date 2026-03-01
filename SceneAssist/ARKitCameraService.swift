//  ARKitCameraService.swift
//  SceneAssist
//
//  ARSession with scene depth for LiDAR devices. Exposes camera frame and center distance in meters.

import ARKit
import AVFoundation
import CoreVideo

final class ARKitCameraService: NSObject {

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    private let queue = DispatchQueue(label: "com.sceneassist.arkit.queue")
    private var _latestFrame: CVPixelBuffer?
    private var _latestDepthMeters: Double?

    private(set) lazy var arSession: ARSession = {
        let s = ARSession()
        s.delegate = self
        s.delegateQueue = queue
        return s
    }()

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let config = ARWorldTrackingConfiguration()
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            }
            self.arSession.run(config)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.arSession.pause()
        }
        queue.sync { [weak self] in
            self?._latestFrame = nil
            self?._latestDepthMeters = nil
        }
    }

    func currentFrame() -> CVPixelBuffer? {
        queue.sync { _latestFrame }
    }

    func currentCenterDistanceMeters() -> Double? {
        queue.sync { _latestDepthMeters }
    }
}

extension ARKitCameraService: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let image = frame.capturedImage
        _latestFrame = image

        if let depthMap = frame.smoothedSceneDepth?.depthMap {
            let meters = sampleCenterDepthMeters(from: depthMap)
            if let m = meters, m > 0, m < 100 {
                _latestDepthMeters = m
            }
        }
    }

    private func sampleCenterDepthMeters(from depthMap: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        guard format == kCVPixelFormatType_DepthFloat32 else { return nil }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let cx = width / 2
        let cy = height / 2

        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let row = base.advanced(by: cy * bytesPerRow)
        let floatPtr = row.assumingMemoryBound(to: Float32.self)
        let value = Float32(floatPtr[cx])
        return Double(value)
    }
}
