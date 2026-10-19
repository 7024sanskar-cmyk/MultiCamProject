import Foundation
import AVFoundation
import Photos
import UIKit

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

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000
            ]
        ]

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            // Rotate landscape sensor buffer to portrait
            inp.transform = CGAffineTransform(rotationAngle: .pi / 2)

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

        // If no frames were ever written, cancel cleanly instead of crashing finishWriting()
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
    @Published var statusMessage = "Initializing 3 Rear Cameras..."

    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multicam.session.queue")
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue")

    // 3 Preview Views: Top (Telephoto), Middle (Main Wide), Bottom (Ultra-Wide)
    let telePreviewView = PreviewView()
    let widePreviewView = PreviewView()
    let ultraWidePreviewView = PreviewView()

    private var teleDataOutput: AVCaptureVideoDataOutput?
    private var wideDataOutput: AVCaptureVideoDataOutput?
    private var ultraWideDataOutput: AVCaptureVideoDataOutput?

    private let teleRecorder = SingleStreamRecorder(name: "1_Telephoto")
    private let wideRecorder = SingleStreamRecorder(name: "2_MainWide")
    private let ultraRecorder = SingleStreamRecorder(name: "3_UltraWide")

    private var activeStreamCount = 0
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

        // Pre-request both Camera and Photos permissions upfront so stopping never crashes
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

    // Selects a low-bandwidth MultiCam format (prefers binned 720p/1080p) so all 3 rear cameras fit under hardwareCost 1.0
    private func configureLowCostMultiCamFormat(for device: AVCaptureDevice, prefer720p: Bool) -> Bool {
        let multiCamFormats = device.formats.filter { $0.isMultiCamSupported }
        guard !multiCamFormats.isEmpty else { return false }

        let targetWidth: Int32 = prefer720p ? 1280 : 1920
        let targetHeight: Int32 = prefer720p ? 720 : 1080

        let matchingFormats = multiCamFormats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == targetWidth && dims.height == targetHeight && format.isVideoBinned
        }

        let fallbackFormats = multiCamFormats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == targetWidth && dims.height == targetHeight
        }

        guard let chosenFormat = matchingFormats.first ?? fallbackFormats.first ?? multiCamFormats.first else {
            return false
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosenFormat
            // 30 fps cap to conserve ISP bandwidth across 3 sensors
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    private func addRearCamera(
        deviceType: AVCaptureDevice.DeviceType,
        previewLayer: AVCaptureVideoPreviewLayer,
        prefer720p: Bool
    ) -> AVCaptureVideoDataOutput? {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back),
              configureLowCostMultiCamFormat(for: device, prefer720p: prefer720p),
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
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

        if session.canAddOutput(dataOutput) {
            session.addOutputWithNoConnections(dataOutput)
            let dataConn = AVCaptureConnection(inputPorts: [port], output: dataOutput)
            if session.canAddConnection(dataConn) {
                session.addConnection(dataConn)
                return dataOutput
            }
        }

        return nil
    }

    private func setupSession() {
        let teleLayer = telePreviewView.videoPreviewLayer
        let wideLayer = widePreviewView.videoPreviewLayer
        let ultraLayer = ultraWidePreviewView.videoPreviewLayer

        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.statusMessage = "Multi-cam not supported on this iPhone."
                }
                return
            }

            var objcError: NSError?
            let success = ObjCExceptionCatcher.tryExecute({
                self.session.beginConfiguration()

                var count = 0

                // 1. TOP: Telephoto Camera (720p binned to save ISP bandwidth)
                if let out = self.addRearCamera(deviceType: .builtInTelephotoCamera, previewLayer: teleLayer, prefer720p: true) {
                    self.teleDataOutput = out
                    count += 1
                }

                // 2. MIDDLE: Main Wide Camera (1080p binned)
                if let out = self.addRearCamera(deviceType: .builtInWideAngleCamera, previewLayer: wideLayer, prefer720p: true) {
                    self.wideDataOutput = out
                    count += 1
                }

                // 3. BOTTOM: Ultra-Wide Camera (720p binned)
                if let out = self.addRearCamera(deviceType: .builtInUltraWideCamera, previewLayer: ultraLayer, prefer720p: true) {
                    self.ultraWideDataOutput = out
                    count += 1
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                let cost = Int(self.session.hardwareCost * 100)
                DispatchQueue.main.async {
                    self.isConfigured = true
                    self.activeStreamCount = count
                    self.isRunning = self.session.isRunning
                    self.statusMessage = "Active: \(count)/3 Rear Cameras (ISP Load: \(cost)%)"
                }
            }, error: &objcError)

            if !success, let err = objcError {
                DispatchQueue.main.async {
                    self.statusMessage = "ISP Limit: \(err.localizedDescription)"
                }
            }
        }
    }

    func startRecording() {
        dataOutputQueue.async {
            guard !self.isRecording else { return }

            var startedAny = false
            if self.teleDataOutput != nil {
                if self.teleRecorder.prepare(width: 1280, height: 720) { startedAny = true }
            }
            if self.wideDataOutput != nil {
                if self.wideRecorder.prepare(width: 1280, height: 720) { startedAny = true }
            }
            if self.ultraWideDataOutput != nil {
                if self.ultraRecorder.prepare(width: 1280, height: 720) { startedAny = true }
            }

            if startedAny {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording \(self.activeStreamCount) rear cameras..."
                }
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to initialize video writers."
                }
            }
        }
    }

    func stopRecording() {
        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false

            DispatchQueue.main.async {
                self.statusMessage = "Finishing & saving videos..."
            }

            let group = DispatchGroup()
            var finishedURLs: [URL] = []
            let lock = NSLock()

            let recorders = [self.teleRecorder, self.wideRecorder, self.ultraRecorder]
            for rec in recorders {
                group.enter()
                rec.finish { url in
                    if let validURL = url {
                        lock.lock()
                        finishedURLs.append(validURL)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.saveVideosToPhotos(urls: finishedURLs)
            }
        }
    }

    private func saveVideosToPhotos(urls: [URL]) {
        guard !urls.isEmpty else {
            self.statusMessage = "No video frames were captured."
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.statusMessage = "Allow Photos permission in Settings to save!"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.statusMessage = "Saved \(urls.count) videos to Photos!"
                    } else {
                        self.statusMessage = "Save Error: \(error?.localizedDescription ?? "Unknown")"
                    }
                }
            }
        }
    }
}

extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }

        if output == teleDataOutput {
            teleRecorder.append(sampleBuffer)
        } else if output == wideDataOutput {
            wideRecorder.append(sampleBuffer)
        } else if output == ultraWideDataOutput {
            ultraRecorder.append(sampleBuffer)
        }
    }
}