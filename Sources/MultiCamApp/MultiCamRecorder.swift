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

enum FpsOption: Int, CaseIterable {
    case fps30 = 30
    case fps60 = 60
}

class SingleStreamRecorder {
    let name: String
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var isSessionStarted = false
    private(set) var outputURL: URL?

    init(name: String) { self.name = name }

    func prepare(width: Int, height: Int, transform: CGAffineTransform, fps: Int = 30) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).mp4")
        try? FileManager.default.removeItem(at: url)
        self.outputURL = url
        self.isSessionStarted = false

        let bitrate = (width >= 3840) ? (fps == 60 ? 55_000_000 : 30_000_000) : (fps == 60 ? 18_000_000 : 10_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
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

// Conform directly on the class declaration to prevent scope resolution failures
class MultiCamRecorder: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var isTorchOn = false
    @Published var selectedCameras: [AvailableCamera] = [.mainWide]
    @Published var lensFor4K: AvailableCamera? = .mainWide
    @Published var targetFps: FpsOption = .fps30
    @Published var activeCameraCount: Int = 1
    @Published var isSingleLensMode: Bool = true
    @Published var statusMessage = "Starting Camera..."

    private let multiCamSession = AVCaptureMultiCamSession()
    private let singleCamSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "multicam.session.queue", qos: .userInitiated)
    private let dataOutputQueue = DispatchQueue(label: "multicam.data.queue", qos: .userInteractive)

    let previewView1 = PreviewView()
    let previewView2 = PreviewView()
    let previewView3 = PreviewView()

    private var output1: AVCaptureVideoDataOutput?
    private var output2: AVCaptureVideoDataOutput?
    private var output3: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?

    private var activeDevice1: AVCaptureDevice?
    private var mainWideDevice: AVCaptureDevice?

    private let recorder1 = SingleStreamRecorder(name: "Stream_1")
    private let recorder2 = SingleStreamRecorder(name: "Stream_2")
    private let recorder3 = SingleStreamRecorder(name: "Stream_3")

    private var isCapturingMultiPhotos = false
    private var capturedPhotoData1: Data?
    private var capturedPhotoData2: Data?
    private var capturedPhotoData3: Data?
    private let photoLock = NSLock()

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

    func toggleFps() {
        guard !isRecording else { return }
        if selectedCameras.count == 1 {
            targetFps = (targetFps == FpsOption.fps30) ? FpsOption.fps60 : FpsOption.fps30
            applyCameraSelection()
        }
    }

    func applyCameraSelection() {
        sessionQueue.async {
            guard !self.isConfiguring else { return }
            self.isConfiguring = true

            if self.selectedCameras.count > 1 {
                self.targetFps = FpsOption.fps30
            }

            let isSingle = (self.selectedCameras.count == 1)
            DispatchQueue.main.async {
                self.isSingleLensMode = isSingle
            }

            if self.multiCamSession.isRunning { self.multiCamSession.stopRunning() }
            if self.singleCamSession.isRunning { self.singleCamSession.stopRunning() }

            if isSingle {
                self.setupSingleLensPipeline()
            } else {
                self.setupMultiCamPipeline()
            }
        }
    }

    private func setupSingleLensPipeline() {
        guard let choice = selectedCameras.first else { self.isConfiguring = false; return }

        var objcError: NSError?
        let success = ObjCExceptionCatcher.tryExecute({
            self.singleCamSession.beginConfiguration()

            for input in self.singleCamSession.inputs { self.singleCamSession.removeInput(input) }
            for output in self.singleCamSession.outputs { self.singleCamSession.removeOutput(output) }

            self.output1 = nil
            self.output2 = nil
            self.output3 = nil
            self.photoOutput = nil

            let isFront = (choice == .front)
            let device = self.getDevice(for: choice)
            guard let camDev = device else { self.singleCamSession.commitConfiguration(); return }
            self.activeDevice1 = camDev
            if choice == .mainWide { self.mainWideDevice = camDev }

            let want4K = (self.lensFor4K == choice && !isFront)
            let reqFps = Int32(self.targetFps.rawValue)
            self.configureSingleCameraFormat(for: camDev, isFront: isFront, want4K: want4K, targetFps: reqFps)

            guard let input = try? AVCaptureDeviceInput(device: camDev), self.singleCamSession.canAddInput(input) else {
                self.singleCamSession.commitConfiguration()
                return
            }
            self.singleCamSession.addInput(input)

            let pOut = AVCapturePhotoOutput()
            pOut.isHighResolutionCaptureEnabled = true
            if self.singleCamSession.canAddOutput(pOut) {
                self.singleCamSession.addOutput(pOut)
                self.photoOutput = pOut
            }

            let dataOutput = AVCaptureVideoDataOutput()
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            dataOutput.setSampleBufferDelegate(self, queue: self.dataOutputQueue)

            if self.singleCamSession.canAddOutput(dataOutput) {
                self.singleCamSession.addOutput(dataOutput)
                self.output1 = dataOutput
            }

            DispatchQueue.main.sync {
                self.previewView1.videoPreviewLayer.session = self.singleCamSession
                if let conn = self.previewView1.videoPreviewLayer.connection {
                    if conn.isVideoOrientationSupported {
                        conn.videoOrientation = AVCaptureVideoOrientation.portrait
                    }
                    if conn.isVideoMirroringSupported {
                        conn.automaticallyAdjustsVideoMirroring = false
                        conn.isVideoMirrored = isFront
                    }
                }
            }

            self.singleCamSession.commitConfiguration()
            self.singleCamSession.startRunning()

            DispatchQueue.main.async {
                self.activeCameraCount = 1
                self.isRunning = self.singleCamSession.isRunning
                let res = want4K ? "4K" : "1080p"
                self.statusMessage = "PRO MODE: \(choice.rawValue) (\(res) \(self.targetFps.rawValue)fps)"
                self.isConfiguring = false
            }
        }, error: &objcError)

        if !success, let err = objcError {
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(err.localizedDescription)"
                self.isConfiguring = false
            }
        }
    }

    private func setupMultiCamPipeline() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async {
                self.statusMessage = "MultiCam unsupported on hardware."
                self.isConfiguring = false
            }
            return
        }

        var objcError: NSError?
        let success = ObjCExceptionCatcher.tryExecute({
            self.multiCamSession.beginConfiguration()

            for input in self.multiCamSession.inputs { self.multiCamSession.removeInput(input) }
            for output in self.multiCamSession.outputs { self.multiCamSession.removeOutput(output) }

            self.output1 = nil
            self.output2 = nil
            self.output3 = nil
            self.photoOutput = nil

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
                if let out = self.addMultiCameraSafe(choice: camChoice, previewLayer: layer, want4K: isTarget4K) {
                    if index == 0 { self.output1 = out }
                    else if index == 1 { self.output2 = out }
                    else if index == 2 { self.output3 = out }
                    count += 1
                }
            }

            self.multiCamSession.commitConfiguration()
            self.multiCamSession.startRunning()

            let costPercent = Int(self.multiCamSession.hardwareCost * 100)
            DispatchQueue.main.async {
                self.activeCameraCount = count
                self.isRunning = self.multiCamSession.isRunning
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

    private func getDevice(for choice: AvailableCamera) -> AVCaptureDevice? {
        switch choice {
        case .telephoto:
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case .mainWide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    private func configureSingleCameraFormat(for device: AVCaptureDevice, isFront: Bool, want4K: Bool, targetFps: Int32) {
        let targetW: Int32 = want4K ? 3840 : 1920
        let targetH: Int32 = want4K ? 2160 : 1080

        let match = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let maxFps = $0.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0
            return dims.width == targetW && dims.height == targetH && maxFps >= Double(targetFps)
        }
        let fallback = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == 1920 && dims.height == 1080
        }

        guard let chosen = match.first ?? fallback.first ?? device.formats.first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.unlockForConfiguration()
        } catch {}
    }

    private func configureMultiCameraFormat(for device: AVCaptureDevice, isFront: Bool, want4K: Bool) -> Bool {
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
            guard let chosen = front720pBinned.first ?? front720pAny.first ?? multiCamFormats.first else { return false }
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

    private func addMultiCameraSafe(choice: AvailableCamera, previewLayer: AVCaptureVideoPreviewLayer, want4K: Bool) -> AVCaptureVideoDataOutput? {
        guard let camDev = getDevice(for: choice) else { return nil }
        if choice == .mainWide { self.mainWideDevice = camDev }

        let isFront = (choice == .front)
        guard configureMultiCameraFormat(for: camDev, isFront: isFront, want4K: want4K),
              let input = try? AVCaptureDeviceInput(device: camDev), multiCamSession.canAddInput(input) else {
            return nil
        }

        multiCamSession.addInputWithNoConnections(input)

        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            multiCamSession.removeInput(input)
            return nil
        }

        DispatchQueue.main.sync {
            previewLayer.setSessionWithNoConnection(self.multiCamSession)
        }

        let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if multiCamSession.canAddConnection(previewConn) {
            multiCamSession.addConnection(previewConn)
            if previewConn.isVideoOrientationSupported {
                previewConn.videoOrientation = AVCaptureVideoOrientation.portrait
            }
            if previewConn.isVideoMirroringSupported {
                previewConn.automaticallyAdjustsVideoMirroring = false
                previewConn.isVideoMirrored = isFront
            }
        }

        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        dataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)

        if multiCamSession.canAddOutput(dataOutput) {
            multiCamSession.addOutputWithNoConnections(dataOutput)
            let dataConn = AVCaptureConnection(inputPorts: [port], output: dataOutput)
            if multiCamSession.canAddConnection(dataConn) {
                multiCamSession.addConnection(dataConn)
                if dataConn.isVideoMirroringSupported {
                    dataConn.automaticallyAdjustsVideoMirroring = false
                    dataConn.isVideoMirrored = isFront
                }
                return dataOutput
            }
        }
        return nil
    }

    func toggleTorch() {
        sessionQueue.async {
            let devices = [self.activeDevice1, self.mainWideDevice, AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)].compactMap { $0 }
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
        if isSingleLensMode, let pOut = photoOutput {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.isHighResolutionPhotoEnabled = true
            pOut.capturePhoto(with: settings, delegate: self)
            DispatchQueue.main.async {
                self.statusMessage = "Capturing native full-res photo..."
            }
        } else {
            captureMultiCamPhotos()
        }
    }

    private func captureMultiCamPhotos() {
        dataOutputQueue.async {
            guard !self.isCapturingMultiPhotos else { return }
            self.photoLock.lock()
            self.capturedPhotoData1 = nil
            self.capturedPhotoData2 = nil
            self.capturedPhotoData3 = nil
            self.isCapturingMultiPhotos = true
            self.photoLock.unlock()

            DispatchQueue.main.async {
                self.statusMessage = "Processing high-res stills..."
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) {
                self.photoLock.lock()
                self.isCapturingMultiPhotos = false
                let d1 = self.capturedPhotoData1
                let d2 = self.capturedPhotoData2
                let d3 = self.capturedPhotoData3
                self.photoLock.unlock()

                let photoDataList = [d1, d2, d3].compactMap { $0 }
                guard !photoDataList.isEmpty else {
                    DispatchQueue.main.async { self.statusMessage = "No frames captured." }
                    return
                }

                PHPhotoLibrary.requestAuthorization(for: .addOnly) { (status: PHAuthorizationStatus) in
                    guard status == .authorized || status == .limited else {
                        DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        for data in photoDataList {
                            let creationRequest = PHAssetCreationRequest.forAsset()
                            creationRequest.addResource(with: .photo, data: data, options: nil)
                        }
                    }, completionHandler: { (success: Bool, error: Error?) in
                        DispatchQueue.main.async {
                            if success {
                                self.statusMessage = "Saved \(photoDataList.count) photos directly to Photos!"
                            } else {
                                self.statusMessage = "Photo save error: \(error?.localizedDescription ?? "")"
                            }
                        }
                    })
                }
            }
        }
    }

    private func processedJPEGData(from sampleBuffer: CMSampleBuffer, isFront: Bool) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)

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
            let fpsVal = self.targetFps.rawValue
            var startedAny = false

            for (index, cam) in cameras.enumerated() {
                var w = 1920
                var h = 1080
                let isFront = (cam == .front)

                if isFront && !self.isSingleLensMode {
                    w = 1280; h = 720
                } else if self.lensFor4K == cam {
                    w = 3840; h = 2160
                }

                let transform = self.videoTransform(isFront: isFront)

                if index == 0 && self.output1 != nil {
                    if self.recorder1.prepare(width: w, height: h, transform: transform, fps: fpsVal) { startedAny = true }
                } else if index == 1 && self.output2 != nil {
                    if self.recorder2.prepare(width: w, height: h, transform: transform, fps: 30) { startedAny = true }
                } else if index == 2 && self.output3 != nil {
                    if self.recorder3.prepare(width: w, height: h, transform: transform, fps: 30) { startedAny = true }
                }
            }

            if startedAny {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording (\(self.targetFps.rawValue)fps)..."
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

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { (status: PHAuthorizationStatus) in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.statusMessage = "Photos permission denied." }
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }, completionHandler: { (success: Bool, error: Error?) in
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }

                DispatchQueue.main.async {
                    if success {
                        self.statusMessage = "Saved \(urls.count) video(s) to Photos!"
                    } else {
                        self.statusMessage = "Save Error: \(error?.localizedDescription ?? "")"
                    }
                }
            })
        }
    }

    // AVCapturePhotoCaptureDelegate implementation
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let photoData = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.statusMessage = "Photo Capture Error" }
            return
        }

        let isFront = (selectedCameras.first == .front)
        guard let sourceImage = UIImage(data: photoData) else { return }
        let correctedImage = UIImage(cgImage: sourceImage.cgImage!, scale: 1.0, orientation: imageOrientation(isFront: isFront))
        guard let finalData = correctedImage.jpegData(compressionQuality: 1.0) else { return }

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: finalData, options: nil)
        }, completionHandler: { (success: Bool, error: Error?) in
            DispatchQueue.main.async {
                self.statusMessage = success ? "Full-Res Native Photo Saved!" : "Photo Save Failed"
            }
        })
    }

    // AVCaptureVideoDataOutputSampleBufferDelegate implementation
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isRecording {
            if output == output1 { recorder1.append(sampleBuffer) }
            else if output == output2 { recorder2.append(sampleBuffer) }
            else if output == output3 { recorder3.append(sampleBuffer) }
        }

        if isCapturingMultiPhotos && !isSingleLensMode {
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