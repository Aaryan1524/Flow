import Testing
@testable import FlowKit

@Suite struct PreservationTests {
    @Test func detectsChangedIdentifierCase() {
        let report = Preservation.check(
            input: "um the camelCase variable getUserById is returning null",
            output: "The CamelCase variable getUserById is returning null.")
        #expect(report.lostIdentifiers == ["camelCase"])
    }

    @Test func acceptsPreservedIdentifiers() {
        let report = Preservation.check(
            input: "set OPENAI_API_KEY and call useAuthSession on the S3 bucket",
            output: "Set OPENAI_API_KEY and call useAuthSession on the S3 bucket.")
        #expect(report.isClean)
    }

    @Test func detectsSilentlyDroppedWords() {
        let report = Preservation.check(
            input: "i i think we should we should call the client back",
            output: "We should call the client back.")
        #expect(report.droppedWords == ["i", "think"])
    }

    @Test func allowsFillersAndStutters() {
        let report = Preservation.check(
            input: "um so the the release is uh ready you know",
            output: "The release is ready.")
        #expect(report.isClean)
    }

    @Test func allowsDroppedClauseWhenSpeakerCorrectedThemselves() {
        let report = Preservation.check(
            input: "send it to Maria no wait send it to Marcus",
            output: "Send it to Marcus.")
        #expect(report.isClean)
    }

    @Test func allowsHyphenatedAndDigitNumbers() {
        #expect(Preservation.check(input: "it takes twenty five minutes", output: "It takes twenty-five minutes.").isClean)
        #expect(Preservation.check(input: "it takes twenty five minutes", output: "It takes 25 minutes.").isClean)
    }

    @Test func detectsCorruptedNumbers() {
        let report = Preservation.check(
            input: "latency of 200 milliseconds at 3:30",
            output: "Latency of 20-than milliseconds at 3:30.")
        #expect(report.changedNumbers == ["200"])
        #expect(Preservation.check(input: "latency of 200 milliseconds.", output: "Latency of 200 milliseconds.").isClean)
    }

    @Test func numbersMayChangeWhenTheSpeakerCorrectedThemselves() {
        #expect(Preservation.check(input: "meet at 3 actually make that four", output: "Meet at four.").isClean)
    }

    @Test func ignoresStutterFragments() {
        #expect(Preservation.check(input: "w-we need to to finish", output: "We need to finish.").isClean)
        #expect(Preservation.check(input: "th- the report", output: "The report.").isClean)
    }

    @Test func allowsDictatedPunctuationWords() {
        let report = Preservation.check(input: "dear team comma the release is ready period", output: "Dear team, the release is ready.")
        #expect(report.isClean)
    }

    @Test func plainNumbersAndTimesAreNotIdentifiers() {
        #expect(Preservation.identifiers(in: "meet at 3:30 for $49, version 3.2.1").isEmpty)
        #expect(Preservation.identifiers(in: "deploy v2 to S3") == ["v2", "S3"])
    }

    @Test func detectsAnAnsweredRequest() {
        let report = Preservation.check(
            input: "write me an email to Bob about the delay",
            output: "Subject: Delay. Hi Bob, the release slipped.")
        #expect(!report.droppedWords.isEmpty)
    }
}
