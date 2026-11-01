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

    @Test func tracksHoldingState() {
        var gesture = HoldGesture()
        #expect(!gesture.isHolding)
        _ = gesture.handle(.fnDown, at: 1)
        #expect(gesture.isHolding)
        _ = gesture.handle(.otherKeyDown, at: 2)
        #expect(!gesture.isHolding)
    }
}
