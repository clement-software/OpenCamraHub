import CoreMedia
import Foundation
import Network
import VideoToolbox
import os.log

/// Receives the picture of an Android phone running the OpenCamraHub Webcam
/// app (`Tools/openlens-android`), connected over USB with
/// `adb forward tcp:8765 tcp:8765`, and decodes it into pixel buffers like a
/// camera's.
///
/// The phone sends its hardware encoder's output as it comes: each message
/// is a 4-byte big-endian length followed by one H.264 buffer in Annex B,
/// the parameter sets first and then one frame per message.
///
/// Used from `queue` only.
final class AndroidStream {
    static let deviceID = "android-usb"
    static let deviceName = "Android phone (USB)"
    static let port: NWEndpoint.Port = 8765
    /// Far above a 1080p frame at the phone's bitrate, far below anything
    /// that would hurt to allocate.
    static let maxMessageLength = 8 << 20

    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer) -> Void
    private let log = Logger(subsystem: OpenLensID.appBundleID, category: "android")
    private var isRunning = false
    private var connection: NWConnection?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?

    init(queue: DispatchQueue, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.queue = queue
        self.onFrame = onFrame
    }

    func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.connection?.cancel()
            self.connection = nil
            self.resetDecoder()
        }
    }

    // MARK: - Connection

    // ponytail: polls the forwarded port twice a second while the phone is
    // missing; an `adb` that this sandboxed app could run would make it push.
    private func connect() {
        guard isRunning, connection == nil else { return }
        let connection = NWConnection(host: "127.0.0.1", port: Self.port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("Receiving the Android phone")
            case .waiting, .failed:
                self?.reconnect(after: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    /// The phone app is not open, the phone is unplugged or `adb forward`
    /// was not run: try again shortly, with a fresh decoder for the new
    /// stream's parameter sets.
    private func reconnect(after connection: NWConnection) {
        guard connection === self.connection else { return }
        connection.cancel()
        self.connection = nil
        resetDecoder()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connect() }
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, connection === self.connection else { return }
            guard error == nil, let header, header.count == 4 else {
                self.reconnect(after: connection)
                return
            }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard (1...Self.maxMessageLength).contains(length) else {
                self.log.error("The phone sent a message of \(length) bytes; reconnecting")
                self.reconnect(after: connection)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) {
                payload, _, _, error in
                guard connection === self.connection else { return }
                guard error == nil, let payload, payload.count == length else {
                    self.reconnect(after: connection)
                    return
                }
                self.handle(payload)
                self.receiveMessage(on: connection)
            }
        }
    }

    // MARK: - Decoding

    /// Decodes one message: parameter sets replace the decoder, and anything
    /// else is a frame.
    func handle(_ message: Data) {
        var frame: [Data] = []
        for unit in Self.nalUnits(in: message) {
            switch unit[unit.startIndex] & 0x1F {
            case 7 where unit != sps:
                sps = unit
                resetDecoder(keepingParameterSets: true)
            case 8 where unit != pps:
                pps = unit
                resetDecoder(keepingParameterSets: true)
            case 7, 8:
                break
            default:
                frame.append(unit)
            }
        }
        guard !frame.isEmpty, let decoder = decoder ?? makeDecoder(), let format else { return }

        var sample = Data()
        for unit in frame {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { sample.append(contentsOf: $0) }
            sample.append(unit)
        }
        guard let buffer = Self.sampleBuffer(sample, format: format) else { return }
        let status = VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: buffer, flags: [], infoFlagsOut: nil
        ) { [onFrame] status, _, image, _, _ in
            if status == noErr, let image { onFrame(image) }
        }
        if status != noErr {
            log.error("The phone's frame did not decode: \(status)")
        }
    }

    private func makeDecoder() -> VTDecompressionSession? {
        guard let sps, let pps else { return nil }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { sps in
            pps.withUnsafeBytes { pps in
                let sets = [sps, pps].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: sets,
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else {
            log.error("The phone's parameter sets are not usable: \(status)")
            return nil
        }
        // Biplanar 4:2:0 in IOSurfaces, which the renderer reads as Metal
        // textures without a copy.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var decoder: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &decoder
        )
        self.format = format
        self.decoder = decoder
        return decoder
    }

    private func resetDecoder(keepingParameterSets: Bool = false) {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        format = nil
        if !keepingParameterSets {
            sps = nil
            pps = nil
        }
    }

    private static func sampleBuffer(_ bytes: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: bytes.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: bytes.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block
            ) == noErr,
            let block,
            bytes.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                    dataLength: bytes.count
                )
            }) == noErr
        else { return nil }

        var sample: CMSampleBuffer?
        var size = bytes.count
        CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        return sample
    }

    /// The NAL units of an Annex B buffer, without their start codes or the
    /// zero bytes that may pad them.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0

        func close(at end: Int) {
            guard let first = start else { return }
            var last = end
            while last > first, bytes[last - 1] == 0 { last -= 1 }
            if last > first { units.append(Data(bytes[first..<last])) }
        }

        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                close(at: index)
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        close(at: bytes.count)
        return units
    }
}
