import CoreGraphics
import CoreImage
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

/// How the person is cut out, tuned by the user in the Background section.
///
/// Global rather than per scene: what looks right depends on the room, the
/// light and the camera, not on the framing.
struct MatteSettings: Codable, Equatable {
    enum Quality: String, Codable, CaseIterable {
        case fast, balanced, accurate
    }

    /// Vision's model. The mask is 256×192, 512×384 or 2016×1512 whatever the
    /// camera delivers; a slower model updates the mask less often.
    var quality: Quality = .fast
    /// 0 smooths the mask on its own; towards 1 the edge snaps to the edges in
    /// the camera image.
    var edgeDetail: Double = 0.5
    /// How wide the transition from person to background is.
    var softness: Double = 0.3
    /// How much of the previous mask each new one keeps, less where it moved.
    var stability: Double = 0.2
    /// Pulls the edge in, to remove a fringe of the old room.
    var shrink: Double = 0

    static let standard = MatteSettings()

    static let stabilityRange: ClosedRange<Double> = 0...0.9
    static let shrinkRange: ClosedRange<Double> = 0...0.5

    /// `1 / 2σ²` of the spatial weight, σ running from 0.5 to 2 mask texels.
    var spatialFactor: Float {
        let sigma = 0.5 + 1.5 * softness
        return Float(1 / (2 * sigma * sigma))
    }

    /// `1 / 2σ²` of the brightness weight, σ = 0.03 / edgeDetail, so 0 turns
    /// it off.
    var rangeFactor: Float {
        Float(edgeDetail * edgeDetail / (2 * 0.03 * 0.03))
    }
}

/// Where the person is in `region` of the camera frame, 255 for the person.
struct PersonMask {
    var buffer: CVPixelBuffer
    /// Normalized source space, top-left origin.
    var region: CGRect
}

/// Finds the person in a camera frame, on the Mac, with Vision.
///
/// Used from one queue at a time.
final class PersonSegmenter {
    private let request = VNGeneratePersonSegmentationRequest()
    private let handler = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var previous: PersonMask?

    init() {
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Segments only `region`, the part of the frame on screen: the mask has
    /// a fixed size, so at zoom 2 this gives the picture twice the detail for
    /// the same cost.
    ///
    /// The result is a copy. Vision reuses its own buffer for the next
    /// request, which may start while the GPU still reads this one.
    func mask(for frame: CVPixelBuffer, region: CGRect, settings: MatteSettings) -> PersonMask? {
        switch settings.quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        let crop = Self.coreImageRect(
            for: region,
            width: CGFloat(CVPixelBufferGetWidth(frame)),
            height: CGFloat(CVPixelBufferGetHeight(frame))
        )
        let image = CIImage(cvPixelBuffer: frame).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        guard (try? handler.perform([request], on: image)) != nil,
            let raw = request.results?.first?.pixelBuffer,
            let copy = makeBuffer(like: raw)
        else { return nil }

        // A mask of another region, size or quality would smear the edge.
        let earlier = previous.flatMap { previous in
            previous.region == region
                && CVPixelBufferGetWidth(previous.buffer) == CVPixelBufferGetWidth(raw)
                && CVPixelBufferGetHeight(previous.buffer) == CVPixelBufferGetHeight(raw)
                ? previous.buffer : nil
        }
        Self.blend(raw, earlier, into: copy, stability: settings.stability)
        let mask = PersonMask(buffer: copy, region: region)
        previous = mask
        return mask
    }

    /// `region` in pixels, counted from the bottom as Core Image does.
    static func coreImageRect(for region: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: region.minX * width,
            y: (1 - region.maxY) * height,
            width: region.width * width,
            height: region.height * height
        )
    }

    /// `into = new + k (earlier - new)`, with `k = stability` where the mask is
    /// still and falling to 0 where it changed completely, so a moving hand
    /// does not leave a trail.
    static func blend(
        _ new: CVPixelBuffer,
        _ earlier: CVPixelBuffer?,
        into output: CVPixelBuffer,
        stability: Double
    ) {
        let inputs = [new] + (earlier.map { [$0] } ?? [])
        for buffer in inputs { CVPixelBufferLockBaseAddress(buffer, .readOnly) }
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            for buffer in inputs { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let newBase = CVPixelBufferGetBaseAddress(new),
            let outputBase = CVPixelBufferGetBaseAddress(output)
        else { return }
        let earlierBase = earlier.flatMap { CVPixelBufferGetBaseAddress($0) }
        let width = CVPixelBufferGetWidth(new)
        for y in 0..<CVPixelBufferGetHeight(new) {
            let newRow = newBase.advanced(by: y * CVPixelBufferGetBytesPerRow(new))
                .assumingMemoryBound(to: UInt8.self)
            let outputRow = outputBase.advanced(by: y * CVPixelBufferGetBytesPerRow(output))
                .assumingMemoryBound(to: UInt8.self)
            guard let earlier, let earlierBase else {
                outputRow.update(from: newRow, count: width)
                continue
            }
            let earlierRow = earlierBase.advanced(by: y * CVPixelBufferGetBytesPerRow(earlier))
                .assumingMemoryBound(to: UInt8.self)
            blendRow(newRow, earlierRow, into: outputRow, count: width, stability: stability)
        }
    }

    static func blendRow(
        _ new: UnsafePointer<UInt8>,
        _ earlier: UnsafePointer<UInt8>,
        into output: UnsafeMutablePointer<UInt8>,
        count: Int,
        stability: Double
    ) {
        for index in 0..<count {
            let current = Double(new[index])
            let past = Double(earlier[index])
            let keep = stability * (1 - abs(current - past) / 255)
            output[index] = UInt8((current + keep * (past - current)).rounded())
        }
    }

    private func makeBuffer(like raw: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(raw)
        let height = CVPixelBufferGetHeight(raw)
        if pool == nil || poolSize != (width, height) {
            poolSize = (width, height)
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
