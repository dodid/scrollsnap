//
//  ScrollSnapTests.swift
//  ScrollSnapTests
//
//  Created by ww on 2026/2/26.
//

import Testing
import CoreGraphics
@testable import ScrollSnap

struct ScrollSnapTests {

    @Test func stitchWindowConvertsNormalizedCoordinatesToPixels() {
        let window = StitchWindow(x: 0, y: 0.2, width: 1, height: 0.6)

        #expect(window.cropRect(for: CGSize(width: 1179, height: 2556)) == CGRect(x: 0, y: 511, width: 1179, height: 1534))
    }

    @Test func stitchWindowCropStaysInsideImageBounds() {
        let window = StitchWindow(x: -0.2, y: 0.8, width: 1.5, height: 0.6)

        #expect(window.cropRect(for: CGSize(width: 100, height: 200)) == CGRect(x: 0, y: 160, width: 100, height: 40))
    }

    @Test func stitchWindowMinimumHeightPreservesEnoughPixelsForMatching() {
        #expect(StitchWindow.minimumHeight(forPixelHeight: 2_556) == 0.3)
        #expect(StitchWindow.minimumHeight(forPixelHeight: 720) == 2.0 / 3.0)
    }

    @Test func samplingPolicyKeepsSmallMovementsAgainstCommittedFrame() {
        let policy = StitchSamplingPolicy(frameHeight: 480, maximumSearchShift: 120, minimumSpacing: 1 / 30)

        #expect(policy.action(confidence: 0.95, shift: 7, isFinalCandidate: false) == .accumulate)
        #expect(policy.action(confidence: 0.95, shift: 7, isFinalCandidate: true) == .commit)
    }

    @Test func samplingPolicyRetriesUnsafeMatches() {
        let policy = StitchSamplingPolicy(frameHeight: 480, maximumSearchShift: 120, minimumSpacing: 1 / 30)

        #expect(policy.action(confidence: 0.79, shift: 30, isFinalCandidate: false) == .retry)
        #expect(policy.action(confidence: 0.95, shift: -1, isFinalCandidate: false) == .retry)
        #expect(policy.action(confidence: 0.95, shift: policy.maximumAcceptedShift + 1, isFinalCandidate: false) == .retry)
    }

    @Test func samplingPolicyAdaptsIntervalToWindowAndScrollSpeed() {
        let smallWindow = StitchSamplingPolicy(frameHeight: 480, maximumSearchShift: 120, minimumSpacing: 1 / 60)
        let largeWindow = StitchSamplingPolicy(frameHeight: 1_500, maximumSearchShift: 450, minimumSpacing: 1 / 60)

        #expect(smallWindow.targetShift < largeWindow.targetShift)
        #expect(smallWindow.spacing(afterShift: 90, elapsed: 0.1) < smallWindow.spacing(afterShift: 15, elapsed: 0.1))
        #expect(smallWindow.spacing(afterShift: 1, elapsed: 1) == smallWindow.maximumSpacing)
    }
}
