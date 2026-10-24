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
    @Published var selectedCameras: [AvailableCamera] = [.mainWide]
    @Published var lensFor4K: AvailableCamera? = .mainWide
    @Published var targetFps: FpsOption = .fps30
    @Published var activeCameraCount: Int = 1
    @Published var isSingleLensMode: Bool = true
    @Published var statusMessage = "Starting Camera..."

    // Multi-Cam hardware session for 2-3 cameras
    private let multiCamSession = AVCaptureMultiCamSession()
    // Standard unconstrained session for Single Lens Pro Mode
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
        // 60fps is strictly supported only in Single Lens mode due to Apple ISP multi-cam limits
        if selectedCameras.count == 1 {
            targetFps = (targetFps == .fps30) ? .fps60 : .fps30
            applyCameraSelection()
        }
    }

    func applyCameraSelection() {
        sessionQueue.async {
            guard !self.isConfiguring else { return }
            self.isConfiguring = true

            if self.selectedCameras.count > 1 {
                self.targetFps = .fps30
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

    // ==========================================
    // MARK: - Single Lens Pro Mode (Full Hardware Power)
    // ==========================================
    private func setupSingleLensPipeline() {
        guard let choice = selectedCameras.first else { self.isConfiguring = false; return }

        var objcError: NSError?
        let success = ObjCExceptionCatcher.tryExecute({
            self.singleCamSession.beginConfiguration()

            for input in self.singleCamSession.inputs { self.singleCamSession.removeInput(input) }
            for output in self.singleCamSession.outputs { self.singleCamSession.removeOutput(output) }

            self.output1 = nil; self.output2 = nil; self.output3 = nil
            self.photoOutput = nil

            let isFront = (choice == .front)
            let device = self.getDevice(for: choice)
            guard let camDev = device else { self.singleCamSession.commitConfiguration(); return }
            self.activeDevice1 = camDev
            if choice == .mainWide { self.mainWideDevice = camDev }

            // Single lens mode supports true 4K and up to 60fps
            let want4K = (self.lensFor4K == choice && !isFront)
            let reqFps = Int32(self.targetFps.rawValue)
            self.configureSingleCameraFormat(for: camDev, isFront: isFront, want4K: want4K, targetFps: reqFps)

            guard let input = try? AVCaptureDeviceInput(device: camDev), self.singleCamSession.canAddInput(input) else {
                self.singleCamSession.commitConfiguration()
                return
            }
            self.singleCamSession.addInput(input)

            // Attach full-fidelity native photo output
            let pOut = AVCapturePhotoOutput()
            pOut.isHighResolutionCaptureEnabled = true
            if self.singleCamSession.canAddOutput(pOut) {
                self.singleCamSession.addOutput(pOut)
                self.photoOutput = pOut
            }

            // Video data output for realtime preview recording
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
                    if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
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

    // ==========================================
    // MARK: - Multi-Cam Mode (2 to 3 Cameras)
    // ==========================================
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

            self.output1 = nil; self.output2 = nil; self.output3 = nil
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
                previewConn.videoOrientation = .portrait
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
            return isFront ? .leftMirrored :