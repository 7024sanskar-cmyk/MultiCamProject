import Foundation
import AVFoundation
import Photos
import UIKit

class MultiCamRecorder: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var statusMessage = "Tap 'Start Cameras' to begin"
    
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
    private var isConfigured = false
    
    override init() {
        super.init()
    }
    
    func startCameraSetup() {
        guard !isConfigured else { return }
        statusMessage = "Checking permissions..."
        
        // Link preview layers on Main Thread BEFORE touching background queue
        backPreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
        frontPreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
        backPreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupSession()
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Camera permission denied."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.statusMessage = "Camera permission denied in Settings."
            }
        }
    }
    
    private func configureMultiCamFormat(for device: AVCaptureDevice) -> Bool {
        // Find a 1080p format that explicitly supports MultiCam
        let supportedFormats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.isMultiCamSupported && dimensions.width == 1920 && dimensions.height == 1080
        }
        
        guard let bestFormat = supportedFormats.first ?? device.formats.first(where: { $0.isMultiCamSupported }) else {
            return false
        }
        
        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }
    
    private func setupSession() {
        let backLayer = backPreviewView.videoPreviewLayer
        let frontLayer = frontPreviewView.videoPreviewLayer
        
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.statusMessage = "Multi-cam not supported on this iPhone model."
                }
                return
            }
            
            var objcError: NSError?
            let success = ObjCExceptionCatcher.tryExecute({
                self.session.beginConfiguration()
                
                // 1. Back Camera
                guard let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      self.configureMultiCamFormat(for: backDevice),
                      let backInput = try? AVCaptureDeviceInput(device: backDevice),
                      self.session.canAddInput(backInput) else {
                    DispatchQueue.main.async { self.statusMessage = "Back camera setup failed." }
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInputWithNoConnections(backInput)
                
                guard let backPort = backInput.ports(for: .video, sourceDeviceType: backDevice.deviceType, sourceDevicePosition: .back).first ?? backInput.ports.first else {
                    DispatchQueue.main.async { self.statusMessage = "No back video port." }
                    self.session.commitConfiguration()
                    return
                }
                
                let backPreviewConn = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: backLayer)
                if self.session.canAddConnection(backPreviewConn) {
                    self.session.addConnection(backPreviewConn)
                }
                
                let bOutput = AVCaptureVideoDataOutput()
                bOutput.alwaysDiscardsLateVideoFrames = true
                bOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
                if self.session.canAddOutput(bOutput) {
                    self.session.addOutputWithNoConnections(bOutput)
                    self.backDataOutput = bOutput
                    let backDataConn = AVCaptureConnection(inputPorts: [backPort], output: bOutput)
                    if self.session.canAddConnection(backDataConn) {
                        self.session.addConnection(backDataConn)
                    }
                }
                
                // 2. Front Camera
                guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                      self.configureMultiCamFormat(for: frontDevice),
                      let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
                      self.session.canAddInput(frontInput) else {
                    DispatchQueue.main.async { self.statusMessage = "Front camera setup failed." }
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInputWithNoConnections(frontInput)
                
                guard let frontPort = frontInput.ports(for: .video, sourceDeviceType: frontDevice.deviceType, sourceDevicePosition: .front).first ?? frontInput.ports.first else {
                    DispatchQueue.main.async { self.statusMessage = "No front video port." }
                    self.session.commitConfiguration()
                    return
                }
                
                let frontPreviewConn = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontLayer)
                if self.session.canAddConnection(frontPreviewConn) {
                    self.session.addConnection(frontPreviewConn)
                }
                
                let fOutput = AVCaptureVideoDataOutput()
                fOutput.alwaysDiscardsLateVideoFrames = true
                fOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)
                if self.session.canAddOutput(fOutput) {
                    self.session.addOutputWithNoConnections(fOutput)
                    self.frontDataOutput = fOutput
                    let frontDataConn = AVCaptureConnection(inputPorts: [frontPort], output: fOutput)
                    if self.session.canAddConnection(frontDataConn) {
                        self.session.addConnection(frontDataConn)
                    }
                }
                
                self.session.commitConfiguration()
                self.session.startRunning()
                
                DispatchQueue.main.async {
                    self.isConfigured = true
                    self.isRunning = self.session.isRunning
                    self.statusMessage = self.isRunning ? "Ready (1080p 30fps)" : "Session failed to start"
                }
            }, error: &objcError)
            
            if !success, let err = objcError {
                DispatchQueue.main.async {
                    self.statusMessage = "Hardware Error: \(err.localizedDescription)"
                }
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
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080
            ]
            
            do {
                let bWriter = try AVAssetWriter(outputURL: backURL, fileType: .mp4)
                let bInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                bInput.expectsMediaDataInRealTime = true
                bInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
                if bWriter.canAdd(bInput) { bWriter.add(bInput) }
                self.backAssetWriter = bWriter
                self.backWriterInput = bInput
                
                let fWriter = try AVAssetWriter(outputURL: frontURL, fileType: .mp4)
                let fInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                fInput.expectsMediaDataInRealTime = true
                fInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
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
                DispatchQueue.main.async {
                    self.statusMessage = "Writer Error: \(error.localizedDescription)"
                }
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
                self.statusMessage = "Saved both videos to Photos!"
            }
        }
    }
    
    private func saveVideos() {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                return
            }
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