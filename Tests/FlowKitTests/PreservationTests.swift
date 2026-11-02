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
            input: "um the the release is uh ready, you know,",
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

    // MARK: - Correction cues

    @Test func anOrdinaryCueWordDoesNotDisableTheDroppedWordCheck() {
        let report = Preservation.check(
            input: "we should actually move the standup to ten and invite the design team",
            output: "Move the standup to ten and invite the design team.")
        #expect(report.droppedWords == ["we", "should", "actually"])
    }

    @Test func anOrdinaryCueWordDoesNotDisableTheChangedNumberCheck() {
        let report = Preservation.check(
            input: "please wait for 200 milliseconds before retrying",
            output: "Please wait for 20 milliseconds before retrying.")
        #expect(report.changedNumbers == ["200"])
    }

    @Test func theCorrectionExemptionOnlyCoversTheCorrectedClause() {
        let report = Preservation.check(
            input: "meet at three actually make that four and then bring the printed handouts for every person",
            output: "Meet at four and bring the printed handouts for every person.")
        #expect(report.droppedWords == ["then"])
        #expect(report.changedNumbers.isEmpty)
    }

    @Test func aCueNextToARepeatedOrReplacedPhraseStillExemptsTheRetractedWords() {
        #expect(Preservation.check(input: "the review is on Tuesday, no, Wednesday morning", output: "The review is on Wednesday morning.").isClean)
        #expect(Preservation.check(input: "we have twelve seats I mean fourteen seats in the room", output: "We have fourteen seats in the room.").isClean)
        #expect(Preservation.check(input: "book a table for six, sorry, for eight people", output: "Book a table for eight people.").isClean)
    }

    // MARK: - Dropped words and numbers

    @Test func wordsThatLookLikeDiscourseAreStillChecked() {
        let report = Preservation.check(input: "so we bought a new car like last year", output: "We bought a car last year.")
        #expect(report.droppedWords == ["so", "new", "like"])
    }

    @Test func commaBoundedFillersMayGo() {
        #expect(Preservation.check(input: "it was, like, the best concert, you know, ever", output: "It was the best concert ever.").isClean)
        #expect(Preservation.check(input: "I was, you know, thinking", output: "I was thinking.").isClean)
        #expect(Preservation.check(input: "um the the release is uh ready, you know,", output: "The release is ready.").isClean)
    }

    @Test func aBareYouKnowIsNotAFiller() {
        let report = Preservation.check(input: "do you know the answer", output: "Do the answer?")
        #expect(report.droppedWords == ["you", "know"])
    }

    @Test func countsRepeatedWordsNotJustTheirPresence() {
        let report = Preservation.check(input: "send the report to the team before the meeting", output: "Send the report to team before meeting.")
        #expect(report.droppedWords == ["the", "the"])
    }

    @Test func aStutterCollapseIsNotALoss() {
        #expect(Preservation.check(input: "the the report is is ready", output: "The report is ready.").isClean)
        #expect(Preservation.check(input: "we should we should call them", output: "We should call them.").isClean)
    }

    @Test func numbersAreComparedByValue() {
        #expect(Preservation.check(input: "we need fifteen chairs", output: "We need 51 chairs.").changedNumbers == ["fifteen"])
        #expect(Preservation.check(input: "we need fifteen chairs", output: "We need 15 chairs.").isClean)
        #expect(Preservation.check(input: "we need 2,500 chairs", output: "We need 2500 chairs.").isClean)
        #expect(Preservation.check(input: "it takes twenty five minutes", output: "It takes 25 minutes.").isClean)
        #expect(Preservation.check(input: "it takes 25 minutes", output: "It takes twenty-five minutes.").isClean)
        #expect(Preservation.check(input: "the call is at three thirty", output: "The call is at 3:30.").isClean)
        #expect(Preservation.check(input: "it takes twenty five minutes", output: "It takes five minutes.").changedNumbers == ["twenty five"])
    }

    @Test func capitalisedHyphenatedWordsAreNotIdentifiers() {
        #expect(Preservation.identifiers(in: "Twenty-Five people came with Jean-Luc").isEmpty)
        #expect(Preservation.identifiers(in: "call getUser-ById now") == ["getUser-ById"])
        #expect(Preservation.identifiers(in: "meet on the 5th at 3PM") .isEmpty)
    }

    @Test func spokenPunctuationWordsOnlyVanishAsDictatedCommands() {
        let report = Preservation.check(input: "we bought a new line of tools", output: "We bought a line of tools.")
        #expect(report.droppedWords == ["new"])
        #expect(Preservation.check(input: "dear team new line thanks", output: "Dear team\nThanks").isClean)
        #expect(Preservation.check(input: "are you done question mark", output: "Are you done?").isClean)
    }
}
