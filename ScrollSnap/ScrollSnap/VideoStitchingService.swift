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

struct StitchWindow: Codable, Equatable {
    static let minimumNormalizedHeight = 0.3
    static let minimumPixelHeight = 480.0

    var x: Double
    var y: Double
    var width: Double
    var height: Double

    nonisolated var isDefault: Bool {
        x.isZero && y.isZero && width >= 1 && height >= 1
    }

    nonisolated func cropRect(for imageSize: CGSize) -> CGRect {
        let normalizedMinX = min(max(0, x), 1)
        let normalizedMinY = min(max(0, y), 1)
        let normalizedMaxX = min(max(normalizedMinX, x + width), 1)
        let normalizedMaxY = min(max(normalizedMinY, y + height), 1)

        let minX = floor(normalizedMinX * imageSize.width)
        let minY = floor(normalizedMinY * imageSize.height)
        let maxX = ceil(normalizedMaxX * imageSize.width)
        let maxY = ceil(normalizedMaxY * imageSize.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func minimumHeight(forPixelHeight pixelHeight: Double) -> Double {
        guard pixelHeight > 0 else { return minimumNormalizedHeight }
        return min(1, max(minimumNormalizedHeight, minimumPixelHeight / pixelHeight))
    }

    static let `default` = StitchWindow(x: 0, y: 0, width: 1, height: 1)
    static let defaultAdjustment = StitchWindow(x: 0, y: 0.2, width: 1, height: 0.6)
}

enum StitchMatchAction: Equatable {
    case commit
    case accumulate
    case retry
}

struct StitchSamplingPolicy {
    let frameHeight: Int
    let maximumSearchShift: Int
    let minimumSpacing: Double
    let maximumSpacing: Double = 0.15
    let minimumCommitShift = 10
    let minimumConfidence: Float = 0.8

    var initialSpacing: Double {
        min(maximumSpacing, max(minimumSpacing, 0.05))
    }

    var targetShift: Int {
        let heightTarget = max(12, Int((Double(frameHeight) * 0.08).rounded()))
        let searchTarget = max(12, Int((Double(maximumSearchShift) * 0.45).rounded()))
        return min(80, heightTarget, searchTarget)
    }

    var maximumAcceptedShift: Int {
        max(minimumCommitShift, Int((Double(maximumSearchShift) * 0.8).rounded()))
    }

    func action(confidence: Float, shift: Int, isFinalCandidate: Bool) -> StitchMatchAction {
        guard confidence >= minimumConfidence, shift >= 0, shift <= maximumAcceptedShift else {
            return .retry
        }
        if shift < minimumCommitShift {
            return isFinalCandidate && shift > 0 ? .commit : .accumulate
        }
        return .commit
    }

    func spacing(afterShift shift: Int, elapsed: Double) -> Double {
        guard shift > 0, elapsed > 0 else { return initialSpacing }
        let velocity = Double(shift) / elapsed
        return min(maximumSpacing, max(minimumSpacing, Double(targetShift) / velocity))
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

    func stitch(
        videoURL: URL,
        startTime: Double = 0,
        endTime: Double? = nil,
        window: StitchWindow? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw StitchingError.noVideoTrack
        }

        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw StitchingError.noFramesExtracted }
        let effectiveStart = max(0, startTime)
        let effectiveEnd   = min(endTime ?? duration, duration)
        guard effectiveEnd > effectiveStart else { throw StitchingError.noFramesExtracted }
        let safeEnd = max(effectiveStart, effectiveEnd - 0.001)
        let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let frameDuration = nominalFrameRate > 0 ? 1 / Double(nominalFrameRate) : 1 / 30
        let minimumSpacing = min(0.05, max(1 / 120, frameDuration))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        func decodeFrame(seconds: Double) async throws -> CGImage {
            let clampedBase = min(max(effectiveStart, seconds), safeEnd)
            let attempts = [
                clampedBase,
                max(effectiveStart, clampedBase - 0.033),
                max(effectiveStart, clampedBase - 0.066),
                max(effectiveStart, clampedBase - 0.120)
            ]

            var lastError: Error?
            for attempt in attempts {
                do {
                    let t = CMTime(seconds: attempt, preferredTimescale: 600)
                    let frame = try await generator.image(at: t).image
                    if let window, !window.isDefault {
                        return frame.cropping(to: window.cropRect(for: CGSize(width: frame.width, height: frame.height))) ?? frame
                    }
                    return frame
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? StitchingError.noFramesExtracted
        }

        let contentFrame = try await decodeFrame(seconds: effectiveStart)

        // scrollbarX is detected lazily from the first valid seam pair and cached.
        var scrollbarX: Int? = nil

        let H = contentFrame.height
        let W = contentFrame.width
        let centerY = H / 2
        let bandHalfHeight = min(300, max(40, H / 4))
        let bandHeight = bandHalfHeight * 2
        let refY = centerY - bandHalfHeight
        let yStart = 0
        let horizontalInset = min(W / 12, max(0, (W - 1) / 2))
        let matchWidth = W - horizontalInset * 2
        let refRect = CGRect(x: horizontalInset, y: refY, width: matchWidth, height: bandHeight)
        let searchRect = CGRect(x: horizontalInset, y: yStart, width: matchWidth, height: refY + bandHeight)
        let matchScale: CGFloat = 0.5
        let samplingPolicy = StitchSamplingPolicy(
            frameHeight: H,
            maximumSearchShift: refY,
            minimumSpacing: minimumSpacing
        )

        struct Slice {
            let image: CGImage
        }

        func makeSlice(from image: CGImage, rect: CGRect, scrollbarX: Int?) -> Slice? {
            guard let cropped = image.cropping(to: rect) else { return nil }
            let cleaned = scrollbarX.flatMap { removeScrollbar(from: cropped, startX: $0) } ?? cropped
            return Slice(image: cleaned)
        }

        var canvasSlices: [Slice] = []
        guard let firstSlice = makeSlice(
            from: contentFrame,
            rect: CGRect(x: 0, y: 0, width: W, height: centerY + bandHalfHeight),
            scrollbarX: nil
        ) else { throw StitchingError.noFramesExtracted }
        canvasSlices.append(firstSlice)

        var referenceFrame = contentFrame
        var referenceTime = effectiveStart
        var tailFrame = contentFrame
        var referenceData = getGrayscalePixels(from: contentFrame, rect: refRect, scale: matchScale)
        guard referenceData != nil else { throw StitchingError.noFramesExtracted }

        var spacing = await samplingPolicy.initialSpacing
        var candidateTime = min(safeEnd, referenceTime + spacing)
        var furthestSampleTime = effectiveStart
        var firstFailedCandidateTime: Double?
        var cumulativeShift = 0

        samplingLoop: while candidateTime > referenceTime && candidateTime <= safeEnd {
            try Task.checkCancellation()

            let candidateFrame: CGImage
            do {
                candidateFrame = try await decodeFrame(seconds: candidateTime)
            } catch {
                print("[Stitch] Decode failed at t=\(String(format: "%.3f", candidateTime)); returning completed work: \(error.localizedDescription)")
                break
            }
            furthestSampleTime = max(furthestSampleTime, candidateTime)
            progress(0.2 + 0.7 * min((furthestSampleTime - effectiveStart) / (effectiveEnd - effectiveStart), 1.0))

            // On the first seam, detect the scrollbar position from this frame pair,
            // then back-patch the already-committed first slice.
            if scrollbarX == nil {
                scrollbarX = detectScrollbarXInFrames([referenceFrame, candidateFrame])
                if let sx = scrollbarX {
                    print("[Stitch] Scrollbar detected at x=\(sx); patching first slice.")
                    if let cleaned = removeScrollbar(from: canvasSlices[0].image, startX: sx) {
                        canvasSlices[0] = Slice(image: cleaned)
                    }
                }
            }

            guard let refData = referenceData,
                  let searchData = getGrayscalePixels(from: candidateFrame, rect: searchRect, scale: matchScale) else {
                print("[Stitch] Could not prepare t=\(String(format: "%.3f", candidateTime)) for matching; returning completed work.")
                break
            }

            let (maxVal, maxLocY) = computeNCC(
                template: refData.pixels,
                searchRegion: searchData.pixels,
                templateWidth: refData.width,
                templateHeight: refData.height,
                searchHeight: searchData.height
            )

            let yMatch = yStart + Int(CGFloat(maxLocY) / matchScale)
            let shift = refY - yMatch
            let elapsed = candidateTime - referenceTime
            let isFinalCandidate = candidateTime >= safeEnd - 0.0005

            print(String(format: "[Stitch] t=%.3f -> %.3f | dt: %.3f | maxVal: %.3f | yMatch: %d | shift: %d", referenceTime, candidateTime, elapsed, maxVal, yMatch, shift))

            switch await samplingPolicy.action(confidence: maxVal, shift: shift, isFinalCandidate: isFinalCandidate) {
            case .commit:
                let startY = yMatch + bandHeight
                let safeHeight = min(shift, H - startY)
                guard safeHeight > 0,
                      let slice = makeSlice(
                        from: candidateFrame,
                        rect: CGRect(x: 0, y: startY, width: W, height: safeHeight),
                        scrollbarX: scrollbarX
                      ) else {
                    print("[Stitch] Could not create a seam at t=\(String(format: "%.3f", candidateTime)); skipping it.")
                    referenceFrame = candidateFrame
                    referenceTime = candidateTime
                    tailFrame = candidateFrame
                    referenceData = getGrayscalePixels(from: candidateFrame, rect: refRect, scale: matchScale)
                    firstFailedCandidateTime = nil
                    spacing = await samplingPolicy.initialSpacing
                    if referenceData == nil || isFinalCandidate { break samplingLoop }
                    candidateTime = min(safeEnd, referenceTime + spacing)
                    continue samplingLoop
                }
                canvasSlices.append(slice)
                cumulativeShift += safeHeight

                referenceFrame = candidateFrame
                referenceTime = candidateTime
                tailFrame = candidateFrame
                referenceData = getGrayscalePixels(from: candidateFrame, rect: refRect, scale: matchScale)
                if referenceData == nil { break samplingLoop }
                firstFailedCandidateTime = nil
                spacing = await samplingPolicy.spacing(afterShift: shift, elapsed: elapsed)

                if isFinalCandidate { break samplingLoop }
                candidateTime = min(safeEnd, referenceTime + spacing)

            case .accumulate:
                firstFailedCandidateTime = nil
                if isFinalCandidate {
                    tailFrame = candidateFrame
                    break samplingLoop
                }
                spacing = min(samplingPolicy.maximumSpacing, spacing * 1.35)
                candidateTime = min(safeEnd, candidateTime + spacing)

            case .retry:
                if isFinalCandidate {
                    print("[Stitch] Final frame did not align; keeping it as the best-effort tail.")
                    tailFrame = candidateFrame
                    break samplingLoop
                }

                if firstFailedCandidateTime == nil && elapsed > minimumSpacing * 1.25 {
                    firstFailedCandidateTime = candidateTime
                    spacing = max(minimumSpacing, elapsed / 2)
                    candidateTime = referenceTime + spacing
                } else {
                    let failedAt = firstFailedCandidateTime ?? candidateTime
                    firstFailedCandidateTime = failedAt
                    if candidateTime - failedAt > 0.6 {
                        print("[Stitch] Could not align \(String(format: "%.3f", failedAt))–\(String(format: "%.3f", candidateTime)); skipping that span and rebasing.")
                        referenceFrame = candidateFrame
                        referenceTime = candidateTime
                        tailFrame = candidateFrame
                        referenceData = getGrayscalePixels(from: candidateFrame, rect: refRect, scale: matchScale)
                        firstFailedCandidateTime = nil
                        spacing = await samplingPolicy.initialSpacing
                        if referenceData == nil { break samplingLoop }
                        candidateTime = min(safeEnd, referenceTime + spacing)
                        continue samplingLoop
                    }
                    candidateTime = min(safeEnd, max(candidateTime + minimumSpacing, failedAt + minimumSpacing))
                }
            }

            if candidateTime <= referenceTime { break }
        }

        let tailY = centerY + bandHalfHeight
        let tailHeight = max(0, H - tailY)
        if tailHeight > 0 {
            let finalTailRect = CGRect(x: 0, y: tailY, width: W, height: tailHeight)
            guard let tailSlice = makeSlice(from: tailFrame, rect: finalTailRect, scrollbarX: scrollbarX) else {
                throw StitchingError.renderFailed
            }
            canvasSlices.append(tailSlice)
        }

        let totalHeight = canvasSlices.reduce(0) { $0 + $1.image.height }
        guard totalHeight == H + cumulativeShift else { throw StitchingError.renderFailed }
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
        guard searchWidth >= 2, !sampleRows.isEmpty else { return nil }

        let searchRect = CGRect(x: W - searchWidth, y: 0, width: searchWidth, height: H)
        let frameData = frames.compactMap {
            getGrayscalePixels(from: $0, rect: searchRect, scale: 1.0)
        }
        guard frameData.count == frames.count else { return nil }

        // Collect per-frame pixel values per column, then compute std dev across frames.
        var colStdDev = [Float](repeating: 0, count: searchWidth)
        for col in 0..<searchWidth {
            var values = [Float](repeating: 0, count: frames.count * sampleRows.count)
            var idx2 = 0
            for data in frameData {
                for row in sampleRows {
                    let pixIdx = row * searchWidth + col
                    values[idx2] = pixIdx < data.pixels.count ? data.pixels[pixIdx] : 0
                    idx2 += 1
                }
            }
            // std dev
            var mean: Float = 0
            vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
            var rawSumSquares: Float = 0
            vDSP_svesq(values, 1, &rawSumSquares, vDSP_Length(values.count))
            let variance = max(0, rawSumSquares / Float(values.count) - mean * mean)
            colStdDev[col] = sqrt(variance)
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

        context.interpolationQuality = .medium
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

        searchRegion.withUnsafeBufferPointer { searchPtr in
            guard let baseAddress = searchPtr.baseAddress else { return }

            for dy in 0...maxDy {
                let startIndex = dy * templateWidth
                let candidatePtr = baseAddress + startIndex

                var cMean: Float = 0
                vDSP_meanv(candidatePtr, 1, &cMean, vDSP_Length(N))

                var cRawSumSq: Float = 0
                vDSP_svesq(candidatePtr, 1, &cRawSumSq, vDSP_Length(N))
                let cSumSq = max(0, cRawSumSq - Float(N) * cMean * cMean)

                let cNorm = sqrt(cSumSq)
                if cNorm == 0 { continue }

                var dotProduct: Float = 0
                vDSP_dotpr(tZeroMean, 1, candidatePtr, 1, &dotProduct, vDSP_Length(N))

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
