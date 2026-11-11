import Foundation
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers

enum SnapshotError: Error, CustomStringConvertible {
    case texture(String)
    case commandBuffer
    case image
    case write(String)

    var description: String {
        switch self {
        case .texture(let m):   return "Could not create texture: \(m)"
        case .commandBuffer:    return "Could not create a command buffer."
        case .image:            return "Could not build a CGImage from the render result."
        case .write(let m):     return "Could not write PNG: \(m)"
        }
    }
}

enum Snapshot {

    /// Runs several frames offscreen and returns average milliseconds.
    static func measure(renderer: Renderer,
                        width: Int,
                        height: Int,
                        frames: Int,
                        time: Float) throws -> Double {
        let device = renderer.context.device
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let color = device.makeTexture(descriptor: desc) else {
            throw SnapshotError.texture("bench \(width)x\(height)")
        }

        func renderOnce() throws {
            guard let cb = renderer.context.queue.makeCommandBuffer() else {
                throw SnapshotError.commandBuffer
            }
            renderer.encodeFrame(commandBuffer: cb, target: color, time: time)
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error {
                throw SnapshotError.write(String(describing: error))
            }
        }

        for _ in 0..<2 { try renderOnce() }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<max(frames, 1) { try renderOnce() }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return elapsed / Double(max(frames, 1)) * 1000.0
    }

    /// Renders one frame offscreen and writes it as a PNG.
    @discardableResult
    static func write(renderer: Renderer,
                      width: Int,
                      height: Int,
                      time: Float,
                      to url: URL) throws -> URL {
        let device = renderer.context.device

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private

        guard let color = device.makeTexture(descriptor: colorDesc) else {
            throw SnapshotError.texture("color \(width)x\(height)")
        }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        guard let readback = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = renderer.context.queue.makeCommandBuffer() else {
            throw SnapshotError.commandBuffer
        }

        renderer.encodeFrame(commandBuffer: commandBuffer,
                             target: color,
                             time: time)

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw SnapshotError.commandBuffer
        }
        blit.copy(from: color,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: byteCount)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw SnapshotError.write(String(describing: error))
        }

        let data = Data(bytes: readback.contents(), count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw SnapshotError.image
        }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)

        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw SnapshotError.image
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.write(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.write(url.path)
        }

        return url
    }
}
