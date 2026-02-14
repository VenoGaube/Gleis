import AVFoundation
import CoreImage
import UIKit
import Vision

// MARK: - CameraStatus

enum CameraStatus { case searching, detected }

// MARK: - CameraModel

class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var completion: ((UIImage?) -> Void)?
    private var device: AVCaptureDevice?

    @Published var status: CameraStatus = .searching
    @Published var torchEnabled = false
    @Published var isProcessing = false
    @Published var frozenPreviewImage: UIImage?

    private let detectQueue = DispatchQueue(label: "detect", qos: .userInteractive)
    private let processQueue = DispatchQueue(label: "process", qos: .userInitiated)
    private var frameCount = 0
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Detection stabilization
    private var detectionCount = 0
    private let detectionThreshold = 3

    // Store last frame for freeze-frame display
    private var lastFrameImage: UIImage?
    private let frameLock = NSLock()

    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 1.3
        request.maximumAspectRatio = 1.75
        request.minimumSize = 0.2
        request.minimumConfidence = 0.8
        request.maximumObservations = 1
        return request
    }()

    func start() {
        guard session.inputs.isEmpty else { return }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device

        // Configure device for optimal card scanning
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()

        if session.canAddInput(input) { session.addInput(input) }

        // Configure photo output for maximum quality
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            if #available(iOS 16.0, *) {
                photoOutput.maxPhotoDimensions =
                    device.activeFormat.supportedMaxPhotoDimensions.first ?? .init(width: 4032, height: 3024)
            } else {
                photoOutput.isHighResolutionCaptureEnabled = true
            }
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.setSampleBufferDelegate(self, queue: detectQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        setTorch(false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.stopRunning() }
    }

    func toggleTorch() { setTorch(!torchEnabled) }

    private func setTorch(_ enabled: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        try? device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.torchEnabled = enabled }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion

        // Freeze the preview with the last captured frame
        frameLock.lock()
        let freezeImage = lastFrameImage
        frameLock.unlock()

        DispatchQueue.main.async {
            self.frozenPreviewImage = freezeImage
            self.isProcessing = true
        }

        // Capture single high-quality photo
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.flashMode = device?.hasFlash == true && !torchEnabled ? .auto : .off
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error _: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.frozenPreviewImage = nil
                self.completion?(nil)
            }
            return
        }

        // Process on background thread
        processQueue.async { [weak self] in
            guard let self else { return }

            // Apply sharpening and detect/correct perspective
            let processed = processImage(image)

            DispatchQueue.main.async {
                self.isProcessing = false
                self.frozenPreviewImage = nil
                self.completion?(processed)
            }
        }
    }

    /// Process captured image: sharpen and correct perspective
    private func processImage(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        // Detect rectangle on the original CGImage with proper orientation hint
        if let corrected = detectAndCorrectPerspective(cgImage, orientation: orientation) {
            // Apply sharpening to the corrected image
            let sharpened = applySharpen(corrected)
            if let outputCGImage = ciContext.createCGImage(sharpened, from: sharpened.extent) {
                return UIImage(cgImage: outputCGImage)
            }
        }

        // Fallback: just apply sharpening without perspective correction
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let sharpened = applySharpen(ciImage)
        if let outputCGImage = ciContext.createCGImage(sharpened, from: sharpened.extent) {
            return UIImage(cgImage: outputCGImage)
        }

        return image
    }

    /// Apply unsharp mask for crisp edges
    private func applySharpen(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.2, forKey: kCIInputRadiusKey)
        filter.setValue(0.6, forKey: kCIInputIntensityKey)
        return filter.outputImage ?? image
    }

    /// Detect rectangle and apply perspective correction
    private func detectAndCorrectPerspective(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CIImage? {
        // Run Vision detection on the original CGImage with orientation hint
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 1.3
        request.maximumAspectRatio = 1.75
        request.minimumSize = 0.15
        request.minimumConfidence = 0.7
        request.maximumObservations = 1

        try? handler.perform([request])
        guard let rect = request.results?.first else { return nil }

        // Create CIImage with orientation applied - this is what we'll crop from
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let w = ciImage.extent.width
        let h = ciImage.extent.height

        // Vision returns normalized coordinates [0,1] in a coordinate system where:
        // - Origin is bottom-left (same as CIImage)
        // - Y increases upward (same as CIImage)
        // So we can directly multiply by image dimensions
        let topLeft = CGPoint(x: rect.topLeft.x * w, y: rect.topLeft.y * h)
        let topRight = CGPoint(x: rect.topRight.x * w, y: rect.topRight.y * h)
        let bottomLeft = CGPoint(x: rect.bottomLeft.x * w, y: rect.bottomLeft.y * h)
        let bottomRight = CGPoint(x: rect.bottomRight.x * w, y: rect.bottomRight.y * h)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let corrected = filter.outputImage else { return nil }

        // Light contrast boost for QR code readability
        return corrected.applyingFilter(
            "CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputSaturationKey: 1.0]
        )
    }

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1

        // Capture frame image for freeze-frame (every 2nd frame to balance performance)
        if frameCount % 2 == 0 {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let frameImage = UIImage(cgImage: cgImage)
                frameLock.lock()
                lastFrameImage = frameImage
                frameLock.unlock()
            }
        }

        // Throttle detection to every 3rd frame
        guard frameCount % 3 == 0 else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([rectangleRequest])
        let detected = rectangleRequest.results?.first != nil

        // Stabilize detection
        if detected {
            detectionCount = min(detectionCount + 1, detectionThreshold + 1)
        } else {
            detectionCount = max(detectionCount - 1, 0)
        }

        let newStatus: CameraStatus = detectionCount >= detectionThreshold ? .detected : .searching
        DispatchQueue.main.async { [weak self] in
            guard let self, status != newStatus else { return }
            status = newStatus
        }
    }
}

// MARK: - CGImagePropertyOrientation Extension

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
