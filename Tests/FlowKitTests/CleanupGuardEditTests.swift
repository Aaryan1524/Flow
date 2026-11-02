import Testing
@testable import FlowKit

/// The guard accepts an output only when every difference from the dictation is an allowed edit. These are the
/// outputs that slipped past a tolerance-based guard, and the real corrections it wrongly refused.
@Suite struct CleanupGuardEditTests {
    let guardrail = CleanupGuard.standard

    private func trusts(_ raw: String, _ cleaned: String) -> Bool {
        guardrail.isTrustworthy(raw: raw, cleaned: cleaned)
    }

    private func failure(_ raw: String, _ cleaned: String) -> CleanupGuard.Failure? {
        guardrail.evaluate(raw: raw, cleaned: cleaned).failure
    }

    // MARK: - An answer hidden in a long dictation

    @Test func rejectsAnAnswerSpliceIntoALongDictation() {
        let raw =
            "okay so I wanted to give you a quick update on the project we finished the migration last week and what is the capital of France and then we also need to schedule the review with the design team for next Thursday afternoon"
        let cleaned =
            "Okay, so I wanted to give you a quick update on the project. We finished the migration last week, Paris, and then we also need to schedule the review with the design team for next Thursday afternoon."
        #expect(!trusts(raw, cleaned))
    }

    @Test func rejectsAnAnswerThatReplacesTheQuestionInPlace() {
        let raw =
            "I will be late tomorrow because of the dentist. What is the capital of France? Also please move the standup to ten and invite the design team and the product managers."
        let cleaned =
            "I will be late tomorrow because of the dentist. Paris. Also please move the standup to ten and invite the design team and the product managers."
        #expect(!trusts(raw, cleaned))
    }

    @Test func rejectsAnAnswerAppendedToARepeatedQuestion() {
        let raw = "sorry what is the capital of france and what is its population today"
        let cleaned = "Sorry, what is the capital of France, and what is its population today? Paris."
        #expect(!trusts(raw, cleaned))
    }

    // MARK: - Words added to the end or the start

    private let paragraph =
        "the quarterly planning meeting covered the new hiring targets the delayed launch of the mobile app and the budget for the second half of the year everyone agreed that the testing schedule needs more time before we ship anything to customers this summer"
    private let cleanParagraph =
        "The quarterly planning meeting covered the new hiring targets, the delayed launch of the mobile app, and the budget for the second half of the year. Everyone agreed that the testing schedule needs more time before we ship anything to customers this summer."

    @Test func theLongParagraphHasFortyThreeWordsAndPassesAsIs() {
        #expect(paragraph.split(separator: " ").count == 43)
        #expect(trusts(paragraph, cleanParagraph))
    }

    @Test func rejectsASentenceAppendedToALongParagraph() {
        for extra in [" It is Paris.", " Answer: Paris.", " Arr matey.", " Thanks."] {
            #expect(!trusts(paragraph, cleanParagraph + extra), "appended \(extra)")
        }
    }

    @Test func rejectsAnAnswerAfterAQuestion() {
        #expect(
            !trusts(
                "can you tell me whether the meeting is on friday or monday",
                "Can you tell me whether the meeting is on Friday or Monday? Monday."))
    }

    @Test func rejectsPrefacesAndSignOffs() {
        let raw = "please send the weekly report to the whole team before noon today"
        #expect(!trusts(raw, "Okay. Please send the weekly report to the whole team before noon today."))
        #expect(!trusts(raw, "Please send the weekly report to the whole team before noon today. Done."))
        #expect(!trusts(raw, "Understood: please send the weekly report to the whole team before noon today."))
        #expect(!trusts(raw, "Sure, please send the weekly report to the whole team before noon today."))
        #expect(!trusts("please send the weekly report to the whole team and then wait", "Please send the weekly report to the whole team and then wait. Regards"))
        #expect(!trusts("please send the weekly report to the whole team and then wait", "Please send the weekly report to the whole team, then wait. Regards"))
        #expect(trusts(raw, "Please send the weekly report to the whole team before noon today."))
    }

    // MARK: - Whole sentences dropped

    private let fourSentences =
        "Please send the invoice to Dana by Friday. Then book the conference room for the offsite on Monday. Also remind me to call the plumber about the leak in the kitchen. After that we should review the quarterly budget with finance."

    @Test func rejectsALostLastOrMiddleSentence() {
        #expect(trusts(fourSentences, fourSentences))
        #expect(
            !trusts(
                fourSentences,
                "Please send the invoice to Dana by Friday. Then book the conference room for the offsite on Monday. Also remind me to call the plumber about the leak in the kitchen."))
        #expect(
            !trusts(
                fourSentences,
                "Please send the invoice to Dana by Friday. Also remind me to call the plumber about the leak in the kitchen. After that we should review the quarterly budget with finance."))
        #expect(
            !trusts(
                fourSentences,
                "Then book the conference room for the offsite on Monday. Also remind me to call the plumber about the leak in the kitchen. After that we should review the quarterly budget with finance."))
    }

    @Test func rejectsALostTailOfASentence() {
        #expect(
            !trusts(
                "we should ship the fix on friday and tell the customers about it", "We should ship the fix on Friday and tell the customers."))
        #expect(trusts("we should ship the fix on friday and tell the customers about it", "We should ship the fix on Friday and tell the customers about it."))
    }

    // MARK: - Substituted words

    @Test func rejectsASubstitutedWord() {
        #expect(!trusts("the review with the design team is on monday afternoon", "The review with the design team is on Tuesday afternoon."))
        #expect(!trusts("please ask john to call the vendor and ask him to send the quote", "Please ask Jane to call the vendor and ask him to send the quote."))
        #expect(!trusts("send the contract to john and ask him to sign it today", "Send the contract to Jane and ask him to sign it today."))
        #expect(!trusts("the budget increase needs approval before the end of the quarter", "The budget decrease needs approval before the end of the quarter."))
        #expect(!trusts("the dog bit the man", "The man bit the dog."))
    }

    @Test func rejectsAnOppositeInALongSentence() {
        let raw =
            "after reading the full proposal from the vendor and talking it through with the finance team and the legal team and the two engineers who will maintain the system the committee decided to approve the contract on thursday"
        let cleaned =
            "After reading the full proposal from the vendor and talking it through with the finance team and the legal team and the two engineers who will maintain the system, the committee decided to reject the contract on Thursday."
        #expect(raw.split(separator: " ").count >= 35)
        #expect(!trusts(raw, cleaned))
        #expect(trusts(raw, cleaned.replacingOccurrences(of: "reject", with: "approve")))
    }

    // MARK: - Numbers

    @Test func rejectsANumberWrittenWithAnotherValue() {
        #expect(!trusts("actually the call starts at three thirty tomorrow", "Actually, the call starts at 3:00 tomorrow."))
        #expect(!trusts("the meeting is at ten thirty tomorrow", "The meeting is at 10 tomorrow."))
        #expect(!trusts("the meeting is at ten thirty tomorrow", "The meeting is at 30 tomorrow."))
        #expect(!trusts("the train leaves at nine fifteen sharp", "The train leaves at 9:00 sharp."))
        #expect(trusts("actually the call starts at three thirty tomorrow", "Actually, the call starts at 3:30 tomorrow."))
        #expect(trusts("the meeting is at ten thirty tomorrow", "The meeting is at 10:30 tomorrow."))
        #expect(trusts("the train leaves at nine fifteen sharp", "The train leaves at 9:15 sharp."))
    }

    @Test func rejectsANumberLostOrMovedAmongSeveral() {
        #expect(!trusts("we need 5 chairs and 5 tables", "We need 5 chairs and tables."))
        #expect(trusts("we need 5 chairs and 5 tables", "We need 5 chairs and 5 tables."))
        #expect(
            !trusts(
                "move 12 apples to box 34 and 56 pears to box 78",
                "Move 34 apples to box 12 and 78 pears to box 56."))
        #expect(trusts("move 12 apples to box 34 and 56 pears to box 78", "Move 12 apples to box 34 and 56 pears to box 78."))
    }

    @Test func acceptsSpokenNumbersWrittenWithTheSameValue() {
        #expect(trusts("we raised ten million dollars", "We raised $10 million"))
        #expect(trusts("we raised ten million dollars", "We raised $10 million."))
        #expect(trusts("the file is two point five gigabytes", "The file is 2.5 GB."))
        #expect(trusts("two point five gigabytes", "2.5 GB"))
        #expect(trusts("it takes twenty five minutes", "It takes 25 minutes."))
        #expect(trusts("it takes twenty five minutes", "It takes twenty-five minutes."))
        #expect(!trusts("two point five gigabytes", "2.5 MB"))
        #expect(!trusts("we raised ten million dollars", "We raised $10 billion."))
    }

    @Test func acceptsNumbersWrittenInTheirUsualShape() {
        #expect(trusts("call me at five five five one two three four", "Call me at 555-1234."))
        #expect(trusts("the part is five mm wide", "The part is 5 mm wide."))
        #expect(trusts("the meeting is at 3pm", "The meeting is at 3 p.m."))
        #expect(trusts("we shipped on march third", "We shipped on March 3rd."))
        #expect(!trusts("call me at five five five one two three four", "Call me at 555-1243."))
    }

    @Test func acceptsUrlsEmailsPathsAndUnicodeLeftAlone() {
        for text in [
            "Open https://example.com/docs?id=5 and email dana@example.com about /usr/local/bin and caf\u{00E9} \u{2615}",
            "The report is due on 2025-03-04, see build_notes.md and v2.4.1 of getUserById.",
            "Dana\u{2019}s caf\u{00E9} serves \u{00FC}ber-fresh bread at 9:30.",
        ] {
            #expect(trusts(text, text), "\(text)")
        }
    }

    @Test func aWordMayBeSplitOrJoinedWithoutChangingItsLetters() {
        #expect(trusts("send me an e mail", "Send me an email."))
        #expect(trusts("send me an email", "Send me an e-mail."))
        #expect(trusts("it is a well known fact", "It is a well-known fact."))
        #expect(!trusts("send me an e mail", "Send me an mail."))
    }

    @Test func aMuchLongerOutputIsRejectedAsTooLong() {
        let raw = "please remember to water the plants"
        #expect(failure(raw, raw + ". " + raw + ". " + raw + ".") == .tooLong)
    }

    @Test func aMillimetreIsNotAFiller() {
        #expect(trusts("mm hmm okay sure", "Okay, sure."))
        #expect(!trusts("the part is 5 mm wide", "The part is 5 wide."))
    }

    @Test func spokenIdentifiersMayBeJoinedWithUnderscores() {
        #expect(trusts("set the variable api base url to the staging host", "Set the variable API_BASE_URL to the staging host."))
        #expect(trusts("rename use auth session to use session", "Rename useAuthSession to useSession."))
        #expect(!trusts("this is really important", "This is _really_ important."))
    }

    @Test func aColonMayBeFollowedByACapital() {
        #expect(trusts("note the meeting starts at nine", "Note: The meeting starts at nine."))
        #expect(trusts("a b c", "A, B, C."))
        #expect(!trusts("note the meeting starts at nine", "Note The Meeting Starts At Nine."))
    }

    @Test func invisibleCharactersAreSymbols() {
        #expect(!trusts("call the dentist", "Call the\u{200B} dentist."))
        #expect(!trusts("call the dentist", "Call the dentist.\u{202E}"))
    }

    // MARK: - A cue is not a licence

    @Test func anOrdinaryCueWordDoesNotExcuseADroppedClause() {
        #expect(!trusts("we should actually move the standup to ten and invite the design team", "Move the standup to ten."))
        #expect(!trusts("we should actually move the standup to ten and invite the design team", "We should move the standup to ten."))
    }

    @Test func aRetractionOnlyCoversTheClauseDirectlyBeforeTheCue() {
        let raw =
            "Please call Dana at the office about the overdue invoice and the missing purchase order. Actually, call her on Monday about the contract."
        #expect(!trusts(raw, "Please call Dana. Actually, call her on Monday about the contract."))
        #expect(!trusts(raw, "Please call Dana. Call her on Monday about the contract."))
        #expect(trusts(raw, raw))
    }

    @Test func aRetractionNeedsWhatFollowsToReplaceIt() {
        // The words after the cue say something else: nothing is taken back, so everything stays.
        #expect(!trusts("send the invoice to Dana sorry the weather is nice today", "The weather is nice today."))
        #expect(!trusts("book the large room no thanks that works for us", "Thanks that works for us."))
    }

    // MARK: - Format

    @Test func rejectsAnOutputInAnotherCase() {
        let raw = "please send the weekly report to the team before noon"
        #expect(!trusts(raw, "PLEASE SEND THE WEEKLY REPORT TO THE TEAM BEFORE NOON."))
        #expect(!trusts(raw, "Please Send The Weekly Report To The Team Before Noon."))
        #expect(trusts(raw, "Please send the weekly report to the team before noon."))
    }

    @Test func rejectsLostCapitalsOnNames() {
        #expect(!trusts("Ask Dana to call Boston", "Ask dana to call boston."))
        #expect(!trusts("Ask Dana to call Boston", "Ask Dana to call boston."))
        #expect(!trusts("Please call Dana tomorrow", "please call dana tomorrow."))
        #expect(!trusts("I think the NASA team is ready", "I think the Nasa team is ready."))
        #expect(!trusts("I think we should go", "i think we should go."))
        #expect(trusts("ask dana to call boston", "Ask Dana to call Boston."))
        #expect(trusts("Ask Dana to call Boston", "Ask Dana to call Boston."))
        #expect(trusts("the api returns a pdf", "The API returns a PDF."))
    }

    @Test func rejectsSymbolsTheSpeakerNeverDictated() {
        let raw = "this is really important for the launch"
        #expect(!trusts(raw, "This is *really* important for the launch."))
        #expect(!trusts(raw, "This is _really_ important for the launch."))
        #expect(!trusts("great work on the launch team", "Great work on the launch team :)"))
        #expect(!trusts("call the dentist", "#Call the dentist"))
        #expect(!trusts("call the dentist", "Call the dentist. \u{2192}\u{2192}\u{2192} ==== ####"))
        #expect(!trusts("call the dentist", "Call the dentist. ---"))
        #expect(trusts("call the dentist", "Call the dentist."))
    }

    @Test func aDictatedPunctuationWordNeedsItsSymbolAtThatPoint() {
        #expect(!trusts("the waiting period ends on friday", "The waiting ends on Friday."))
        #expect(trusts("the waiting period ends on friday", "The waiting period ends on Friday."))
        #expect(trusts("dear team comma new paragraph the release is ready period", "Dear team,\n\nThe release is ready."))
        #expect(!trusts("dear team comma new paragraph the release is ready period", "Dear team The release is ready."))
        #expect(!trusts("dear team comma the release is ready", "Dear team the release is ready."))
        #expect(!trusts("dear team comma the release is ready period", "Dear team the release is ready."))
        #expect(!trusts("we bought a new line of tools", "We bought a line of tools."))
        #expect(trusts("first item new line second item", "First item\nsecond item"))
        #expect(!trusts("first item new line second item", "First item second item"))
    }

    @Test func aYouKnowIsOnlyAFillerBetweenCommas() {
        #expect(!trusts("i think you know", "I think."))
        #expect(trusts("i think, you know, that works", "I think that works."))
        #expect(!trusts("do you know the answer", "Do the answer?"))
        #expect(trusts("it was, like, really late", "It was really late."))
        #expect(!trusts("it was like really late", "It was really late."))
    }

    @Test func aQuestionMarkNeedsAQuestion() {
        #expect(trusts("so you ready for the demo tomorrow", "So, you ready for the demo tomorrow?"))
        #expect(trusts("are you ready for the demo tomorrow", "Are you ready for the demo tomorrow?"))
        #expect(!trusts("we are ready for the demo tomorrow", "We are ready for the demo tomorrow?"))
        #expect(!trusts("so we are ready for the demo tomorrow", "So, we are ready for the demo tomorrow!"))
        #expect(trusts("what a great demo", "What a great demo!"))
    }

    // MARK: - Real corrections

    @Test func acceptsASpokenReplacementOfOneWordOrTwo() {
        #expect(trusts("I want a large no wait a medium coffee", "I want a medium coffee."))
        #expect(trusts("I will email him no wait call him this afternoon", "I will call him this afternoon."))
        #expect(trusts("the car is red no blue", "The car is blue."))
        #expect(trusts("please bring the laptop sorry the tablet to the meeting", "Please bring the tablet to the meeting."))
        #expect(trusts("we will ship on the second or rather the third", "We will ship on the third."))
    }

    @Test func acceptsARestartedClause() {
        #expect(trusts("Send it to Maria, no wait, uh send it to Marcus.", "Send it to Marcus."))
        #expect(trusts("The deadline is Friday I mean Monday because of the holiday.", "The deadline is Monday because of the holiday."))
        #expect(trusts("Let's meet at three, actually make that four o'clock.", "Let's meet at 4 o'clock."))
    }

    @Test func aRetractionCueAtTheVeryStartOnlyDropsTheCue() {
        #expect(trusts("Scratch that, let's go with the second option instead.", "Let's go with the second option instead."))
        #expect(trusts("strike that let's go with the second option instead", "Let's go with the second option instead."))
        #expect(!trusts("Scratch that, let's go with the second option instead.", "Let's go with the first option instead."))
        #expect(!trusts("Scratch that, let's go with the second option instead.", "Go with the second option instead."))
    }

    @Test func aCorrectionBecomesNoMoreThanItsReplacement() {
        // What was retracted may go, but not what the speaker kept saying after it.
        #expect(!trusts("meet at three actually make that four and then bring the handouts", "Meet at four and bring the handouts."))
        #expect(!trusts("I want a large no wait a medium coffee", "I want a coffee."))
        #expect(!trusts("the car is red no blue", "The car is."))
    }

    // MARK: - Failure reasons

    @Test func namesWhatWentWrong() {
        #expect(failure("what is the capital of france", "Paris.") == .wordChanged)
        #expect(failure("book the room for friday", "Book the room for friday. Done.") == .wordAdded)
        #expect(failure("please send the weekly report to the team", "Please send the report to the team.") == .contentDropped)
        #expect(failure("we can not ship this week", "We can ship this week.") == .negationChanged)
        #expect(failure("ship it on friday", "Ship it on Friday! \u{1F680}") == .formatChanged)
        #expect(failure("ask Dana to call Boston", "Ask dana to call boston.") == .caseChanged)
        #expect(failure("the waiting period ends on friday", "The waiting ends on Friday.") == .contentDropped)
    }
}
