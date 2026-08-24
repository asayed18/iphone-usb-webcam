import AVFoundation
import UIKit

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isStreaming = false
    @Published var manualMode = false
    @Published var torchOn = false
    @Published var lensIndex = 1          // 0 ultra-wide, 1 wide, 2 tele
    @Published var zoomFactor: CGFloat = 1.0
    @Published var iso: Float = 400
    @Published var shutterMs: Double = 8
    @Published var wbTemp: Float = 5000
    @Published var wbTint: Float = 0
    @Published var focusPos: Float = 0.5
    @Published var use4K = false
    @Published var fps: Int32 = 30
    @Published var bitrateMbps: Double = 20
    @Published var clientCount = 0

    private lazy var orderedDevices: [AVCaptureDevice] = {
        let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        return [ultra, wide, tele].compactMap { $0 }
    }()

    private var currentInput: AVCaptureDeviceInput?
    private(set) var encoder: H264Encoder?
    private(set) var server: StreamServer?

    private let videoQueue = DispatchQueue(label: "usbcam.video", qos: .userInteractive)

    func setup() {
        guard orderedDevices.indices.contains(lensIndex) else { return }
        configure(with: orderedDevices[lensIndex])
    }

    private func configure(with device: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = use4K ? .inputPriority : .hd1920x1080

        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            currentInput = input
        } catch {
            session.commitConfiguration()
            return
        }

        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        session.commitConfiguration()
        applyFormat(device: device)
        applyManualControls()
        if session.isRunning == false { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    }

    func applyFormatChange() {
        guard let device = currentInput?.device else { return }
        session.beginConfiguration()
        session.sessionPreset = use4K ? .inputPriority : .hd1920x1080
        session.commitConfiguration()
        applyFormat(device: device)
    }

    private func applyFormat(device: AVCaptureDevice) {
        let targetW: Int32 = use4K ? 3840 : 1920
        guard let format = device.formats.first(where: { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let maxFps = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return dims.width >= targetW && maxFps >= Double(fps)
                && fmt.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) }
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            device.unlockForConfiguration()
        } catch {}
    }

    func switchLens(to index: Int) {
        lensIndex = index
        guard orderedDevices.indices.contains(index) else { return }
        configure(with: orderedDevices[index])
    }

    func setZoom(_ factor: CGFloat) {
        zoomFactor = factor
        guard let device = currentInput?.device else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {}
    }

    func toggleTorch(_ on: Bool) {
        torchOn = on
        guard let device = currentInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {}
    }

    func setManual(_ manual: Bool) {
        manualMode = manual
        applyManualControls()
    }

    func applyManualControls() {
        guard let device = currentInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if manualMode {
                let isoRange = device.activeFormat.minISO...device.activeFormat.maxISO
                let clampedShutterS = min(max(shutterMs / 1000.0,
                                              device.activeFormat.minExposureDuration.seconds),
                                          device.activeFormat.maxExposureDuration.seconds)
                let dur = CMTime(seconds: clampedShutterS, preferredTimescale: 1_000_000)
                device.setExposureModeCustom(duration: dur, iso: min(max(iso, isoRange.lowerBound), isoRange.upperBound))
                if device.isWhiteBalanceSupported {
                    let wb = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: wbTemp, tint: wbTint)
                    device.setWhiteBalanceModeCustom(with: wb)
                }
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                    device.setFocusModeLocked(lensPosition: focusPos)
                }
            } else {
                device.exposureMode = .continuousAutoExposure
                device.focusMode = .continuousAutoFocus
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func startStream() {
        guard encoder == nil else { return }
        let enc = H264Encoder(bitrate: Int(bitrateMbps * 1_000_000), fps: fps) { [weak self] data in
            self?.server?.broadcast(data)
        }
        encoder = enc
        let srv = StreamServer(port: 9750)
        srv.onClientChange = { [weak self] count in
            DispatchQueue.main.async { self?.clientCount = count }
        }
        server = srv
        srv.start()
        isStreaming = true
    }

    func stopStream() {
        encoder?.finish()
        encoder = nil
        server?.stop()
        server = nil
        isStreaming = false
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let encoder = encoder else { return }
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
