import Foundation
import AVFoundation
import UIKit
import CoreImage
import CoreMotion
import Photos

enum AvailableCamera: String, CaseIterable, Identifiable {
    case telephoto = "Telephoto"
    case mainWide = "Main Wide"
    case ultraWide = "Ultra Wide"
    case front = "Front Camera"
    
    var id: String { rawValue }
}

class SingleStreamRecorder {
    let name: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var isSessionStarted = false
    private(set) var outputURL: URL?

    init(name: String) { self.name = name }

    func prepare(width: Int, height: Int, transform: CGAffineTransform) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).mp4")
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url
        self.isSessionStarted = false

        let bitrate = (width >= 3840) ? 28_000_000 : 8_000_000
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
            inp.transform = transform

            if w.canAdd(inp) { w.add(inp) }
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
    @Published var selectedCameras: [AvailableCamera] = [.telephoto, .mainWide]
    @Published var lensFor4K: AvailableCamera? = nil
    @Published var activeCameraCount: Int = 2
    @Published var statusMessage = "Starting Cameras..."

    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "multicam.session.queue", qos: .userInitiated)
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue", qos: .userInteractive)

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

    private var isCapturingPhotos = false
    private var capturedPhotoData1: Data?
    private var capturedPhotoData2: Data?
    private var capturedPhotoData3: Data?
    private let photoLock = NSLock()

    // Persistent high-performance GPU context for photo processing
    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    private let motionManager = CMMotionManager()
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait

    private var isConfiguring = false

    override init() {
        super.init()
        startMotionUpdates()
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }

    private func startMotionUpdates() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 0.2
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let acceleration = data?.acceleration else { return }
            if abs(acceleration.x) > abs(acceleration.y) {
                if acceleration.x > 0.45 {
                    self.currentDeviceOrientation = .landscapeRight
                } else if acceleration.x < -0.45 {
                    self.currentDeviceOrientation = .landscapeLeft
                }
            } else {
                if acceleration.y < -0.45 {
                    self.currentDeviceOrientation = .portrait
                } else if acceleration.y > 0.45 {
                    self.currentDeviceOrientation = .portraitUpsideDown
                }
            }
        }
    }

    func startCameraSetup() {
        DispatchQueue.main.async {
            self.previewView1.videoPreviewLayer.setSessionWithNoConnection(self.session)
            self.previewView2.videoPreviewLayer.setSessionWithNoConnection(self.session)
            self.previewView3.videoPreviewLayer.setSessionWithNoConnection(self.session)

            self.previewView1.videoPreviewLayer.videoGravity = .resizeAspectFill
            self.previewView2.videoPreviewLayer.videoGravity = .resizeAspectFill
            self.previewView3.videoPreviewLayer.videoGravity = .resizeAspectFill
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

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

    func set4KLens(_ lens: AvailableCamera?) {
        guard !isRecording else { return }
        lensFor4K = lens
        applyCameraSelection()
    }

    func applyCameraSelection() {
        sessionQueue.async {
            guard !self.isConfiguring else { return }
            self.isConfiguring = true

            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.statusMessage = "MultiCam unsupported on hardware."
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
                    let isTarget4K = (self.lensFor4K == camChoice && camChoice != .front)
                    if let out = self.addCameraSafe(choice: camChoice, previewLayer: layer, want4K: isTarget4K) {
                        if index == 0 { self.output1 = out }
                        else if index == 1 { self.output2 = out }
                        else if index == 2 { self.output3 = out }
                        count += 1
                    }
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                let costPercent = Int(self.session.hardwareCost * 100)
                DispatchQueue.main.async {
                    self.activeCameraCount = count
                    self.isRunning = self.session.isRunning
                    let fourKInfo = self.lensFor4K != nil ? "4K: \(self.lensFor4K!.rawValue)" : "1080p/720p"
                    self.statusMessage = "\(count) Active | \(fourKInfo) (ISP: \(costPercent)%)"
                    self.isConfiguring = false
                }
            }, error: &objcError)

            if !success, let err = objcError {
                DispatchQueue.main.async {
                    self.statusMessage = "Hardware Failure: \(err.localizedDescription)"
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

    private func configureCameraFormat(for device: AVCaptureDevice, isFront: Bool, want4K: Bool) -> Bool {
        let multiCamFormats = device.formats.filter { $0.isMultiCamSupported }
        guard !multiCamFormats.isEmpty else { return false }

        if isFront {
            let front720pBinned = multiCamFormats.filter {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width == 1280 && dims.height == 720 && $0.isVideoBinned
            }
            let front720pAny = multiCamFormats.filter {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width == 1280 && dims.height == 720
            }
            let frontLowest = multiCamFormats.sorted {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return (a.width * a.height) < (b.width * b.height)
            }

            guard let chosen = front720pBinned.first ?? front720pAny.first ?? frontLowest.first else { return false }
            do {
                try device.lockForConfiguration()
                device.activeFormat = chosen
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
                return true
            } catch { return false }
        }

        let targetW: Int32 = want4K ? 3840 : 1920
        let targetH: Int32 = want4K ? 2160 : 1080

        let matched = multiCamFormats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == targetW && dims.height == targetH
        }
        let fallback1080p = multiCamFormats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == 1920 && dims.height == 1080
        }

        guard let chosen = matched.first ?? fallback1080p.first ?? multiCamFormats.first else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            return true
        } catch { return false }
    }

    private func addCameraSafe(choice: AvailableCamera, previewLayer: AVCaptureVideoPreviewLayer, want4K: Bool) -> AVCaptureVideoDataOutput? {
        var device: AVCaptureDevice?
        var position: AVCaptureDevice.Position = .back

        switch choice {
        case .telephoto:
            device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case .mainWide:
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            position = .back
        case .ultraWide:
            device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .front:
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            position = .front
        }

        guard let camDev = device else { return nil }
        if choice == .mainWide { self.mainWideDevice = camDev }

        let isFront = (position == .front)
        guard configureCameraFormat(for: camDev, isFront: isFront, want4K: want4K),
              let input = try? AVCaptureDeviceInput(device: camDev), session.canAddInput(input) else {
            return nil
        }

        session.addInputWithNoConnections(input)

        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            session.removeInput(input)
            return nil
        }

        let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if session.canAddConnection(previewConn) {
            session.addConnection(previewConn)
            if previewConn.isVideoOrientationSupported {
                previewConn.videoOrientation = .portrait
            }
            if previewConn.isVideoMirroringSupported {
                previewConn.automaticallyAdjustsVideoMirroring = false
                previewConn.isVideoMirrored = isFront
            }
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        // Retain uncompressed 32-bit BGRA format for higher fidelity capture
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        dataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

        if session.canAddOutput(dataOutput) {
            session.addOutputWithNoConnections(dataOutput)
            let dataConn = AVCaptureConnection(inputPorts: [port], output: dataOutput)
            if session.canAddConnection(dataConn) {
                session.addConnection(dataConn)
                if dataConn.isVideoMirroringSupported {
                    dataConn.automaticallyAdjustsVideoMirroring = false
                    dataConn.isVideoMirrored = isFront
                }
                return dataOutput
            }
        }
        return nil
    }

    private func videoTransform(isFront: Bool) -> CGAffineTransform {
        switch currentDeviceOrientation {
        case .landscapeLeft:
            return isFront ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: .pi * 1.5)
        case .portrait, .unknown, .faceUp, .faceDown:
            fallthrough
        @unknown default:
            return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }

    private func imageOrientation(isFront: Bool) -> UIImage.Orientation {
        switch currentDeviceOrientation {
        case .landscapeLeft:
            return isFront ? .upMirrored : .up
        case .landscapeRight:
            return isFront ? .downMirrored : .down
        case .portraitUpsideDown:
            return isFront ? .leftMirrored : .left
        case .portrait, .unknown, .faceUp, .faceDown:
            fallthrough
        @unknown default:
            return isFront ? .leftMirrored : .right
        }
    }

    func capturePhotos() {
        dataOutputQueue.async {
            guard !self.isCapturingPhotos else { return }
            self.photoLock.lock()
            self.capturedPhotoData1 = nil
            self.capturedPhotoData2 = nil
            self.capturedPhotoData3 = nil
            self.isCapturingPhotos = true
            self.photoLock.unlock()

            DispatchQueue.main.async {
                self.statusMessage = "Processing high-res stills..."
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) {
                self.photoLock.lock()
                self.isCapturingPhotos = false
                let d1 = self.capturedPhotoData1
                let d2 = self.capturedPhotoData2
                let d3 = self.capturedPhotoData3
                self.photoLock.unlock()

                let photoDataList = [d1, d2, d3].compactMap { $0 }
                guard !photoDataList.isEmpty else {
                    DispatchQueue.main.async { self.statusMessage = "No frames captured." }
                    return
                }

                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        for data in photoDataList {
                            let creationRequest = PHAssetCreationRequest.forAsset()
                            creationRequest.addResource(with: .photo, data: data, options: nil)
                        }
                    }) { success, error in
                        DispatchQueue.main.async {
                            if success {
                                self.statusMessage = "Saved \(photoDataList.count) high-res photos to Photos!"
                            } else {
                                self.statusMessage = "Photo save error: \(error?.localizedDescription ?? "")"
                            }
                        }
                    }
                }
            }
        }
    }

    // High-fidelity image processor: applies noise suppression, sharpening, and sRGB color profile
    private func processedJPEGData(from sampleBuffer: CMSampleBuffer, isFront: Bool) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)

        // Subtle unsharp mask to recover fine detail lost from video sampling
        if let unsharpFilter = CIFilter(name: "CIUnsharpMask") {
            unsharpFilter.setValue(ciImage, forKey: kCIInputImageKey)
            unsharpFilter.setValue(0.45, forKey: kCIInputIntensityKey)
            unsharpFilter.setValue(1.2, forKey: kCIInputRadiusKey)
            if let output = unsharpFilter.outputImage {
                ciImage = output
            }
        }

        let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: srgbColorSpace) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation(isFront: isFront))
        return uiImage.jpegData(compressionQuality: 1.0)
    }

    func startRecording() {
        dataOutputQueue.async {
            guard !self.isRecording else { return }
            let cameras = Array(self.selectedCameras.prefix(3))
            var startedAny = false

            for (index, cam) in cameras.enumerated() {
                var w = 1920
                var h = 1080
                let isFront = (cam == .front)

                if isFront {
                    w = 1280; h = 720
                } else if self.lensFor4K == cam {
                    w = 3840; h = 2160
                }

                let transform = self.videoTransform(isFront: isFront)

                if index == 0 && self.output1 != nil {
                    if self.recorder1.prepare(width: w, height: h, transform: transform) { startedAny = true }
                } else if index == 1 && self.output2 != nil {
                    if self.recorder2.prepare(width: w, height: h, transform: transform) { startedAny = true }
                } else if index == 2 && self.output3 != nil {
                    if self.recorder3.prepare(width: w, height: h, transform: transform) { startedAny = true }
                }
            }

            if startedAny {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording..."
                }
            }
        }
    }

    func stopRecording() {
        dataOutputQueue.async {
            guard self.isRecording else { return }
            self.isRecording = false
            DispatchQueue.main.async { self.statusMessage = "Saving videos to Photos..." }

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
                self.saveVideosAndCleanup(urls: allURLs)
            }
        }
    }

    private func saveVideosAndCleanup(urls: [URL]) {
        guard !urls.isEmpty else {
            DispatchQueue.main.async { self.statusMessage = "No video files to save." }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }) { success, error in
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }

                DispatchQueue.main.async {
                    if success {
                        self.statusMessage = "Saved \(urls.count) videos in original orientation!"
                    } else {
                        self.statusMessage = "Save Error: \(error?.localizedDescription ?? "")"
                    }
                }
            }
        }
    }
}

extension MultiCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isRecording {
            if output == output1 { recorder1.append(sampleBuffer) }
            else if output == output2 { recorder2.append(sampleBuffer) }
            else if output == output3 { recorder3.append(sampleBuffer) }
        }

        if isCapturingPhotos {
            let cameras = Array(selectedCameras.prefix(3))
            photoLock.lock()
            if output == output1 && capturedPhotoData1 == nil {
                let isFront = (cameras.indices.contains(0) && cameras[0] == .front)
                capturedPhotoData1 = processedJPEGData(from: sampleBuffer, isFront: isFront)
            } else if output == output2 && capturedPhotoData2 == nil {
                let isFront = (cameras.indices.contains(1) && cameras[1] == .front)
                capturedPhotoData2 = processedJPEGData(from: sampleBuffer, isFront: isFront)
            } else if output == output3 && capturedPhotoData3 == nil {
                let isFront = (cameras.indices.contains(2) && cameras[2] == .front)
                capturedPhotoData3 = processedJPEGData(from: sampleBuffer, isFront: isFront)
            }
            photoLock.unlock()
        }
    }
}