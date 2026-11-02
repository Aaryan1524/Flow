import Testing
@testable import FlowKit

/// The AI may only delete words a speaker took back. These pin down what that means, starting with the cases an
/// independent review showed the earlier, more permissive check trusting.
@Suite struct DeleteOnlyCheckTests {
    private func trusted(_ input: String, _ output: String) -> Bool {
        DeleteOnlyCheck.isTrusted(input: input, output: output)
    }

    private func expectRejected(_ pairs: [(String, String)], sourceLocation: SourceLocation = #_sourceLocation) {
        for (input, output) in pairs {
            #expect(!trusted(input, output), "should reject: \(input) -> \(output)", sourceLocation: sourceLocation)
        }
    }

    private func expectTrusted(_ pairs: [(String, String)], sourceLocation: SourceLocation = #_sourceLocation) {
        for (input, output) in pairs {
            #expect(trusted(input, output), "should trust: \(input) -> \(output)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Nothing can be added

    @Test func rejectsAnAnswerAddedOrSubstituted() {
        expectRejected([
            ("What is the capital of France", "Paris."),
            ("What is the capital of France?", "What is the capital of France? Paris."),
            ("Please send the report to the whole team before noon today.", "Okay. Please send the report to the whole team before noon today."),
            ("Please send the report to the whole team before noon today.", "Please send the report to the whole team before noon today. Done."),
            ("Send the file to Dana on Monday.", "Send the file to Dana on Tuesday."),
            ("Add it to the budget increase.", "Add it to the budget decrease."),
            ("The dog bit the man.", "The man bit the dog."),
        ])
    }

    @Test func rejectsChangedNumbersAndDigitGroups() {
        expectRejected([
            ("Call 800-555-0199 now.", "Call 800-555-0991 now."),
            ("Call 800-555-0199 now.", "Call 123-456-0199 now."),
            ("It is due 2024-03-15.", "It is due 2024-09-27."),
            ("The call starts at three thirty tomorrow.", "The call starts at 3:00 tomorrow."),
            ("I need five tickets.", "I need 5 7 tickets."),
            ("What is 7 times 8", "What is 7 times 8 56"),
        ])
    }

    @Test func rejectsLettersGluedToNumbersAndAddedSymbols() {
        expectRejected([
            ("The price is twenty five dollars.", "The price is $25k."),
            ("We have five hundred users.", "We have 500k users."),
            ("I need five tickets for tonight.", "I need 5ParisIsTheCapital tickets for tonight."),
            ("Do not send it.", "Do not send it?"),
            ("Thanks for coming.", "Thanks for coming!"),
            ("Send the report to Maria.", "Send the report to (Maria)."),
            ("Send the report to Maria.", "\"Send the report to Maria.\""),
            ("Send the report to Maria.", "Send *the* report to Maria."),
        ])
    }

    @Test func rejectsRewordingJoiningSplittingAndNumberConversion() {
        expectRejected([
            ("It is a part of the plan.", "It is apart of the plan."),
            ("No one called.", "Noone called."),
            ("re-read the contract", "read the contract"),
            ("Let's meet at three, actually make that four o'clock.", "Let's meet at 4 o'clock."),
            ("We raised ten million dollars.", "We raised $10 million."),
            ("I'll be there.", "Ill be there."),
        ])
    }

    @Test func rejectsCaseChangesExceptTheFirstLetterOfASentence() {
        expectRejected([
            ("Please send the weekly report.", "PLEASE SEND THE WEEKLY REPORT."),
            ("Call Maria now.", "Call MARIA now."),
            ("Ask Dana to call Boston.", "Ask dana to call boston."),
            ("Use useAuthSession here.", "Use UseAuthSession here."),
        ])
    }

    @Test func rejectsLineBreaksTheSpeakerDidNotDictate() {
        expectRejected([("Send the report to Maria.", "Send\nthe\nreport\nto\nMaria.")])
    }

    // MARK: - Only retracted words may go

    @Test func rejectsAMissingNegatorEvenNextToACueWord() {
        expectRejected([
            ("The scan showed no tumor.", "The scan showed tumor."),
            ("We found no evidence of fraud in the report.", "We found evidence of fraud in the report."),
            ("Payment is due. No refunds are allowed after Friday.", "Payment is due. Refunds are allowed after Friday."),
            ("We cannot actually ship this on Friday.", "We ship this on Friday."),
            ("I never actually said that to him.", "I said that to him."),
            ("Nobody actually knows the answer.", "Knows the answer."),
        ])
    }

    @Test func anOrdinaryCueWordDoesNotExcuseDeletingItsNeighbours() {
        expectRejected([
            ("The build actually passes now.", "The passes now."),
            ("Our customers actually prefer the old design.", "Our prefer the old design."),
            ("Please wait until Tuesday for the results.", "Until Tuesday for the results."),
            ("Chefs make that sauce every day.", "Sauce every day."),
            ("I need to scratch that itch before the meeting.", "Itch before the meeting."),
            ("The batter will strike that ball hard.", "Ball hard."),
            ("He said never mind and walked out of the room.", "And walked out of the room."),
            ("Never mind the cost of the project.", "The cost of the project."),
            ("Make that sauce for dinner tonight.", "Sauce for dinner tonight."),
            ("Sorry, I am late for the meeting.", "I am late for the meeting."),
        ])
    }

    @Test func aRetractionStaysInsideOneSentence() {
        expectRejected([
            ("Bob paid the invoice in full on Friday. Actually Alice paid the deposit in cash on Monday.", "Alice paid the deposit in cash on Monday."),
            ("Please send the invoice to Dana by Friday. Then book the room. Also call the plumber.", "Please send the invoice to Dana by Friday. Also call the plumber."),
            ("We should ship the fix on Friday and tell the customers about it.", "We should ship the fix on Friday and tell the customers."),
        ])
    }

    @Test func repeatedWordsAreNotStuttersForTheAIToRemove() {
        // The rules already collapse real stutters; "bye bye" and "very very" are not the AI's to touch.
        expectRejected([
            ("It was not not good.", "It was not good."),
            ("She had had enough of it.", "She had enough of it."),
            ("Bye bye.", "Bye."),
            ("If you know, you know.", "If you know."),
            ("Yes. Yes.", "Yes."),
            ("Please call me. Please call me.", "Please call me."),
            ("Call me at 5 5.", "Call me at 5."),
        ])
    }

    @Test func rejectsAnOutputTooBigToCheck() {
        let long = Array(repeating: "word", count: DeleteOnlyCheck.maxWords + 1).joined(separator: " ")
        #expect(DeleteOnlyCheck.evaluate(input: long, output: long) == .tooLong)
    }

    // MARK: - What it should still trust

    @Test func trustsAnUnchangedOrOnlyRecasedOrRepunctuatedText() {
        expectTrusted([
            ("Please send the report to the team today.", "Please send the report to the team today."),
            ("please send the report to the team today", "Please send the report to the team today"),
            ("Call 800-555-0199 now.", "Call 800-555-0199 now."),
            ("Use useAuthSession and API_BASE_URL at https://example.com/a?b=1.", "Use useAuthSession and API_BASE_URL at https://example.com/a?b=1."),
            ("Dear team,\n\nThe release is ready.", "Dear team,\n\nThe release is ready."),
        ])
    }

    @Test func trustsFillerOnlyDeletions() {
        expectTrusted([
            ("So um I think we should uh go.", "So I think we should go."),
            ("Um, can you send me the file?", "Can you send me the file?"),
        ])
    }

    @Test func trustsRealSelfCorrections() {
        expectTrusted([
            ("Send it to Maria, no wait, uh send it to Marcus.", "Send it to Marcus."),
            ("Send the invoice to Dana, no wait, send it to Priya.", "Send the invoice to Priya."),
            ("Send it to Maria no wait send it to Marcus.", "Send it to Marcus."),
            ("Let's meet at three, actually make that four o'clock.", "Let's meet at four o'clock."),
            ("Scratch that, let's go with the second option instead.", "Let's go with the second option instead."),
            ("Um, scratch that. Unfortunately the client cancelled.", "Unfortunately the client cancelled."),
            ("Add milk to the list. Scratch that. Add oat milk.", "Add oat milk."),
            ("The report is due Tuesday, actually Wednesday.", "The report is due Wednesday."),
            ("The meeting is at 3, actually 4.", "The meeting is at 4."),
            ("Her name is Jon, sorry, John.", "Her name is John."),
            ("It's in room 204, correction, room 240.", "It's in room 240."),
            ("Tell him I'll be late, no, tell him I can't come.", "Tell him I can't come."),
        ])
    }

    @Test func wordsRestatedAfterACueMayGoButNegatorsAndNumbersMayNot() {
        expectRejected([
            ("Send it to Dana, no wait, do not send it to Priya.", "Send it to Priya."),
            ("Pay Dana on Monday, no wait, pay her 5 on Friday.", "Pay Dana on Friday."),
            ("Send the invoice to Dana, no wait, send the budget and the plan to Priya.", "Send the invoice to Priya."),
        ])
    }

    @Test func aScratchThatSentenceTakesBackOnlyTheOneSentenceBeforeIt() {
        // Two sentences before the cue: only the nearest one is the speaker's draft.
        expectRejected([("Add eggs to the list. Add milk to the list. Scratch that. Add oat milk.", "Add oat milk.")])
    }

    @Test func anExplicitCueMayReplaceOneNameOrNumberWithoutCommas() {
        expectTrusted([
            ("The deadline is Friday I mean Monday because of the holiday.", "The deadline is Monday because of the holiday."),
            ("Call me at 3 I mean 4 tomorrow.", "Call me at 4 tomorrow."),
        ])
        // A single lowercase word is not the shape of a swapped value.
        expectRejected([("We should go home I mean now.", "We should go now.")])
    }

    @Test func aBareNoNeedsCommasOnBothSides() {
        expectTrusted([("Tell him I'll be late, no, tell him I can't come.", "Tell him I can't come.")])
        expectRejected([("The scan showed no tumor.", "The scan showed tumor.")])
    }

    @Test func aSoftCueSwapsOnlyOneWordForOneOfTheSameKind() {
        // A name for a name and a number for a number, but not an arbitrary word.
        expectRejected([
            ("We should, actually, go home.", "We go home."),
            ("I was late, sorry, I overslept.", "I was I overslept."),
        ])
    }

    @Test func caseOnlyChangeIsToldApartFromAddedWords() {
        #expect(DeleteOnlyCheck.evaluate(input: "Call Maria now.", output: "Call MARIA now.") == .caseChanged)
        #expect(DeleteOnlyCheck.evaluate(input: "Call Maria now.", output: "Call Marcus now.") == .notOnlyDeletions)
    }

    @Test func staysFastOnLongText() {
        let text = (0..<1_900).map { "word\($0)" }.joined(separator: " ")
        let start = ContinuousClock.now
        _ = DeleteOnlyCheck.evaluate(input: text, output: text)
        let adversarial = Array(repeating: "no", count: 1_900).joined(separator: " ")
        _ = DeleteOnlyCheck.evaluate(input: adversarial, output: "no")
        #expect(start.duration(to: .now) < .seconds(1))
    }
}
