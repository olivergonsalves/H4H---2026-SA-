//  SceneCameraProvider.swift
//  SceneAssist
//
//  Single camera abstraction: ARKit (with depth) when supported, else AVFoundation.

import ARKit
import AVFoundation
import CoreVideo

final class SceneCameraProvider {

    private let arkit = ARKitCameraService()
    private let av = CameraService()

    private var useARKit: Bool { ARKitCameraService.isSupported }

    var avCaptureSession: AVCaptureSession? {
        useARKit ? nil : av.session
    }

    var arSession: ARSession? {
        useARKit ? arkit.arSession : nil
    }

    func start() {
        if useARKit {
            arkit.start()
        } else {
            av.start()
        }
    }

    func stop() {
        if useARKit {
            arkit.stop()
        } else {
            av.stop()
        }
    }

    func currentFrame() -> CVPixelBuffer? {
        if useARKit {
            return arkit.currentFrame()
        } else {
            return av.currentFrame()
        }
    }

    func currentCenterDistanceMeters() -> Double? {
        if useARKit {
            return arkit.currentCenterDistanceMeters()
        } else {
            return nil
        }
    }
}
