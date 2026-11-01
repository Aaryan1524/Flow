import Foundation

/// Cheap checks on captured audio, used to skip accidental or silent recordings before transcribing.
/// A proper voice activity detector can replace this later.
public enum AudioLevel {
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// True when nothing in the clip rises above the noise floor of a quiet room.
    public static func isSilent(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        peak(samples) < threshold
    }

    public static func duration(_ samples: [Float]) -> Double {
        Double(samples.count) / MicrophoneRecorder.sampleRate
    }
}
