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
    
    private let backDataOutput = AVCaptureVideoDataOutput()
    private let frontDataOutput = AVCaptureVideoDataOutput()
    
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
                    self.statusMessage = "Multi-cam capture not supported on this iPhone."
                }
                return
            }
            
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            
            // 1. Setup Back Camera
            guard let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let backInput = try? AVCaptureDeviceInput(device: backDevice) else {
                DispatchQueue.main.async { self.statusMessage = "Failed to load back camera." }
                return
            }
            
            if self.session.canAddInput(backInput) {
                self.session.addInputWithNoConnections(backInput)
            }
            
            // Safe port retrieval (no forced unwrap)
            let backPorts = backInput.ports.filter { $0.mediaType == .video }
            guard let backPort = backPorts.first else {
                DispatchQueue.main.async { self.statusMessage = "No video port on back camera." }
                return
            }
            
            let backPreviewConnection = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: self.backPreviewView.videoPreviewLayer)
            if self.session.canAddConnection(backPreviewConnection) {
                self.session.addConnection(backPreviewConnection)
            }
            
            if self.session.canAddOutput(self.backDataOutput) {
                self.session.addOutputWithNoConnections(self.backDataOutput)
            }
            self.backDataOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
            
            let backDataConnection = AVCaptureConnection(inputPorts: [backPort], output: self.backDataOutput)
            if self.session.canAddConnection(backDataConnection) {
                self.session.addConnection(backDataConnection)
                backDataConnection.videoOrientation = .portrait
            }
            
            // 2. Setup Front Camera
            guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let frontInput = try? AVCaptureDeviceInput(device: frontDevice) else {
                DispatchQueue.main.async { self.statusMessage = "Failed to load front camera." }
                return
            }
            
            if self.session.canAddInput(frontInput) {
                self.session.addInputWithNoConnections(frontInput)
            }
            
            let frontPorts = frontInput.ports.filter { $0.mediaType == .video }
            guard let frontPort = frontPorts.first else {
                DispatchQueue.main.async { self.statusMessage = "No video port on front camera." }
                return
            }
            
            let frontPreviewConnection = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: self.frontPreviewView.videoPreviewLayer)
            if self.session.canAddConnection(frontPreviewConnection) {
                self.session.addConnection(frontPreviewConnection)
            }
            
            if self.session.canAddOutput(self.frontDataOutput) {
                self.session.addOutputWithNoConnections(self.frontDataOutput)
            }
            self.frontDataOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
            
            let frontDataConnection = AVCaptureConnection(inputPorts: [frontPort], output: self.frontDataOutput)
            if self.session.canAddConnection(frontDataConnection) {
                self.session.addConnection(frontDataConnection)
                frontDataConnection.videoOrientation = .portrait
                if frontDataConnection.isVideoMirroringSupported {
                    frontDataConnection.isVideoMirrored = true
                }
            }
            
            // Bind Preview Layers
            DispatchQueue.main.async {
                self.backPreviewView.videoPreviewLayer.session = self.session
                self.frontPreviewView.videoPreviewLayer.session = self.session
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
                print("Writer initialization error: \(error)")
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