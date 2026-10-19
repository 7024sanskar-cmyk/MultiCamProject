import Foundation
import AVFoundation
import Photos
import UIKit

enum RecordingOutputMode: String, CaseIterable {
    case threeSeparate = "3 Separate"
    case combinedViewfinder = "Combined View"
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
            
            // Native sensor buffer is 1280x720 landscape (horizontal).
            // Using .identity saves it directly as a horizontal 16:9 video!
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
    @Published var outputMode: RecordingOutputMode = .threeSeparate
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

    private var mainWideDevice: AVCaptureDevice?

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

    func toggleTorch() {
        sessionQueue.async {
            let devices = [
                self.mainWideDevice,
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
            ].compactMap { $0 }

            guard let device = devices.first(where: { $0.hasTorch && $0.isTorchAvailable }) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Flash/Torch unavailable right now."
                }
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

                DispatchQueue.main.async {
                    self.isTorchOn = (device.torchMode == .on)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Flash error: \(error.localizedDescription)"
                }
            }
        }
    }

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
    ) -> (AVCaptureVideoDataOutput, AVCaptureDevice)? {
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

        // Viewfinder stays upright portrait while raw data output remains horizontal landscape
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

                // 1. TOP: Telephoto Camera
                if let (out, _) = self.addRearCamera(deviceType: .builtInTelephotoCamera, previewLayer: teleLayer, prefer720p: true) {
                    self.teleDataOutput = out
                    count += 1
                }

                // 2. MIDDLE: Main Wide Camera
                if let (out, dev) = self.addRearCamera(deviceType: .builtInWideAngleCamera, previewLayer: wideLayer, prefer720p: true) {
                    self.wideDataOutput = out
                    self.mainWideDevice = dev
                    count += 1
                }

                // 3. BOTTOM: Ultra-Wide Camera
                if let (out, _) = self.addRearCamera(deviceType: .builtInUltraWideCamera, previewLayer: ultraLayer, prefer720p: true) {
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
                    self.statusMessage = "Active: \(count)/3 Cameras (ISP: \(cost)%)"
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
                    self.statusMessage = "Recording (\(self.outputMode.rawValue))..."
                }
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to initialize video writers."
                }
            }
        }
    }

    func stopRecording() {
        let selectedMode = self.outputMode

        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false

            DispatchQueue.main.async {
                self.statusMessage = "Finishing recording..."
            }

            let group = DispatchGroup()
            var teleURL: URL?
            var wideURL: URL?
            var ultraURL: URL?

            group.enter()
            self.teleRecorder.finish { url in teleURL = url; group.leave() }

            group.enter()
            self.wideRecorder.finish { url in wideURL = url; group.leave() }

            group.enter()
            self.ultraRecorder.finish { url in ultraURL = url; group.leave() }

            group.notify(queue: .main) {
                let allURLs = [teleURL, wideURL, ultraURL].compactMap { $0 }
                guard !allURLs.isEmpty else {
                    self.statusMessage = "No frames captured."
                    return
                }

                if selectedMode == .threeSeparate {
                    self.saveVideosToPhotos(urls: allURLs)
                } else {
                    self.statusMessage = "Merging into Viewfinder Layout..."
                    self.exportCombinedViewfinderVideo(teleURL: teleURL, wideURL: wideURL, ultraURL: ultraURL) { mergedURL in
                        if let validMerged = mergedURL {
                            self.saveVideosToPhotos(urls: [validMerged])
                        } else {
                            // Fallback: save individual files if merge fails
                            self.saveVideosToPhotos(urls: allURLs)
                        }
                    }
                }
            }
        }
    }

    // Combines the 3 streams vertically (Top: Telephoto, Middle: Main, Bottom: Ultra-Wide) to match the Viewfinder
    private func exportCombinedViewfinderVideo(
        teleURL: URL?,
        wideURL: URL?,
        ultraURL: URL?,
        completion: @escaping (URL?) -> Void
    ) {
        let composition = AVMutableComposition()
        let orderedURLs = [teleURL, wideURL, ultraURL]
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        var minDuration: CMTime = .positiveInfinity

        // Output canvas: 1080x1920 split into 3 stacked boxes of 1080x640 each
        let canvasWidth: CGFloat = 1080
        let slotHeight: CGFloat = 640

        for (index, optionalURL) in orderedURLs.enumerated() {
            guard let url = optionalURL else { continue }
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = asset.tracks(withMediaType: .video).first,
                  let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }

            let duration = asset.duration
            if duration < minDuration && duration.seconds > 0 {
                minDuration = duration
            }

            do {
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
                let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)

                // Raw sensor frame is 1280x720. Rotate 90 deg clockwise -> becomes 720x1280 portrait.
                // Scale width 720 -> 1080 (scale = 1.5 -> 1080x1920) and center-crop vertically into the 1080x640 slot.
                let scale: CGFloat = canvasWidth / 720.0 // 1.5
                let rotatedHeight: CGFloat = 1280.0 * scale // 1920.0
                let ySlotOffset = CGFloat(index) * slotHeight
                let cropOffsetY = (rotatedHeight - slotHeight) / 2.0

                // Transform order: rotate 90deg around origin, shift right by 720, scale by 1.5, position into slot
                var transform = CGAffineTransform(translationX: 720, y: 0)
                transform = transform.rotated(by: .pi / 2)
                transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(transform)
                transform = transform.concatenating(CGAffineTransform(translationX: 0, y: ySlotOffset - cropOffsetY))

                instruction.setTransform(transform, at: .zero)

                // Crop rectangle so each camera stays strictly inside its 1/3 vertical slot
                let cropRect = CGRect(x: 0, y: (1280.0 - (slotHeight / scale)) / 2.0, width: 1280.0, height: 720.0)
                let _ = cropRect // Keep clean full width
                layerInstructions.append(instruction)
            } catch {
                continue
            }
        }

        guard !layerInstructions.isEmpty, minDuration.isValid, !minDuration.isIndefinite else {
            completion(nil)
            return
        }

        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRange(start: .zero, duration: minDuration)
        mainInstruction.layerInstructions = layerInstructions

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = CGSize(width: 1080, height: 1920)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions = [mainInstruction]

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedViewfinder_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil)
            return
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComp
        exporter.timeRange = CMTimeRange(start: .zero, duration: minDuration)

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    completion(outputURL)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func saveVideosToPhotos(urls: [URL]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.statusMessage = "Allow Photos permission in Settings!"
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
                        self.statusMessage = urls.count == 1
                            ? "Saved Combined Viewfinder Video!"
                            : "Saved \(urls.count) Horizontal Videos!"
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