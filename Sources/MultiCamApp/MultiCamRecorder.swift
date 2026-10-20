import Foundation
import AVFoundation
import UIKit

enum AvailableCamera: String, CaseIterable, Identifiable {
    case telephoto = "Telephoto"
    case mainWide = "Main Wide"
    case ultraWide = "Ultra Wide"
    case front = "Front Camera"
    
    var id: String { rawValue }
}

enum StreamResolution: String, CaseIterable {
    case res1080p = "1080p"
    case res4K = "4K"
}

class SingleStreamRecorder {
    let name: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var isSessionStarted = false
    private(set) var outputURL: URL?

    init(name: String) { self.name = name }

    func prepare(width: Int, height: Int) -> Bool {
        let tempDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = tempDir.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).mp4")
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url
        self.isSessionStarted = false

        let bitrate = (width >= 3840) ? 30_000_000 : 10_000_000
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ]

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            inp.transform = .identity

            if w.canAdd(inp) { w.add(inp) }
            if w.startWriting() {
                self.writer = w
                self.input = inp
                return true
            }
        } catch { print("\(name) writer error: \(error)") }
        return false
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = writer, writer.status == .writing, let input = input else { return }
        if !isSessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            isSessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        guard let writer = writer else { completion(nil); return }
        guard isSessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            self.writer = nil; self.input = nil
            completion(nil)
            return
        }
        input?.markAsFinished()
        let url = self.outputURL
        writer.finishWriting {
            let success = (writer.status == .completed)
            self.writer = nil; self.input = nil
            completion(success ? url : nil)
        }
    }
}

class MultiCamRecorder: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var isTorchOn = false
    @Published var selectedCameras: [AvailableCamera] = [.mainWide, .telephoto]
    @Published var selectedResolution: StreamResolution = .res1080p
    @Published var activeCameraCount: Int = 2
    @Published var statusMessage = "Starting Cameras..."

    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multicam.session.queue")
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue")

    let previewView1 = PreviewView()
    let previewView2 = PreviewView()
    let previewView3 = PreviewView()

    private var output1: AVCaptureVideoDataOutput?
    private var output2: AVCaptureVideoDataOutput?
    private var output3: AVCaptureVideoDataOutput?
    private var mainWideDevice: AVCaptureDevice?

    private let recorder1 = SingleStreamRecorder(name: "Stream_1")
    private let recorder2 = SingleStreamRecorder(name: "Stream_2")
    private let recorder3 = SingleStreamRecorder(name: "Stream_3")

    private var isConfiguring = false

    override init() {
        super.init()
    }

    func startCameraSetup() {
        DispatchQueue.main.async {
            self.previewView1.videoPreviewLayer.videoGravity = .resizeAspectFill
            self.previewView2.videoPreviewLayer.videoGravity = .resizeAspectFill
            self.previewView3.videoPreviewLayer.videoGravity = .resizeAspectFill
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            applyCameraSelection()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.applyCameraSelection()
                } else {
                    DispatchQueue.main.async { self.statusMessage = "Camera permission denied." }
                }
            }
        default:
            DispatchQueue.main.async { self.statusMessage = "Camera permission denied in Settings." }
        }
    }

    func toggleResolution() {
        guard !isRecording else { return }
        selectedResolution = (selectedResolution == .res1080p) ? .res4K : .res1080p
        applyCameraSelection()
    }

    func applyCameraSelection() {
        sessionQueue.async {
            guard !self.isConfiguring else { return }
            self.isConfiguring = true

            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.statusMessage = "MultiCam not supported on this device."
                    self.isConfiguring = false
                }
                return
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            var objcError: NSError?
            let success = ObjCExceptionCatcher.tryExecute({
                self.session.beginConfiguration()

                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }

                self.output1 = nil
                self.output2 = nil
                self.output3 = nil

                let camerasToConfigure = Array(self.selectedCameras.prefix(3))
                let previewLayers = [
                    self.previewView1.videoPreviewLayer,
                    self.previewView2.videoPreviewLayer,
                    self.previewView3.videoPreviewLayer
                ]

                var count = 0
                for (index, camChoice) in camerasToConfigure.enumerated() {
                    let layer = previewLayers[index]
                    if let out = self.addCameraSafe(choice: camChoice, previewLayer: layer) {
                        if index == 0 { self.output1 = out }
                        else if index == 1 { self.output2 = out }
                        else if index == 2 { self.output3 = out }
                        count += 1
                    }
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.activeCameraCount = count
                    self.isRunning = self.session.isRunning
                    self.statusMessage = "Active: \(count) Lenses | Target: \(self.selectedResolution.rawValue)"
                    self.isConfiguring = false
                }
            }, error: &objcError)

            if !success, let err = objcError {
                DispatchQueue.main.async {
                    self.statusMessage = "ISP Limit: \(err.localizedDescription)"
                    self.isConfiguring = false
                }
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async {
            let devices = [self.mainWideDevice, AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)].compactMap { $0 }
            guard let device = devices.first(where: { $0.hasTorch && $0.isTorchAvailable }) else { return }
            do {
                try device.lockForConfiguration()
                let targetState = !self.isTorchOn
                if targetState { try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) }
                else { device.torchMode = .off }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = (device.torchMode == .on) }
            } catch {}
        }
    }

    private func configureCameraFormat(for device: AVCaptureDevice, targetWidth: Int32, targetHeight: Int32, targetFps: Int32) -> Bool {
        let multiCamFormats = device.formats.filter { $0.isMultiCamSupported }
        guard !multiCamFormats.isEmpty else { return false }

        let matching = multiCamFormats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == targetWidth && dims.height == targetHeight
        }

        guard let chosen = matching.first ?? multiCamFormats.first else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.unlockForConfiguration()
            return true
        } catch { return false }
    }

    private func addCameraSafe(choice: AvailableCamera, previewLayer: AVCaptureVideoPreviewLayer) -> AVCaptureVideoDataOutput? {
        var device: AVCaptureDevice?
        var position: AVCaptureDevice.Position = .back
        
        // Base resolution is 1080p, elevated to 4K if preferred and supported
        var targetW: Int32 = 1920
        var targetH: Int32 = 1080

        switch choice {
        case .telephoto:
            device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
            if selectedResolution == .res4K {
                targetW = 3840; targetH = 2160
            }
        case .mainWide:
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            position = .back
            if selectedResolution == .res4K && selectedCameras.count <= 2 {
                targetW = 3840; targetH = 2160
            }
        case .ultraWide:
            device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .front:
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            position = .front
        }

        guard let camDev = device else { return nil }
        if choice == .mainWide { self.mainWideDevice = camDev }

        let mirror = (position == .front)
        guard configureCameraFormat(for: camDev, targetWidth: targetW, targetHeight: targetH, targetFps: 30),
              let input = try? AVCaptureDeviceInput(device: camDev), session.canAddInput(input) else { return nil }

        session.addInputWithNoConnections(input)

        guard let port = input.ports(for: .video, sourceDeviceType: camDev.deviceType, sourceDevicePosition: position).first
                ?? input.ports.first(where: { $0.mediaType == .video }) else {
            session.removeInput(input)
            return nil
        }

        DispatchQueue.main.sync {
            previewLayer.setSessionWithNoConnection(self.session)
        }

        let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if session.canAddConnection(previewConn) {
            session.addConnection(previewConn)
            if previewConn.isVideoOrientationSupported { previewConn.videoOrientation = .portrait }
            if mirror && previewConn.isVideoMirroringSupported { previewConn.isVideoMirrored = true }
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        if session.canAddOutput(dataOutput) {
            session.addOutputWithNoConnections(dataOutput)
            let dataConn = AVCaptureConnection(inputPorts: [port], output: dataOutput)
            if session.canAddConnection(dataConn) {
                session.addConnection(dataConn)
                if mirror && dataConn.isVideoMirroringSupported { dataConn.isVideoMirrored = true }
                return dataOutput
            }
        }
        return nil
    }

    func startRecording() {
        dataOutputQueue.async {
            guard !self.isRecording else { return }
            let cameras = Array(self.selectedCameras.prefix(3))
            var startedAny = false

            for (index, cam) in cameras.enumerated() {
                var w = 1920
                var h = 1080
                if self.selectedResolution == .res4K && (cam == .telephoto || (cam == .mainWide && cameras.count <= 2)) {
                    w = 3840; h = 2160
                }

                if index == 0 && self.output1 != nil {
                    if self.recorder1.prepare(width: w, height: h) { startedAny = true }
                } else if index == 1 && self.output2 != nil {
                    if self.recorder2.prepare(width: w, height: h) { startedAny = true }
                } else if index == 2 && self.output3 != nil {
                    if self.recorder3.prepare(width: w, height: h) { startedAny = true }
                }
            }

            if startedAny {
                DispatchQueue.main.async { self.isRecording = true; self.statusMessage = "Recording (\(self.selectedResolution.rawValue))..." }
            }
        }
    }

    func stopRecording() {
        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            DispatchQueue.main.async { self.statusMessage = "Saving..." }

            let group = DispatchGroup()
            var url1: URL?
            var url2: URL?
            var url3: URL?

            let cameras = Array(self.selectedCameras.prefix(3))
            if cameras.indices.contains(0) { group.enter(); self.recorder1.finish { url1 = $0; group.leave() } }
            if cameras.indices.contains(1) { group.enter(); self.recorder2.finish { url2 = $0; group.leave() } }
            if cameras.indices.contains(2) { group.enter(); self.recorder3.finish { url3 = $0; group.leave() } }

            group.notify(queue: .main) {
                let allURLs = [url1, url2, url3].compactMap { $0 }
                self.statusMessage = "Saved \(allURLs.count) videos (\(self.selectedResolution.rawValue))!"
            }
        }
    }
}

extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        if output == output1 { recorder1.append(sampleBuffer) }
        else if output == output2 { recorder2.append(sampleBuffer) }
        else if output == output3 { recorder3.append(sampleBuffer) }
    }
}