import CoreMedia
import VideoToolbox
import XCTest

@testable import OpenLens

final class AndroidStreamTests: XCTestCase {
    func testNALUnitsAreSplitOnBothStartCodesWithoutTheirPadding() {
        let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 4, 5])
        XCTAssertEqual(
            AndroidStream.nalUnits(in: stream),
            [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])]
        )
    }

    /// The phone's messages, made here by the Mac's own H.264 encoder: the
    /// parameter sets alone, then one frame per message, all in Annex B.
    func testFramesInThePhonesFormatDecodeToThePictureThatWasSent() throws {
        let frameCount = 5
        let decoded = expectation(description: "decoded frames")
        decoded.expectedFulfillmentCount = frameCount
        let lock = NSLock()
        var frames: [CVPixelBuffer] = []
        let stream = AndroidStream(queue: DispatchQueue(label: "test")) { frame in
            lock.withLock { frames.append(frame) }
            decoded.fulfill()
        }

        for message in try Self.phoneMessages(frameCount: frameCount, width: 1280, height: 720, luma: 200) {
            stream.handle(message)
        }
        wait(for: [decoded], timeout: 5)

        let frame = try XCTUnwrap(lock.withLock { frames.last })
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 720)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(frame), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0))
        let centre = luma.load(
            fromByteOffset: 360 * CVPixelBufferGetBytesPerRowOfPlane(frame, 0) + 640, as: UInt8.self)
        XCTAssertEqual(Int(centre), 200, accuracy: 6)
    }

    private static func phoneMessages(frameCount: Int, width: Int, height: Int, luma: UInt8) throws -> [Data]
    {
        var created: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        let encoder = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        var picture: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &picture
        )
        let source = try XCTUnwrap(picture)
        CVPixelBufferLockBaseAddress(source, [])
        for (plane, value) in [(0, luma), (1, UInt8(128))] {
            memset(
                CVPixelBufferGetBaseAddressOfPlane(source, plane), Int32(value),
                CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    * CVPixelBufferGetHeightOfPlane(source, plane)
            )
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        var samples: [CMSampleBuffer] = []
        for index in 0..<frameCount {
            VTCompressionSessionEncodeFrame(
                encoder,
                imageBuffer: source,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { _, _, sample in
                if let sample { samples.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        XCTAssertEqual(samples.count, frameCount)

        let startCode = Data([0, 0, 0, 1])
        var messages: [Data] = []
        let format = try XCTUnwrap(samples.first.flatMap(CMSampleBufferGetFormatDescription))
        var parameterSets = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            parameterSets += startCode + Data(bytes: try XCTUnwrap(pointer), count: size)
        }
        messages.append(parameterSets)

        for sample in samples {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            bytes.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            var message = Data()
            var offset = 0
            while offset + 4 <= bytes.count {
                let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                message += startCode + bytes[offset + 4..<offset + 4 + length]
                offset += 4 + length
            }
            messages.append(message)
        }
        return messages
    }
}
