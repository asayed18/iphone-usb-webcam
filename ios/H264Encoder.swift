import AVFoundation
import CoreMedia
import VideoToolbox

/// Hardware H.264 encoder producing Annex-B access units (NALUs with 00 00 00 01 start codes).
final class H264Encoder {
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "usbcam.encoder", qos: .userInteractive)
    private let onAccessUnit: (Data) -> Void
    private let targetBitrate: Int
    private let frameRate: Int32
    private var sps: Data?
    private var pps: Data?

    // Must stay alive for the lifetime of the session (C function pointer).
    private let outputCallback: VTOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let refcon else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.consume(sampleBuffer: sampleBuffer)
    }

    init(bitrate: Int, fps: Int32, onAccessUnit: @escaping (Data) -> Void) {
        self.targetBitrate = bitrate
        self.frameRate = fps
        self.onAccessUnit = onAccessUnit
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.ensureSession(pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                                   pixelHeight: CVPixelBufferGetHeight(pixelBuffer)) { return }
            guard let session = self.session else { return }
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: nil,
                sourcePixelBufferPoolOut: nil,
                infoFlagsOut: nil
            )
        }
    }

    private func ensureSession(pixelWidth: Int32, pixelHeight: Int32) -> Bool {
        if session != nil { return true }

        var newSession: VTCompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: pixelWidth,
            height: pixelHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTCompressionPropertyKey_EnableHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue as Any,
                kVTCompressionPropertyKey_RealTime as String: kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let s = newSession else { return false }
        session = s

        let props: [String: Any] = [
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate as String: NSNumber(value: targetBitrate),
            kVTCompressionPropertyKey_ExpectedFrameRate as String: NSNumber(value: frameRate),
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: NSNumber(value: frameRate * 2),
            kVTCompressionPropertyKey_AllowFrameReordering as String: kCFBooleanFalse as Any,
        ]
        VTSessionSetProperties(s, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    func finish() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }

    private func consume(sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        if sps == nil || pps == nil {
            var spsPtr: UnsafePointer<UInt8>?
            var ppsPtr: UnsafePointer<UInt8>?
            var spsSize = 0, ppsSize = 0, spsCount = 0, ppsCount = 0
            var nalHeaderLen: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalHeaderLen)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil)
            if let sp = spsPtr, let pp = ppsPtr {
                sps = Data(bytes: sp, count: spsSize)
                pps = Data(bytes: pp, count: ppsSize)
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let notSync = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_NotSync,
            attachmentModeOut: nil
        ) as? Bool ?? false
        let isIDR = !notSync

        let total = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: total)
        guard avcc.withUnsafeMutableBytes({ ptr -> Bool in
            guard let dest = ptr.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: total, destination: dest) == kCMBlockBufferNoErr
        }) else { return }

        var annexB = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        if isIDR, let sps, let pps {
            annexB.append(contentsOf: startCode)
            annexB.append(sps)
            annexB.append(contentsOf: startCode)
            annexB.append(pps)
        }

        avcc.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 4 <= total {
                let naluLen = Int(UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
                guard naluLen > 0, offset &+ naluLen <= total else { break }
                annexB.append(contentsOf: startCode)
                annexB.append(contentsOf: UnsafeRawBufferPointer(rebasing: ptr[offset..<(offset + naluLen)]))
                offset += naluLen
            }
        }

        if !annexB.isEmpty { onAccessUnit(annexB) }
    }
}
