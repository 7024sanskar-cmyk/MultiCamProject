import Foundation
import AVFoundation
import Photos
import UIKit

class MultiCamRecorder: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var statusMessage = "Initializing..."
    
    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multicam.session.queue")
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue")
    
    let backPreviewView = PreviewView()
    let frontPreviewView = PreviewView()
    
    private var backDataOutput: AVCaptureVideoDataOutput?
    private var frontDataOutput: AVCaptureVideoDataOutput?
    
    private var backAssetWriter: AVAssetWriter?
    private var frontAssetWriter: AVAssetWriter?
    private var backWriterInput: AVAssetWriterInput?
    private var frontWriterInput: AVAssetWriterInput?
    
    private var backOutputURL: URL?
    private var frontOutputURL: URL?
    private var isWritingStarted = false
    
    override init() {
        super.init()
    }
    
    func startCameraSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupSession()
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Camera access denied in Settings."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.statusMessage = "Camera access denied in Settings."
            }
        }
    }
    
    private func setupSession() {
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.statusMessage = "Multi-cam not supported on this iPhone."
                }
                return
            }
            
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            
            // 1. Back Camera Configuration
            guard let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let backInput = try? AVCaptureDeviceInput(device: backDevice),
                  self.session.canAddInput(backInput) else {
                DispatchQueue.main.async { self.statusMessage = "Failed to load back camera." }
                return
            }
            self.session.addInputWithNoConnections(backInput)
            
            // Find back video port
            guard let backVideoPort = backInput.ports.first(where: { $0.mediaType == .video }) else {
                DispatchQueue.main.async { self.statusMessage = "No back camera video port." }
                return
            }
            
            // Connect Back Preview Layer Safely
            DispatchQueue.main.sync {
                self.backPreviewView.videoPreviewLayer.setSessionWithNoConnection(self.session)
            }
            let backPreviewConnection = AVCaptureConnection(inputPort: backVideoPort, videoPreviewLayer: self.backPreviewView.videoPreviewLayer)
            if self.session.canAddConnection(backPreviewConnection) {
                self.session.addConnection(backPreviewConnection)
            }
            
            // Back Data Output (for recording)
            let bOutput = AVCaptureVideoDataOutput()
            bOutput.alwaysDiscardsLateVideoFrames = true
            bOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
            if self.session.canAddOutput(bOutput) {
                self.session.addOutputWithNoConnections(bOutput)
                self.backDataOutput = bOutput
            }
            
            let backDataConnection = AVCaptureConnection(inputPorts: [backVideoPort], output: bOutput)
            if self.session.canAddConnection(backDataConnection) {
                self.session.addConnection(backDataConnection)
                if backDataConnection.isVideoOrientationSupported {
                    backDataConnection.videoOrientation = .portrait
                }
            }
            
            // 2. Front Camera Configuration
            guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
                  self.session.canAddInput(frontInput) else {
                DispatchQueue.main.async { self.statusMessage = "Failed to load front camera." }
                return
            }
            self.session.addInputWithNoConnections(frontInput)
            
            // Find front video port
            guard let frontVideoPort = frontInput.ports.first(where: { $0.mediaType == .video }) else {
                DispatchQueue.main.async { self.statusMessage = "No front camera video port." }
                return
            }
            
            // Connect Front Preview Layer Safely
            DispatchQueue.main.sync {
                self.frontPreviewView.videoPreviewLayer.setSessionWithNoConnection(self.session)
            }
            let frontPreviewConnection = AVCaptureConnection(inputPort: frontVideoPort, videoPreviewLayer: self.frontPreviewView.videoPreviewLayer)
            if self.session.canAddConnection(frontPreviewConnection) {
                self.session.addConnection(frontPreviewConnection)
                if frontPreviewConnection.isVideoMirroringSupported {
                    frontPreviewConnection.isVideoMirrored = true
                }
            }
            
            // Front Data Output (for recording)
            let fOutput = AVCaptureVideoDataOutput()
            fOutput.alwaysDiscardsLateVideoFrames = true
            fOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
            if self.session.canAddOutput(fOutput) {
                self.session.addOutputWithNoConnections(fOutput)
                self.frontDataOutput = fOutput
            }
            
            let frontDataConnection = AVCaptureConnection(inputPorts: [frontVideoPort], output: fOutput)
            if self.session.canAddConnection(frontDataConnection) {
                self.session.addConnection(frontDataConnection)
                if frontDataConnection.isVideoOrientationSupported {
                    frontDataConnection.videoOrientation = .portrait
                }
                if frontDataConnection.isVideoMirroringSupported {
                    frontDataConnection.isVideoMirrored = true
                }
            }
            
            DispatchQueue.main.async {
                self.backPreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
                self.frontPreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
                self.statusMessage = ""
            }
            
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
            }
        }
    }
    
    func startRecording() {
        dataOutputQueue.async {
            guard !self.isRecording else { return }
            
            let tempDir = FileManager.default.temporaryDirectory
            let backURL = tempDir.appendingPathComponent("Back_\(UUID().uuidString).mp4")
            let frontURL = tempDir.appendingPathComponent("Front_\(UUID().uuidString).mp4")
            
            self.backOutputURL = backURL
            self.frontOutputURL = frontURL
            
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920
            ]
            
            do {
                let bWriter = try AVAssetWriter(outputURL: backURL, fileType: .mp4)
                let bInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                bInput.expectsMediaDataInRealTime = true
                if bWriter.canAdd(bInput) { bWriter.add(bInput) }
                self.backAssetWriter = bWriter
                self.backWriterInput = bInput
                
                let fWriter = try AVAssetWriter(outputURL: frontURL, fileType: .mp4)
                let fInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                fInput.expectsMediaDataInRealTime = true
                if fWriter.canAdd(fInput) { fWriter.add(fInput) }
                self.frontAssetWriter = fWriter
                self.frontWriterInput = fInput
                
                self.backAssetWriter?.startWriting()
                self.frontAssetWriter?.startWriting()
                self.isWritingStarted = false
                
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording..."
                }
            } catch {
                print("Writer error: \(error)")
            }
        }
    }
    
    func stopRecording() {
        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            
            self.backWriterInput?.markAsFinished()
            self.frontWriterInput?.markAsFinished()
            
            let group = DispatchGroup()
            if let bw = self.backAssetWriter {
                group.enter()
                bw.finishWriting { group.leave() }
            }
            if let fw = self.frontAssetWriter {
                group.enter()
                fw.finishWriting { group.leave() }
            }
            
            group.notify(queue: .main) {
                self.saveVideos()
                self.statusMessage = "Saved to Photos."
            }
        }
    }
    
    private func saveVideos() {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else { return }
            if let bURL = self.backOutputURL {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: bURL)
                })
            }
            if let fURL = self.frontOutputURL {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fURL)
                })
            }
        }
    }
}

extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        if !isWritingStarted {
            backAssetWriter?.startSession(atSourceTime: timestamp)
            frontAssetWriter?.startSession(atSourceTime: timestamp)
            isWritingStarted = true
        }
        
        if output == backDataOutput, let input = backWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        } else if output == frontDataOutput, let input = frontWriterInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}