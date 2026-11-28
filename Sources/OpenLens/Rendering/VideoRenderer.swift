import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

/// Layout must match `RenderUniforms` in Shaders.metal.
struct RenderUniforms {
    var cropRect: SIMD4<Float>
    var overlayRect: SIMD4<Float>
    var backgroundRect: SIMD4<Float>
    var maskRect: SIMD4<Float>
    var cameraRect: SIMD4<Float>
    var overlayOpacity: Float
    var mirror: Float
    var lumaOffset: Float
    var lumaScale: Float
    var chromaOffset: Float
    var chromaScale: Float
    var exposureGain: Float
    var blackLevel: Float
    var levelsGain: Float
    var midtoneExponent: Float
    var contrastAmount: Float
    var saturationGain: Float
    var temperatureShift: Float
    var tintShift: Float
    var shadowShift: Float
    var highlightShift: Float
    var maskSpatialFactor: Float
    var maskRangeFactor: Float
    var maskShrink: Float
    var blurBackground: Float
}

/// The whole image pipeline: one Metal pass that crops, scales and composites.
///
/// Nothing here ever maps a pixel buffer to the CPU. Camera buffers arrive
/// IOSurface-backed, are wrapped as Metal textures through a texture cache, and
/// the result is written straight into another IOSurface that gets handed to the
/// system extension.
final class VideoRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let biplanarPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState

    /// One pipeline per source layout; the NV12 output needs both planes.
    private struct Planar {
        let biplanar: MTLRenderPipelineState
        let bgra: MTLRenderPipelineState

        func pipeline(isBiplanarSource: Bool) -> MTLRenderPipelineState {
            isBiplanarSource ? biplanar : bgra
        }
    }

    private let lumaPipelines: Planar
    private let chromaPipelines: Planar
    private let textureCache: CVMetalTextureCache
    private let blankOverlay: MTLTexture

    private var blurPlanes: [BlurPlane] = []
    /// Lanczos rather than bilinear: shrinking a 4K frame tenfold with four
    /// taps per pixel would alias, and the blur would shimmer as you move.
    private lazy var downscale: MPSImageLanczosScale = {
        let kernel = MPSImageLanczosScale(device: device)
        kernel.edgeMode = .clamp
        return kernel
    }()
    private var outputPool: CVPixelBufferPool?
    private var outputPoolSize = CGSize.zero

    /// Keeps the CVMetalTexture wrappers alive until the GPU is done with them.
    private var inFlightTextures: [CVMetalTexture] = []

    enum RendererError: Error {
        case noDevice
        case libraryUnavailable
        case pipelineCreationFailed
        case textureCacheCreationFailed
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.commandQueue = queue

        // Resolving the library from the bundle that owns this class rather than
        // the main bundle lets the render pass run inside a unit-test bundle too.
        let library: MTLLibrary
        if let bundled = try? device.makeDefaultLibrary(bundle: Bundle(for: VideoRenderer.self)) {
            library = bundled
        } else if let main = device.makeDefaultLibrary() {
            library = main
        } else {
            throw RendererError.libraryUnavailable
        }

        func makePipeline(fragment: String, format: MTLPixelFormat = .bgra8Unorm) throws
            -> MTLRenderPipelineState
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "openlens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
                throw RendererError.pipelineCreationFailed
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        biplanarPipeline = try makePipeline(fragment: "openlens_fragment_biplanar")
        bgraPipeline = try makePipeline(fragment: "openlens_fragment_bgra")
        lumaPipelines = Planar(
            biplanar: try makePipeline(
                fragment: "openlens_fragment_luma_biplanar",
                format: .r8Unorm
            ),
            bgra: try makePipeline(fragment: "openlens_fragment_luma_bgra", format: .r8Unorm)
        )
        chromaPipelines = Planar(
            biplanar: try makePipeline(
                fragment: "openlens_fragment_chroma_biplanar",
                format: .rg8Unorm
            ),
            bgra: try makePipeline(fragment: "openlens_fragment_chroma_bgra", format: .rg8Unorm)
        )

        var cache: CVMetalTextureCache?
        guard
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess,
            let cache
        else { throw RendererError.textureCacheCreationFailed }
        textureCache = cache

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let blank = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.pipelineCreationFailed
        }
        var clear: UInt32 = 0
        blank.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &clear,
            bytesPerRow: 4
        )
        blankOverlay = blank
    }

    // MARK: - Public API

    struct Frame {
        var pixelBuffer: CVPixelBuffer
        var crop: CGRect
        var mirror: Bool
        var overlay: OverlayTexture?
        var adjustments: ImageAdjustments = .neutral
        /// Replaces the room around the person when set.
        var background: BackgroundImage?
        /// Where the camera picture sits in the output, normalized with a
        /// top-left origin. Smaller than the frame only in front of a
        /// background, which fills the rest.
        var cameraRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// Where the person is, from `PersonSegmenter`. Without one, a set
        /// background covers the whole frame: if the person cannot be found,
        /// showing the room that was meant to be hidden is the worse failure.
        var personMask: PersonMask?
        var matte: MatteSettings = .standard
        /// Blurs the room around the person, or the whole frame without a
        /// mask. It is the camera's own picture, so it is zoomed, mirrored
        /// and colour-corrected with the person.
        var blurBackground = false
    }

    /// The visible part of the camera is shrunk to this width before it is
    /// blurred: a strong blur then costs next to nothing, and loses nothing.
    static let blurWidth = 384

    /// Renders into a pooled NV12 buffer destined for the virtual camera.
    func renderToOutputBuffer(_ frame: Frame) -> CVPixelBuffer? {
        let size = CGSize(width: OpenLensOutput.width, height: OpenLensOutput.height)
        guard let pool = pool(for: size) else { return nil }

        var output: CVPixelBuffer?
        // Fail the allocation rather than growing the pool without bound. If the
        // extension ever stops draining, dropping this frame is the right answer;
        // queueing more of them only adds latency and memory.
        let auxAttributes: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 6]
        guard
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxAttributes as CFDictionary,
                &output
            ) == kCVReturnSuccess,
            let output,
            let luma = makeTexture(from: output, plane: 0, format: .r8Unorm),
            let chroma = makeTexture(from: output, plane: 1, format: .rg8Unorm)
        else { return nil }

        let isBiplanar = Self.isBiplanar(frame.pixelBuffer)
        // Both planes go into one command buffer: the source textures, uniforms
        // and GPU submission are shared, so the second plane costs little beyond
        // its own (quarter-size) fragment work.
        let passes = [
            Pass(pipeline: lumaPipelines.pipeline(isBiplanarSource: isBiplanar), texture: luma),
            Pass(pipeline: chromaPipelines.pipeline(isBiplanarSource: isBiplanar), texture: chroma),
        ]
        guard encode(frame, passes: passes, present: nil) else { return nil }

        // Only the matrix is signalled. A consumer needs it to decode the two
        // planes, and getting it wrong is visible. Primaries and transfer
        // function are display characteristics that every conferencing app
        // assumes to be 709/sRGB anyway — and tagging them made CoreMedia
        // synthesise an ICC profile, which it then rebuilt into a gamma LUT on
        // every single frame.
        CVBufferSetAttachment(
            output, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        return output
    }

    /// A fully black frame in the virtual camera's output format.
    ///
    /// Used as a known-good source buffer in tests; the pause path sends
    /// `IdleFrameRenderer`'s card instead of this, on purpose — a frozen still
    /// of the room would read as live video to whoever is watching, which is
    /// the one thing someone who steps away does not want, but a card that
    /// says the app isn't running is unambiguous either way.
    ///
    /// Static and self-allocating on purpose: it is called from the main thread
    /// while the capture queue is inside `renderToOutputBuffer`, so it must not
    /// touch the renderer's pool or texture cache.
    static func makeBlackOutputBuffer() -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                OpenLensOutput.width,
                OpenLensOutput.height,
                OpenLensOutput.pixelFormat,
                attributes as CFDictionary,
                &output
            ) == kCVReturnSuccess, let output
        else { return nil }

        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        // Video-range NV12 black is luma 16 and neutral chroma 128. Zeroing both
        // planes instead — the obvious shortcut — produces a green frame.
        let fills: [(plane: Int, value: Int32)] = [(0, 16), (1, 128)]
        for fill in fills {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(output, fill.plane)
            else { return nil }
            let bytes =
                CVPixelBufferGetBytesPerRowOfPlane(output, fill.plane)
                * CVPixelBufferGetHeightOfPlane(output, fill.plane)
            memset(base, fill.value, bytes)
        }

        CVBufferSetAttachment(
            output, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        return output
    }

    /// Blocks until everything submitted so far has finished on the GPU.
    ///
    /// Command buffers on a single queue complete in order, so an empty one
    /// submitted last is a barrier. This exists for tests, which have to read an
    /// output surface back and would otherwise race the GPU; the live path never
    /// waits, which is the whole point of handing the buffer straight on.
    func waitUntilIdle() {
        let barrier = commandQueue.makeCommandBuffer()
        barrier?.commit()
        barrier?.waitUntilCompleted()
    }

    /// Renders straight into a `CAMetalLayer` drawable for the preview.
    ///
    /// `completion` fires once the frame has been presented, which is what lets
    /// the caller keep exactly one preview render in flight instead of blocking
    /// on `nextDrawable()`.
    func renderToDrawable(
        _ frame: Frame,
        drawable: CAMetalDrawable,
        completion: @escaping @Sendable () -> Void
    ) {
        let pipeline = Self.isBiplanar(frame.pixelBuffer) ? biplanarPipeline : bgraPipeline
        let pass = Pass(pipeline: pipeline, texture: drawable.texture)
        if !encode(frame, passes: [pass], present: drawable, completion: completion) {
            completion()
        }
    }

    // MARK: - Encoding

    private struct Pass {
        let pipeline: MTLRenderPipelineState
        let texture: MTLTexture
    }

    private static func vector(_ rect: CGRect) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(rect.origin.x),
            Float(rect.origin.y),
            Float(rect.width),
            Float(rect.height)
        )
    }

    private static func isBiplanar(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func encode(
        _ frame: Frame,
        passes: [Pass],
        present drawable: CAMetalDrawable?,
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let isBiplanar = Self.isBiplanar(frame.pixelBuffer)

        var sourceTextures: [MTLTexture] = []
        if isBiplanar {
            guard let luma = makeTexture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm),
                let chroma = makeTexture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm)
            else { return false }
            sourceTextures = [luma, chroma]
        } else {
            guard let bgra = makeTexture(from: frame.pixelBuffer, plane: 0, format: .bgra8Unorm)
            else { return false }
            sourceTextures = [bgra]
        }

        // Blank means no person anywhere, so the background fills the frame.
        let mask = frame.personMask.flatMap {
            makeTexture(from: $0.buffer, plane: 0, format: .r8Unorm)
        }

        // Zero width switches the background, and the mask, off in the shader.
        var backgroundRect = SIMD4<Float>(0, 0, 0, 0)
        if let visible = frame.background?.visibleRect {
            backgroundRect = Self.vector(visible)
        }
        var maskRect = SIMD4<Float>(0, 0, 0, 0)
        if mask != nil, let region = frame.personMask?.region {
            maskRect = Self.vector(region)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        // Each source plane's visible part is shrunk and blurred before the
        // render passes, which then read one texel of it per pixel.
        //
        // ponytail: the room is blurred together with the person, so a faint
        // halo of the person's colours surrounds them; a blur that leaves the
        // person out would need the mask on this side of the render pass.
        var blurTextures: [MTLTexture] = []
        if frame.blurBackground {
            guard let planes = blurPlanes(like: sourceTextures) else { return false }
            for (source, plane) in zip(sourceTextures, planes) {
                encodeBlur(
                    of: source,
                    crop: frame.crop,
                    sigma: frame.matte.blurFraction,
                    into: plane,
                    commandBuffer: commandBuffer
                )
            }
            blurTextures = planes.map(\.blurred)
        }

        // Video range needs the 16...235 luma window expanded; full range does not.
        let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var uniforms = RenderUniforms(
            cropRect: SIMD4<Float>(
                Float(frame.crop.origin.x),
                Float(frame.crop.origin.y),
                Float(frame.crop.width),
                Float(frame.crop.height)
            ),
            overlayRect: frame.overlay.map {
                SIMD4<Float>(
                    Float($0.rect.origin.x),
                    Float($0.rect.origin.y),
                    Float($0.rect.width),
                    Float($0.rect.height)
                )
            } ?? SIMD4<Float>(0, 0, 0, 0),
            backgroundRect: backgroundRect,
            maskRect: maskRect,
            cameraRect: SIMD4<Float>(
                Float(frame.cameraRect.origin.x),
                Float(frame.cameraRect.origin.y),
                Float(frame.cameraRect.width),
                Float(frame.cameraRect.height)
            ),
            overlayOpacity: Float(frame.overlay?.opacity ?? 0),
            mirror: frame.mirror ? 1 : 0,
            lumaOffset: isFullRange ? 0.0 : 16.0 / 255.0,
            lumaScale: isFullRange ? 1.0 : 255.0 / 219.0,
            chromaOffset: 128.0 / 255.0,
            chromaScale: isFullRange ? 1.0 : 255.0 / 224.0,
            exposureGain: Float(frame.adjustments.exposureGain),
            blackLevel: Float(frame.adjustments.blackLevel),
            levelsGain: Float(frame.adjustments.levelsGain),
            midtoneExponent: Float(frame.adjustments.midtoneExponent),
            contrastAmount: Float(frame.adjustments.contrastAmount),
            saturationGain: Float(frame.adjustments.saturationGain),
            temperatureShift: Float(frame.adjustments.temperatureShift),
            tintShift: Float(frame.adjustments.tintShift),
            shadowShift: Float(frame.adjustments.shadowShift),
            highlightShift: Float(frame.adjustments.highlightShift),
            maskSpatialFactor: frame.matte.spatialFactor,
            maskRangeFactor: frame.matte.rangeFactor,
            maskShrink: Float(frame.matte.shrink),
            blurBackground: blurTextures.isEmpty ? 0 : 1
        )

        for pass in passes {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = pass.texture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return false }

            encoder.setRenderPipelineState(pass.pipeline)
            for (index, texture) in sourceTextures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
            }
            encoder.setFragmentTexture(frame.overlay?.texture ?? blankOverlay, index: 2)
            encoder.setFragmentTexture(frame.background?.texture ?? blankOverlay, index: 3)
            encoder.setFragmentTexture(mask ?? blankOverlay, index: 4)
            for index in sourceTextures.indices {
                let blurred = index < blurTextures.count ? blurTextures[index] : blankOverlay
                encoder.setFragmentTexture(blurred, index: 5 + index)
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
            encoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if let drawable { commandBuffer.present(drawable) }

        let retained = inFlightTextures
        commandBuffer.addCompletedHandler { _ in
            _ = retained
            completion?()
        }
        inFlightTextures.removeAll(keepingCapacity: true)

        commandBuffer.commit()
        // The cache holds a reference to every texture it hands out; without a
        // periodic flush the IOSurfaces behind them are never released back to
        // the capture device's pool.
        flushTextureCache()
        return true
    }

    // MARK: - Buffers and textures

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let effectiveWidth = planeCount == 0 ? CVPixelBufferGetWidth(pixelBuffer) : width
        let effectiveHeight = planeCount == 0 ? CVPixelBufferGetHeight(pixelBuffer) : height

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            effectiveWidth,
            effectiveHeight,
            plane,
            &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef,
            let texture = CVMetalTextureGetTexture(textureRef)
        else { return nil }
        inFlightTextures.append(textureRef)
        return texture
    }

    /// A source plane's visible part, shrunk into `scaled` and blurred into
    /// `blurred` by `gaussian`, which is replaced when the blur changes.
    private final class BlurPlane {
        let format: MTLPixelFormat
        let scaled: MTLTexture
        let blurred: MTLTexture
        var gaussian: MPSImageGaussianBlur?

        init(format: MTLPixelFormat, scaled: MTLTexture, blurred: MTLTexture) {
            self.format = format
            self.scaled = scaled
            self.blurred = blurred
        }
    }

    /// One `BlurPlane` per source plane, rebuilt when the camera's format
    /// changes. The chroma plane is half as wide.
    private func blurPlanes(like sources: [MTLTexture]) -> [BlurPlane]? {
        if blurPlanes.map(\.format) != sources.map(\.pixelFormat) {
            blurPlanes = []
            for source in sources {
                let width = Self.blurWidth * source.width / max(sources[0].width, 1)
                let height = width * OpenLensOutput.height / OpenLensOutput.width
                // BGRA is written as RGBA: the channels keep their meaning and
                // every GPU can write the format.
                let format = source.pixelFormat == .bgra8Unorm ? .rgba8Unorm : source.pixelFormat
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: width, height: height, mipmapped: false
                )
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                guard let scaled = device.makeTexture(descriptor: descriptor),
                    let blurred = device.makeTexture(descriptor: descriptor)
                else {
                    blurPlanes = []
                    return nil
                }
                blurPlanes.append(BlurPlane(format: source.pixelFormat, scaled: scaled, blurred: blurred))
            }
        }
        return blurPlanes
    }

    /// Shrinks `crop` of `source` into the plane and blurs it with a sigma of
    /// `sigma` times the visible width, so the blur looks the same at every
    /// zoom, camera resolution and plane size.
    private func encodeBlur(
        of source: MTLTexture,
        crop: CGRect,
        sigma: Double,
        into plane: BlurPlane,
        commandBuffer: MTLCommandBuffer
    ) {
        let pixels = Float(sigma * Double(plane.scaled.width))
        if plane.gaussian?.sigma != pixels {
            let gaussian = MPSImageGaussianBlur(device: device, sigma: pixels)
            gaussian.edgeMode = .clamp
            plane.gaussian = gaussian
        }
        let scaleX = Double(plane.scaled.width) / (crop.width * Double(source.width))
        let scaleY = Double(plane.scaled.height) / (crop.height * Double(source.height))
        var transform = MPSScaleTransform(
            scaleX: scaleX,
            scaleY: scaleY,
            translateX: -crop.minX * Double(source.width) * scaleX,
            translateY: -crop.minY * Double(source.height) * scaleY
        )
        withUnsafePointer(to: &transform) { transform in
            downscale.scaleTransform = transform
            downscale.encode(
                commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: plane.scaled
            )
        }
        downscale.scaleTransform = nil
        plane.gaussian?.encode(
            commandBuffer: commandBuffer, sourceTexture: plane.scaled, destinationTexture: plane.blurred
        )
    }

    private func pool(for size: CGSize) -> CVPixelBufferPool? {
        if let outputPool, outputPoolSize == size { return outputPool }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: OpenLensOutput.pixelFormat,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // A shallow pool is deliberate: it bounds latency and memory, and the
        // extension is always a frame or two behind at most.
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]

        var pool: CVPixelBufferPool?
        guard
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                attributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess
        else { return nil }

        outputPool = pool
        outputPoolSize = size
        return pool
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
