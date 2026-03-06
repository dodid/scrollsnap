import Foundation
import AVFoundation
import UIKit
import Accelerate
import CoreGraphics

enum ScrollConfidence: Sendable {
    case confident
    case uncertain
    case notScrolling
}

enum StitchingError: LocalizedError {
    case noVideoTrack
    case noFramesExtracted
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "The selected video has no usable video track.")
        case .noFramesExtracted: return String(localized: "Could not extract frames from the video.")
        case .renderFailed: return String(localized: "Failed to render the final stitched image.")
        }
    }
}

actor VideoStitchingService {

    func detectScrollingVideo(videoURL: URL) async -> ScrollConfidence {
        return .confident
    }

    func extractFramePairWithOverlap(videoURL: URL, positionFraction: Double, offsetSeconds: Double) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw StitchingError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let time1 = duration * positionFraction
        let time2 = min(duration, time1 + offsetSeconds)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let t1 = CMTime(seconds: time1, preferredTimescale: 600)
        let t2 = CMTime(seconds: time2, preferredTimescale: 600)

        let cg1 = try await generator.image(at: t1).image
        let cg2 = try await generator.image(at: t2).image

        let W = cg1.width
        let H = cg1.height
        let centerY = H / 2
        let bandHalfHeight = 300
        let bandHeight = bandHalfHeight * 2

        let refRect = CGRect(x: 0, y: centerY - bandHalfHeight, width: W, height: bandHeight)

        let refY = centerY - bandHalfHeight
        let yStart = 0
        let yEnd = centerY - bandHalfHeight + 100
        let searchRegionHeight = (yEnd - yStart) + bandHeight
        let searchRect = CGRect(x: 0, y: yStart, width: W, height: searchRegionHeight)

        let scale: CGFloat = 0.5
        var yMatch = refY
        var maxVal: Float = 0

        if let refData = getGrayscalePixels(from: cg1, rect: refRect, scale: scale),
           let searchData = getGrayscalePixels(from: cg2, rect: searchRect, scale: scale) {

            let (matchVal, maxLocY) = computeNCC(
                template: refData.pixels,
                searchRegion: searchData.pixels,
                templateWidth: refData.width,
                templateHeight: refData.height,
                searchHeight: searchData.height
            )
            maxVal = matchVal
            if maxVal >= 0.6 {
                yMatch = yStart + Int(CGFloat(maxLocY) / scale)
            }
        }

        let shift = refY - yMatch

        print(String(format: "[Preview] Extract pairwise | maxVal: %.3f | yMatch: %d | shift: %d | refY: %d", maxVal, yMatch, shift, refY))

        let yOffset1 = max(0, -shift)
        let yOffset2 = max(0, shift)
        let canvasHeight = max(H + yOffset1, H + yOffset2)

        let size = CGSize(width: W * 2, height: canvasHeight)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            throw StitchingError.renderFailed
        }

        UIImage(cgImage: cg1).draw(in: CGRect(x: 0, y: yOffset1, width: W, height: H))
        UIImage(cgImage: cg2).draw(in: CGRect(x: W, y: yOffset2, width: W, height: H))

        let isDropped = (maxVal >= 0.6 && shift < 50)

        let attr: [NSAttributedString.Key: Any] = [
            .foregroundColor: isDropped ? UIColor.red : UIColor.cyan,
            .backgroundColor: UIColor.black.withAlphaComponent(0.7),
            .font: UIFont.monospacedSystemFont(ofSize: 40, weight: .bold)
        ]

        let shiftStr = String(format: "%d", shift)
        var infoStr = String(format: " NCC: %.3f ", maxVal)

        if isDropped {
            infoStr += " DROPPED (SHIFT: \(shiftStr)) "
        } else if maxVal >= 0.6 {
            infoStr += " SHIFT: \(shiftStr) "
        }

        NSString(string: infoStr).draw(at: CGPoint(x: W + 20, y: 40), withAttributes: attr)

        ctx.setStrokeColor(UIColor.cyan.cgColor)
        ctx.setLineWidth(4.0)
        ctx.setLineDash(phase: 0, lengths: [12.0, 8.0])

        let overlapRectA = CGRect(x: 0, y: yOffset1 + refY, width: W, height: bandHeight)
        let overlapRectB = CGRect(x: W, y: yOffset2 + yMatch, width: W, height: bandHeight)

        ctx.stroke(overlapRectA)
        ctx.stroke(overlapRectB)

        if shift >= 5 {
            ctx.setStrokeColor(UIColor.yellow.cgColor)
            ctx.setLineWidth(5.0)
            ctx.setLineDash(phase: 0, lengths: [])
            let startY = yOffset2 + yMatch + bandHeight
            let stitchRectB = CGRect(x: W, y: startY, width: W, height: shift)
            ctx.stroke(stitchRectB)
        }

        ctx.setStrokeColor(UIColor.red.cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineDash(phase: 0, lengths: [10.0, 10.0])
        ctx.beginPath()
        let alignedCenterY = CGFloat(yOffset1 + refY + bandHalfHeight)
        ctx.move(to: CGPoint(x: 0, y: alignedCenterY))
        ctx.addLine(to: CGPoint(x: CGFloat(W * 2), y: alignedCenterY))
        ctx.strokePath()

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let finalImage = result else { throw StitchingError.renderFailed }
        return finalImage
    }

    func stitch(videoURL: URL, startTime: Double = 0, endTime: Double? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw StitchingError.noVideoTrack
        }

        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw StitchingError.noFramesExtracted }
        let effectiveStart = max(0, startTime)
        let effectiveEnd   = min(endTime ?? duration, duration)
        guard effectiveEnd > effectiveStart else { throw StitchingError.noFramesExtracted }
        let safeDuration = max(0, effectiveEnd - 0.001)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let spacing = 0.1

        func decodeFrame(seconds: Double) async throws -> CGImage {
            let clampedBase = min(max(effectiveStart, seconds), safeDuration)
            let attempts: [Double] = [clampedBase, max(0, clampedBase - 0.033), max(0, clampedBase - 0.066), max(0, clampedBase - 0.120)]

            var lastError: Error?
            for attempt in attempts {
                do {
                    let t = CMTime(seconds: attempt, preferredTimescale: 600)
                    return try await generator.image(at: t).image
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? StitchingError.noFramesExtracted
        }

        let firstTime = CMTime(seconds: effectiveStart, preferredTimescale: 600)
        let firstFrame = try await generator.image(at: firstTime).image

        // scrollbarX is detected lazily from the first valid seam pair and cached.
        var scrollbarX: Int? = nil

        let H = firstFrame.height
        let W = firstFrame.width
        let centerY = H / 2
        let bandHalfHeight = 300
        let bandHeight = bandHalfHeight * 2

        struct Slice {
            let image: CGImage
        }

        func makeSlice(from image: CGImage, rect: CGRect, scrollbarX: Int?) -> Slice? {
            guard let cropped = image.cropping(to: rect) else { return nil }
            let cleaned = scrollbarX.flatMap { removeScrollbar(from: cropped, startX: $0) } ?? cropped
            return Slice(image: cleaned)
        }

        var canvasSlices: [Slice] = []
        // First slice is appended immediately; scrollbar will be patched once detected.
        if let firstSlice = makeSlice(
            from: firstFrame,
            rect: CGRect(x: 0, y: 0, width: W, height: centerY + bandHalfHeight),
            scrollbarX: nil
        ) {
            canvasSlices.append(firstSlice)
        }

        var referenceFrame = firstFrame
        var referenceTime = effectiveStart
        var latestFrame = firstFrame

        while referenceTime < effectiveEnd {
            try Task.checkCancellation()

            let nextTime = min(safeDuration, referenceTime + spacing)
            if nextTime <= referenceTime { break }

            let nextFrame: CGImage
            do {
                nextFrame = try await decodeFrame(seconds: nextTime)
            } catch {
                print("[Stitch] Decode failed near t=\(String(format: "%.3f", nextTime)); stopping gracefully: \(error.localizedDescription)")
                break
            }
            latestFrame = nextFrame

            // On the first seam, detect the scrollbar position from this frame pair,
            // then back-patch the already-committed first slice.
            if scrollbarX == nil {
                scrollbarX = detectScrollbarXInFrames([referenceFrame, nextFrame])
                if let sx = scrollbarX {
                    print("[Stitch] Scrollbar detected at x=\(sx); patching first slice.")
                    if let cleaned = removeScrollbar(from: canvasSlices[0].image, startX: sx) {
                        canvasSlices[0] = Slice(image: cleaned)
                    }
                }
            }

            let refRect = CGRect(x: 0, y: centerY - bandHalfHeight, width: W, height: bandHeight)

            let refY = centerY - bandHalfHeight
            let yStart = 0
            let yEnd = centerY - bandHalfHeight + 100
            let searchRegionHeight = (yEnd - yStart) + bandHeight

            if searchRegionHeight < bandHeight {
                print("[Stitch] Sample skipped (search region < bandHeight)")
                referenceFrame = nextFrame
                referenceTime = nextTime
                progress(0.2 + 0.7 * min((nextTime - effectiveStart) / (effectiveEnd - effectiveStart), 1.0))
                continue
            }

            let searchRect = CGRect(x: 0, y: yStart, width: W, height: searchRegionHeight)

            let scale: CGFloat = 0.5

            guard let refData = getGrayscalePixels(from: referenceFrame, rect: refRect, scale: scale),
                  let searchData = getGrayscalePixels(from: nextFrame, rect: searchRect, scale: scale) else {
                print("[Stitch] Sample t=\(String(format: "%.3f", nextTime)) skipped (failed to extract grayscale data)")
                referenceFrame = nextFrame
                referenceTime = nextTime
                continue
            }

            let (maxVal, maxLocY) = computeNCC(
                template: refData.pixels,
                searchRegion: searchData.pixels,
                templateWidth: refData.width,
                templateHeight: refData.height,
                searchHeight: searchData.height
            )

            let yMatch = yStart + Int(CGFloat(maxLocY) / scale)
            let shift = refY - yMatch

            print(String(format: "[Stitch] t=%.3f -> %.3f | dt: %.3f | maxVal: %.3f | yMatch: %d | shift: %d", referenceTime, nextTime, spacing, maxVal, yMatch, shift))

            if maxVal < 0.8 || shift > 650 {
                print(String(format: "[Stitch]    -> REJECTED (maxVal: %.3f, shift: %d). Advancing reference.", maxVal, shift))
                referenceFrame = nextFrame
                referenceTime = nextTime
                progress(0.2 + 0.7 * min((nextTime - effectiveStart) / (effectiveEnd - effectiveStart), 1.0))
                continue
            }

            if shift < 10 {
                print("[Stitch]    -> SKIPPED (shift < 10). Accumulating shift...")
                referenceFrame = nextFrame
                referenceTime = nextTime
                progress(0.2 + 0.7 * min((nextTime - effectiveStart) / (effectiveEnd - effectiveStart), 1.0))
                continue
            }

            let startY = yMatch + bandHeight
            let sliceHeight = shift
            let safeHeight = min(sliceHeight, H - startY)

            print("[Stitch]    -> ACCEPTED. Appending slice startY: \(startY) height: \(safeHeight)")

            if safeHeight > 0 {
                let sliceRect = CGRect(x: 0, y: startY, width: W, height: safeHeight)
                if let slice = makeSlice(from: nextFrame, rect: sliceRect, scrollbarX: scrollbarX) {
                    canvasSlices.append(slice)
                }
            }

            referenceFrame = nextFrame
            referenceTime = nextTime

            progress(0.2 + 0.7 * min((nextTime - effectiveStart) / (effectiveEnd - effectiveStart), 1.0))
        }

        let tailY = centerY + bandHalfHeight
        let tailHeight = max(0, H - tailY)
        if tailHeight > 0 {
            let finalTailRect = CGRect(x: 0, y: tailY, width: W, height: tailHeight)
            if let tailSlice = makeSlice(from: latestFrame, rect: finalTailRect, scrollbarX: scrollbarX) {
                canvasSlices.append(tailSlice)
            }
        }

        let totalHeight = canvasSlices.reduce(0) { $0 + $1.image.height }
        let finalSize = CGSize(width: W, height: totalHeight)

        UIGraphicsBeginImageContextWithOptions(finalSize, false, 1.0)

        var currentY: CGFloat = 0
        for slice in canvasSlices {
            let h = CGFloat(slice.image.height)
            let drawRect = CGRect(x: 0, y: currentY, width: CGFloat(W), height: h)
            UIImage(cgImage: slice.image).draw(in: drawRect)
            currentY += h
        }

        let finalImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let resultImage = finalImage else {
            throw StitchingError.renderFailed
        }

        progress(1.0)
        return resultImage
    }

    // MARK: - Scrollbar Removal

    /// Detects the x-coordinate where the scrollbar track begins by comparing temporal
    /// variance of columns near the right edge across the provided frames.
    /// The scroll indicator slides vertically between frames, so its column has
    /// distinctly higher variance than surrounding static content columns.
    /// Called with a seam pair (referenceFrame + nextFrame) during stitching.
    func detectScrollbarXInFrames(_ frames: [CGImage]) -> Int? {
        guard frames.count >= 2 else { return nil }

        let W = frames[0].width
        let H = frames[0].height
        let searchWidth = min(40, W / 6)   // inspect rightmost 40px (or up to 1/6 of width)
        let sampleRows  = stride(from: H / 8, to: 7 * H / 8, by: max(1, H / 60)).map { $0 }

        // Collect per-frame pixel values per column, then compute std dev across frames.
        var colStdDev = [Float](repeating: 0, count: searchWidth)
        for col in 0..<searchWidth {
            var values = [Float](repeating: 0, count: frames.count * sampleRows.count)
            var idx2 = 0
            for frame in frames {
                let searchRect = CGRect(x: W - searchWidth, y: 0, width: searchWidth, height: H)
                guard let data = getGrayscalePixels(from: frame, rect: searchRect, scale: 1.0) else { idx2 += sampleRows.count; continue }
                for row in sampleRows {
                    let pixIdx = row * searchWidth + col
                    values[idx2] = pixIdx < data.pixels.count ? data.pixels[pixIdx] : 0
                    idx2 += 1
                }
            }
            // std dev
            var mean: Float = 0
            vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
            var sq: Float = 0
            var negMean = -mean
            var zmv = [Float](repeating: 0, count: values.count)
            vDSP_vsadd(values, 1, &negMean, &zmv, 1, vDSP_Length(values.count))
            vDSP_svesq(zmv, 1, &sq, vDSP_Length(values.count))
            colStdDev[col] = sqrt(sq / Float(values.count))
        }

        // The scrollbar column(s) will be near the RIGHT end and have elevated std dev.
        // Scan from the right and find where std dev falls back to baseline content level.
        // Baseline: median of leftmost half of search region
        let baseline: Float = {
            let half = Array(colStdDev.prefix(searchWidth / 2)).sorted()
            return half[half.count / 2]
        }()
        let threshold = baseline * 1.6 + 2.0   // 60% above baseline, min +2

        // Find leftmost column (from right) that exceeds threshold — that's the scrollbar left edge
        var scrollbarLeftOffset: Int? = nil
        for col in stride(from: searchWidth - 1, through: 0, by: -1) {
            if colStdDev[col] > threshold {
                scrollbarLeftOffset = col
            } else if scrollbarLeftOffset != nil {
                break   // we've already found the block and it ended further right
            }
        }

        guard let offset = scrollbarLeftOffset else { return nil }
        let absX = (W - searchWidth) + offset
        // Sanity check: scrollbar should be narrow (≤ 20px) and close to the edge
        let scrollbarWidth = W - absX
        guard scrollbarWidth <= 20 && scrollbarWidth >= 2 else { return nil }

        print("[ScrollbarDetect] Detected scrollbar at x=\(absX) (width=\(scrollbarWidth)). Baseline stdDev=\(String(format:"%.2f", baseline))")
        return absX
    }

    /// Fills the scrollbar columns (from `scrollbarX` to the right edge) in each
    /// stitched slice by copying the pixel column immediately to the left.
    private func removeScrollbar(from image: CGImage, startX: Int) -> CGImage? {
        let W = image.width
        let H = image.height
        guard startX > 0, startX < W else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = W * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: H * bytesPerRow)

        guard let ctx = CGContext(data: &pixelData,
                                  width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))

        // For every row, copy the pixel at (startX - 1) into columns startX … W-1
        let srcX = startX - 1
        for row in 0..<H {
            let rowBase = row * bytesPerRow
            let srcBase = rowBase + srcX * bytesPerPixel
            let r = pixelData[srcBase]
            let g = pixelData[srcBase + 1]
            let b = pixelData[srcBase + 2]
            let a = pixelData[srcBase + 3]
            for col in startX..<W {
                let dstBase = rowBase + col * bytesPerPixel
                pixelData[dstBase]     = r
                pixelData[dstBase + 1] = g
                pixelData[dstBase + 2] = b
                pixelData[dstBase + 3] = a
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Pixel Utilities

    private func getGrayscalePixels(from image: CGImage, rect: CGRect, scale: CGFloat = 1.0) -> (pixels: [Float], width: Int, height: Int)? {
        guard let cropped = image.cropping(to: rect) else { return nil }

        let width = Int(CGFloat(cropped.width) * scale)
        let height = Int(CGFloat(cropped.height) * scale)

        guard width > 0 && height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        var floatPixels = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(pixels, 1, &floatPixels, 1, vDSP_Length(width * height))
        return (floatPixels, width, height)
    }

    private func computeNCC(template: [Float], searchRegion: [Float], templateWidth: Int, templateHeight: Int, searchHeight: Int) -> (maxVal: Float, maxLocY: Int) {
        let N = templateWidth * templateHeight
        guard N > 0, searchHeight >= templateHeight else { return (0, 0) }

        var tMean: Float = 0
        vDSP_meanv(template, 1, &tMean, vDSP_Length(N))

        var tZeroMean = [Float](repeating: 0, count: N)
        var negTMean = -tMean
        vDSP_vsadd(template, 1, &negTMean, &tZeroMean, 1, vDSP_Length(N))

        var tSumSq: Float = 0
        vDSP_svesq(tZeroMean, 1, &tSumSq, vDSP_Length(N))

        let tNorm = sqrt(tSumSq)
        if tNorm == 0 { return (0, 0) }

        var maxNCC: Float = -1.0
        var bestY: Int = 0

        let maxDy = searchHeight - templateHeight

        for dy in 0...maxDy {
            let startIndex = dy * templateWidth

            searchRegion.withUnsafeBufferPointer { searchPtr in
                guard let baseAddress = searchPtr.baseAddress else { return }
                let candidatePtr = baseAddress + startIndex

                var cMean: Float = 0
                vDSP_meanv(candidatePtr, 1, &cMean, vDSP_Length(N))

                var cZeroMean = [Float](repeating: 0, count: N)
                var negCMean = -cMean
                vDSP_vsadd(candidatePtr, 1, &negCMean, &cZeroMean, 1, vDSP_Length(N))

                var cSumSq: Float = 0
                vDSP_svesq(cZeroMean, 1, &cSumSq, vDSP_Length(N))

                let cNorm = sqrt(cSumSq)
                if cNorm == 0 { return }

                var dotProduct: Float = 0
                vDSP_dotpr(tZeroMean, 1, cZeroMean, 1, &dotProduct, vDSP_Length(N))

                let ncc = dotProduct / (tNorm * cNorm)
                if ncc > maxNCC {
                    maxNCC = ncc
                    bestY = dy
                }
            }
        }

        return (maxNCC, bestY)
    }
}
