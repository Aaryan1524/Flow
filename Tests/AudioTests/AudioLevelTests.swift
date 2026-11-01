import Testing
@testable import Audio

@Suite struct AudioLevelTests {
    @Test func emptyAndQuietClipsAreSilent() {
        #expect(AudioLevel.isSilent([]))
        #expect(AudioLevel.isSilent([Float](repeating: 0.002, count: 16_000)))
    }

    @Test func aSingleLoudSampleIsNotSilent() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = -0.2
        #expect(!AudioLevel.isSilent(samples))
        #expect(AudioLevel.peak(samples) == 0.2)
    }

    @Test func durationFollowsTheSampleRate() {
        #expect(AudioLevel.duration([Float](repeating: 0, count: 8_000)) == 0.5)
    }
}
