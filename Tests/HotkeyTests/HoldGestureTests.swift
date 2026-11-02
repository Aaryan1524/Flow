import Testing
@testable import Hotkey

@Suite struct HoldGestureTests {
    @Test func holdStartsThenFinishes() {
        var gesture = HoldGesture(minimumHold: 0.2)
        #expect(gesture.handle(.fnDown, at: 10) == .started)
        #expect(gesture.handle(.fnUp, at: 11) == .finished)
    }

    @Test func accidentalTapIsCancelled() {
        var gesture = HoldGesture(minimumHold: 0.2)
        #expect(gesture.handle(.fnDown, at: 10) == .started)
        #expect(gesture.handle(.fnUp, at: 10.1) == .cancelled)
    }

    @Test func holdExactlyAtTheMinimumFinishes() {
        var gesture = HoldGesture(minimumHold: 0.2)
        _ = gesture.handle(.fnDown, at: 10)
        #expect(gesture.handle(.fnUp, at: 10.2) == .finished)
    }

    @Test func fnWithAnotherKeyCancelsAndIgnoresTheRelease() {
        var gesture = HoldGesture()
        #expect(gesture.handle(.fnDown, at: 10) == .started)
        #expect(gesture.handle(.otherKeyDown, at: 10.3) == .cancelled)
        #expect(gesture.handle(.fnUp, at: 11) == nil)
        // A fresh press afterwards works normally
        #expect(gesture.handle(.fnDown, at: 12) == .started)
        #expect(gesture.handle(.fnUp, at: 13) == .finished)
    }

    @Test func escapeCancelsWhileHolding() {
        var gesture = HoldGesture()
        _ = gesture.handle(.fnDown, at: 10)
        #expect(gesture.handle(.escape, at: 11) == .cancelled)
        #expect(gesture.handle(.fnUp, at: 12) == nil)
    }

    @Test func plainKeysWhileIdleDoNothing() {
        var gesture = HoldGesture()
        #expect(gesture.handle(.otherKeyDown, at: 1) == nil)
        #expect(gesture.handle(.escape, at: 2) == nil)
        #expect(gesture.handle(.fnUp, at: 3) == nil)
    }

    @Test func repeatedFnDownDoesNotRestart() {
        var gesture = HoldGesture()
        #expect(gesture.handle(.fnDown, at: 10) == .started)
        #expect(gesture.handle(.fnDown, at: 10.5) == nil)
        #expect(gesture.handle(.fnUp, at: 11) == .finished)
    }

    @Test func aStuckHoldIsClearedByAFreshGesture() {
        // Fn went down and the release was lost (sleep, lock). Without a reset the next press is ignored.
        var gesture = HoldGesture()
        _ = gesture.handle(.fnDown, at: 1)
        #expect(gesture.handle(.fnDown, at: 100) == nil)
        gesture = HoldGesture()
        #expect(gesture.handle(.fnDown, at: 100) == .started)
    }

    @Test func tracksHoldingState() {
        var gesture = HoldGesture()
        #expect(!gesture.isHolding)
        _ = gesture.handle(.fnDown, at: 1)
        #expect(gesture.isHolding)
        _ = gesture.handle(.otherKeyDown, at: 2)
        #expect(!gesture.isHolding)
    }

    // MARK: - Hands-free

    private func handsFreeGesture() -> HoldGesture { HoldGesture(minimumHold: 0.2, doubleTapWindow: 0.4) }

    @Test func twoQuickTapsStartHandsFreeRecordingThatOneMoreTapFinishes() {
        var gesture = handsFreeGesture()
        #expect(gesture.handle(.fnDown, at: 10) == .started)
        #expect(gesture.handle(.fnUp, at: 10.08) == .cancelled)  // the first tap on its own
        #expect(gesture.handle(.fnDown, at: 10.3) == .started)  // within the window
        #expect(gesture.handle(.fnUp, at: 10.38) == nil)  // latched: still recording
        #expect(gesture.isRecording)
        #expect(gesture.handle(.fnDown, at: 15) == .finished)  // the tap that ends it
        #expect(gesture.handle(.fnUp, at: 15.05) == nil)
        #expect(!gesture.isRecording)
    }

    @Test func escapeThrowsAwayAHandsFreeRecording() {
        var gesture = handsFreeGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.fnUp, at: 1.05)
        _ = gesture.handle(.fnDown, at: 1.2)
        _ = gesture.handle(.fnUp, at: 1.25)
        #expect(gesture.handle(.escape, at: 4) == .cancelled)
        #expect(!gesture.isRecording)
        #expect(gesture.handle(.fnDown, at: 6) == .started)
    }

    @Test func typingWhileTalkingHandsFreeDoesNotCancel() {
        var gesture = handsFreeGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.fnUp, at: 1.05)
        _ = gesture.handle(.fnDown, at: 1.2)
        _ = gesture.handle(.fnUp, at: 1.25)
        #expect(gesture.handle(.otherKeyDown, at: 2) == nil)
        #expect(gesture.isRecording)
    }

    @Test func aTapThenAHoldIsAnOrdinaryHold() {
        var gesture = handsFreeGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.fnUp, at: 1.05)
        #expect(gesture.handle(.fnDown, at: 1.2) == .started)
        #expect(gesture.handle(.fnUp, at: 3) == .finished)  // held: finishes on release
        #expect(!gesture.isRecording)
    }

    @Test func tapsTooFarApartAreTwoSeparateTaps() {
        var gesture = handsFreeGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.fnUp, at: 1.05)
        _ = gesture.handle(.fnDown, at: 2)  // 0.95 s later: outside the window
        #expect(gesture.handle(.fnUp, at: 2.05) == .cancelled)
        #expect(!gesture.isRecording)
    }

    @Test func withoutTheWindowTwoTapsAreJustTwoCancelledTaps() {
        var gesture = HoldGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.fnUp, at: 1.05)
        _ = gesture.handle(.fnDown, at: 1.2)
        #expect(gesture.handle(.fnUp, at: 1.25) == .cancelled)
    }

    @Test func fnWithAnotherKeyDoesNotCountAsATap() {
        var gesture = handsFreeGesture()
        _ = gesture.handle(.fnDown, at: 1)
        _ = gesture.handle(.otherKeyDown, at: 1.05)  // Fn+arrow
        _ = gesture.handle(.fnUp, at: 1.1)
        // The next quick tap must not be treated as the second half of a double-tap.
        _ = gesture.handle(.fnDown, at: 1.2)
        #expect(gesture.handle(.fnUp, at: 1.25) == .cancelled)
        #expect(!gesture.isRecording)
    }
}
