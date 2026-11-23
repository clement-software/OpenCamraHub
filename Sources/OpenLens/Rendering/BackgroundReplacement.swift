import CoreGraphics
import CoreVideo
import Metal
import Vision

/// An image shown behind the person, in place of the room.
struct BackgroundImage {
    var texture: MTLTexture
    /// The part of the image that fills the output, in normalized texture
    /// space: the image is scaled to cover the frame and centred, never
    /// stretched.
    var visibleRect: CGRect

    init(texture: MTLTexture, pixelSize: CGSize, outputAspect: CGFloat) {
        self.texture = texture
        visibleRect = Self.visibleRect(pixelSize: pixelSize, outputAspect: outputAspect)
    }

    static func visibleRect(pixelSize: CGSize, outputAspect: CGFloat) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, outputAspect > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let imageAspect = pixelSize.width / pixelSize.height
        if imageAspect > outputAspect {
            let width = outputAspect / imageAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = imageAspect / outputAspect
        return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }
}

/// Finds the person in a camera frame, on the Mac, with Vision.
///
/// Used only from the capture queue, one frame at a time.
final class PersonSegmenter {
    private let request: VNGeneratePersonSegmentationRequest
    private let handler = VNSequenceRequestHandler()

    init() {
        request = VNGeneratePersonSegmentationRequest()
        // ponytail: synchronous on the capture queue. Measured on a 1080p frame:
        // .fast 20 ms, .balanced 69 ms, .accurate 124 ms, and a 30 fps frame has
        // 33 ms. If a slower Mac drops frames, run this on its own queue and
        // composite with the latest mask instead.
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// A one-channel mask the size Vision chooses, 255 where the person is.
    /// It covers the whole frame, so it is sampled with the frame's own
    /// coordinates. Vision returns it IOSurface-backed, so it becomes a Metal
    /// texture without a copy.
    func mask(for frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard (try? handler.perform([request], on: frame)) != nil else { return nil }
        return request.results?.first?.pixelBuffer
    }
}
