import Foundation
import AVFoundation
import Photos
import UIKit

enum FourKCameraChoice: String, CaseIterable {
    case telephoto = "Tele 4K"
    case mainWide = "Main 4K"
    case ultraWide = "Ultra 4K"
}

// Independent thread-safe recorder for a single camera stream
class SingleStreamRecorder {
    let name: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var isSessionStarted = false
    private(set) var outputURL: URL?

    init(name: String) {
        self.name = name
    }

    func prepare(width: Int, height: Int) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).mp4")
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url
        self.isSessionStarted = false

        let bitrate = (width == 3840) ? 30_000_000 : 10_000_000

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate
            ]
        ]

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            inp.transform = .identity

            if w.canAdd(inp) {
                w.add(inp)
            }
            if w.startWriting() {
                self.writer = w
                self.input = inp
                return true
            }
        } catch {
            print("\(name) writer error: \(error)")
        }
        return false
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = writer, writer.status == .writing, let input = input else { return }

        if !isSessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            isSessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        guard let writer = writer else {
            completion(nil)
            return
        }

        guard isSessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            self.writer = nil
            self.input = nil
            completion(nil)
            return
        }

        input?.markAsFinished()
        let url = self.outputURL
        writer.finishWriting {
            let success = (writer.status == .completed)
            self.writer = nil
            self.input = nil
            completion(success ? url : nil)
        }
    }
}

class MultiCamRecorder: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var isTorchOn = false
    @Published var selected4K: FourKCameraChoice = .telephoto {
        didSet {
            // Reconfigure session when 4K target changes
            restartSession()
        }
    }
    @Published var statusMessage = "Configuring Cameras..."

    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multicam.session.queue")
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue")

    let telePreviewView = PreviewView()
    let widePreviewView = PreviewView()
    let ultraWidePreviewView = PreviewView()

    private var teleDataOutput: AVCaptureVideoDataOutput?
    private var wideDataOutput: AVCaptureVideoDataOutput?
    private var ultraWideDataOutput: AVCaptureVideoDataOutput?

    private var mainWideDevice: AVCaptureDevice?

    private let teleRecorder = SingleStreamRecorder(name: "1_Telephoto")
    private let wideRecorder = SingleStreamRecorder(name: "2_MainWide")
    private let ultraRecorder = SingleStreamRecorder(name: "3_UltraWide")

    private var isConfigured = false

    override init() {
        super.init()
    }

    func startCameraSetup() {
        guard !isConfigured else { return }

        telePreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
        widePreviewView.videoPreviewLayer.setSessionWithNoConnection(session)
        ultraWidePreviewView.videoPreviewLayer.setSessionWithNoConnection(session)

        telePreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
        widePreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill
        ultraWidePreviewView.videoPreviewLayer.videoGravity = .resizeAspectFill

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupSession()
                } else {
                    DispatchQueue.main.async { self.statusMessage = "Camera permission denied." }
                }
            }
        default:
            DispatchQueue.main.async { self.statusMessage = "Camera permission denied in Settings." }
        }
    }

    private func restartSession() {
        sessionQueue.async {
            self.session.stopRunning()
            self.setupSession()
        }
    }

    func toggleTorch() {
        sessionQueue.async {
            let devices = [
                self.mainWideDevice,
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
            ].compactMap { $0 }

            guard let device = devices.first(where: { $0.hasTorch && $0.isTorchAvailable }) else {
                DispatchQueue.main.async { self.statusMessage = "Flash unavailable." }
                return
            }

            do {
                try device.lockForConfiguration()
                let targetState = !self.isTorchOn
                if targetState {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = (device.torchMode == .on) }
            } catch {
                DispatchQueue.main.async { self.statusMessage = "Flash error." }
            }
        }
    }

    private func configureCameraFormat(for device: AVCaptureDevice, targetWidth: Int32, targetHeight: Int32, targetFps: Int32) -> Bool {
        let multiCamFormats = device.formats.filter { $0.isMultiCamSupported }
        guard !multiCamFormats.isEmpty else { return false }

        let matchingFormats = multiCamFormats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == targetWidth && dims.height == targetHeight
        }

        guard let chosenFormat = matchingFormats.first ?? multiCamFormats.first else {
            return false
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosenFormat
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    private func addRearCamera(
        deviceType: AVCaptureDevice.DeviceType,
        previewLayer: AVCaptureVideoPreviewLayer,
        targetWidth: Int32,
        targetHeight: Int32,
        targetFps: Int32
    ) -> (AVCaptureVideoDataOutput, AVCaptureDevice)? {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back),
              configureCameraFormat(for: device, targetWidth: targetWidth, targetHeight: targetHeight, targetFps: targetFps),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return nil
        }

        session.addInputWithNoConnections(input)

        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: .back).first
                ?? input.ports.first(where: { $0.mediaType == .video }) else {
            session.removeInput(input)
            return nil
        }

        let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if session.canAddConnection(previewConn) {
            session.addConnection(previewConn)
            if previewConn.isVideoOrientationSupported {
                previewConn.videoOrientation = .portrait
            }
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

        if session.canAddOutput(dataOutput) {
            session.addOutputWithNoConnections(dataOutput)
            let dataConn = AVCaptureConnection(inputPorts: [port], output: dataOutput)
            if session.canAddConnection(dataConn) {
                session.addConnection(dataConn)
                return (dataOutput, device)
            }
        }

        return nil
    }

    private func setupSession() {
        let teleLayer = telePreviewView.videoPreviewLayer
        let wideLayer = widePreviewView.videoPreviewLayer
        let ultraLayer = ultraWidePreviewView.videoPreviewLayer
        let current4K = self.selected4K

        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async { self.statusMessage = "Multi-cam not supported." }
                return
            }

            var objcError: NSError?
            let success = ObjCExceptionCatcher.tryExecute({
                self.session.beginConfiguration()

                // Remove existing inputs/outputs if restarting
                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }

                // Determine resolutions based on user selection
                let teleRes: (Int32, Int32) = (current4K == .telephoto) ? (3840, 2160) : (1920, 1080)
                let wideRes: (Int32, Int32) = (current4K == .mainWide) ? (3840, 2160) : (1920, 1080)
                let ultraRes: (Int32, Int32) = (current4K == .ultraWide) ? (3840, 2160) : (1920, 1080)

                // 1. Telephoto
                if let (out, _) = self.addRearCamera(deviceType: .builtInTelephotoCamera, previewLayer: teleLayer, targetWidth: teleRes.0, targetHeight: teleRes.1, targetFps: 30) {
                    self.teleDataOutput = out
                }

                // 2. Main Wide
                if let (out, dev) = self.addRearCamera(deviceType: .builtInWideAngleCamera, previewLayer: wideLayer, targetWidth: wideRes.0, targetHeight: wideRes.1, targetFps: 30) {
                    self.wideDataOutput = out
                    self.mainWideDevice = dev
                }

                // 3. Ultra-Wide
                if let (out, _) = self.addRearCamera(deviceType: .builtInUltraWideCamera, previewLayer: ultraLayer, targetWidth: ultraRes.0, targetHeight: ultraRes.1, targetFps: 30) {
                    self.ultraWideDataOutput = out
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.isConfigured = true
                    self.isRunning = self.session.isRunning
                    self.statusMessage = "4K Target: \(current4K.rawValue)"
                }
            }, error: &objcError)

            if !success, let err = objcError {
                DispatchQueue.main.async { self.statusMessage = "ISP Limit: \(err.localizedDescription)" }
            }
        }
    }

    func startRecording() {
        dataOutputQueue.async {
            guard !self.isRecording else { return }

            let teleDim = (self.selected4K == .telephoto) ? (3840, 2160) : (1920, 1080)
            let wideDim = (self.selected4K == .mainWide) ? (3840, 2160) : (1920, 1080)
            let ultraDim = (self.selected4K == .ultraWide) ? (3840, 2160) : (1920, 1080)

            var startedAny = false
            if self.teleDataOutput != nil {
                if self.teleRecorder.prepare(width: teleDim.0, height: teleDim.1) { startedAny = true }
            }
            if self.wideDataOutput != nil {
                if self.wideRecorder.prepare(width: wideDim.0, height: wideDim.1) { startedAny = true }
            }
            if self.ultraWideDataOutput != nil {
                if self.ultraRecorder.prepare(width: ultraDim.0, height: ultraDim.1) { startedAny = true }
            }

            if startedAny {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording..."
                }
            } else {
                DispatchQueue.main.async { self.statusMessage = "Recorder init failed." }
            }
        }
    }

    func stopRecording() {
        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false

            DispatchQueue.main.async { self.statusMessage = "Saving recordings..." }

            let group = DispatchGroup()
            var teleURL: URL?
            var wideURL: URL?
            var ultraURL: URL?

            group.enter(); self.teleRecorder.finish { teleURL = $0; group.leave() }
            group.enter(); self.wideRecorder.finish { wideURL = $0; group.leave() }
            group.enter(); self.ultraRecorder.finish { ultraURL = $0; group.leave() }

            group.notify(queue: .main) {
                let allURLs = [teleURL, wideURL, ultraURL].compactMap { $0 }
                self.saveVideosToPhotos(urls: allURLs)
            }
        }
    }

    private func saveVideosToPhotos(urls: [URL]) {
        guard !urls.isEmpty else {
            self.statusMessage = "No video frames captured."
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    self.statusMessage = success ? "Saved \(urls.count) videos to Photos!" : "Save error."
                }
            }
        }
    }
}

extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }
        if output == teleDataOutput { teleRecorder.append(sampleBuffer) }
        else if output == wideDataOutput { wideRecorder.append(sampleBuffer) }
        else if output == ultraWideDataOutput { ultraRecorder.append(sampleBuffer) }
    }
}