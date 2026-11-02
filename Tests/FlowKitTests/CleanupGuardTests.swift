import Testing
@testable import FlowKit

@Suite struct CleanupGuardTests {
    let guardrail = CleanupGuard.standard

    private func trusts(_ raw: String, _ cleaned: String) -> Bool {
        guardrail.isTrustworthy(raw: raw, cleaned: cleaned)
    }

    // MARK: - Legitimate cleanups must pass

    @Test func acceptsFillerAndStutterRemoval() {
        #expect(
            trusts(
                "so um I was thinking we we should uh go with the the second option",
                "So I was thinking we should go with the second option."))
    }

    @Test func acceptsPunctuationAndCapitalizationOnly() {
        #expect(trusts("please close the garage door before you leave", "Please close the garage door before you leave."))
    }

    @Test func acceptsSelfCorrectionThatDropsMostOfAShortSentence() {
        #expect(trusts("ship it friday no wait scratch that ship it monday", "Ship it Monday."))
    }

    @Test func acceptsSelfCorrectionInAMediumSentence() {
        #expect(
            trusts(
                "send the report to Maria on Friday scratch that send the report to Peter on Monday",
                "Send the report to Peter on Monday."))
    }

    @Test func acceptsFillerOnlyInputBecomingEmpty() {
        #expect(trusts("um uh", ""))
        #expect(trusts("", ""))
    }

    @Test func acceptsNumberReformatting() {
        #expect(trusts("the dentist is at three thirty p m on march fifth", "The dentist is at 3:30 PM on March 5th."))
        #expect(trusts("we shipped twenty twenty five units", "We shipped 2025 units."))
    }

    @Test func acceptsJoinedIdentifiers() {
        #expect(trusts("rename use auth session to use session in the hook", "Rename useAuthSession to useSession in the hook."))
    }

    @Test func acceptsHyphenatedAndSplitSpellingsAsTheSameWords() {
        #expect(trusts("it takes about twenty five minutes by train", "It takes about twenty-five minutes by train."))
        #expect(trusts("w-we need to to finish the slides before lunch", "We need to finish the slides before lunch."))
    }

    @Test func acceptsSpokenPunctuationBecomingSymbols() {
        #expect(trusts("dear team comma new paragraph the release is ready period", "Dear team,\n\nThe release is ready."))
        #expect(trusts("are you coming to the party question mark", "Are you coming to the party?"))
    }

    @Test func acceptsApostropheAndPluralVariants() {
        #expect(trusts("the dogs bowl is empty again today", "The dog's bowl is empty again today."))
    }

    @Test func acceptsLongCleanParagraph() {
        let raw =
            "the quarterly numbers came in higher than we expected and the team deserves credit for it "
            + "the biggest gains were in the northern region where two new stores opened early "
            + "next quarter we plan to hire three more people and finish the warehouse move"
        let cleaned =
            "The quarterly numbers came in higher than we expected, and the team deserves credit for it. "
            + "The biggest gains were in the northern region, where two new stores opened early.\n\n"
            + "Next quarter we plan to hire three more people and finish the warehouse move."
        #expect(trusts(raw, cleaned))
    }

    @Test func acceptsInputThatStartsLikeAChatReply() {
        #expect(trusts("sure that works for me", "Sure, that works for me."))
        #expect(trusts("here is the plan for the weekend", "Here is the plan for the weekend."))
    }

    // MARK: - Answers, emails, refusals and chatter must fail

    @Test func acceptsChatLikeOpenersThatFollowAFiller() {
        #expect(trusts("um sure that works for me", "Sure, that works for me."))
        #expect(trusts("uh here's the plan for the weekend", "Here's the plan for the weekend."))
        #expect(trusts("um sorry but i can't make it tonight", "Sorry, but I can't make it tonight."))
    }

    @Test func rejectsAShortAnswer() {
        let verdict = guardrail.evaluate(raw: "what is the tallest mountain in Africa", cleaned: "Kilimanjaro.")
        #expect(!verdict.isTrustworthy)
    }

    @Test func rejectsAnAnswerThatReusesTheQuestionWords() {
        #expect(!trusts("what is the tallest mountain in Africa", "The tallest mountain in Africa is Kilimanjaro."))
        #expect(!trusts("how many ounces are in a pound", "There are 16 ounces in a pound."))
    }

    @Test func rejectsAnEmailWrittenFromARequest() {
        let email = "Subject: Schedule change\n\nHi Dana,\n\nI wanted to let you know the schedule has changed. Please see the details below.\n\nBest regards"
        #expect(!trusts("write an email to Dana about the schedule change", email))
    }

    @Test func rejectsARefusal() {
        #expect(!trusts("tell me a joke about cats", "I'm sorry, but I can't help with that request."))
        #expect(!trusts("tell me a joke about cats", "I cannot do that."))
    }

    @Test func rejectsAChattyPrefaceEvenOnLongText() {
        let raw =
            "the new onboarding flow cuts the number of steps from nine to five and moves the account "
            + "verification to the end so that people can look around before they commit to anything"
        let cleaned = "Here is the cleaned transcript: " + raw
        #expect(!trusts(raw, cleaned))
        #expect(!trusts(raw, "Sure! " + raw))
    }

    @Test func rejectsAChattyClosingEvenOnLongText() {
        let raw =
            "the new onboarding flow cuts the number of steps from nine to five and moves the account "
            + "verification to the end so that people can look around before they commit to anything"
        #expect(!trusts(raw, raw + " Let me know if you would like any changes."))
    }

    @Test func rejectsATranslation() {
        #expect(!trusts("translate good morning my friend into Spanish", "Buenos días, mi amigo."))
    }

    @Test func rejectsASummaryOfAboutHalfTheLength() {
        let raw =
            "the logistics team found that the delay came from a customs hold at the port which lasted six days "
            + "and the supplier did not notify us until the shipment had already missed its slot on the truck "
            + "so we are changing the contract to require a daily status update"
        let summary = "The delay came from a customs hold at the port, so we are changing the contract to require updates."
        #expect(!trusts(raw, summary))
    }

    @Test func rejectsTheInputRepeatedTwice() {
        let raw = "please remember to water the plants on thursday"
        #expect(!trusts(raw, raw + ". " + raw))
    }

    @Test func rejectsEmptyOutputForRealInput() {
        let verdict = guardrail.evaluate(raw: "remind me to call the plumber", cleaned: "")
        #expect(verdict.failure == .emptyOutput)
    }

    @Test func reportsTheReasonAndMeasurements() {
        let verdict = guardrail.evaluate(raw: "what is the tallest mountain in Africa", cleaned: "Kilimanjaro.")
        #expect(verdict.failure == .tooShort)
        #expect(verdict.lengthRatio < 0.3)
        let preface = guardrail.evaluate(raw: "turn the lights off", cleaned: "Sure, turn the lights off.")
        #expect(preface.failure == .chattyFraming)
    }

    // MARK: - Dropped words without a correction

    @Test func rejectsTruncationWhenNothingWasCorrected() {
        // The model kept only part of the sentence: no filler, repeat or correction explains the loss.
        #expect(!trusts("the bakery on main street opens at seven and closes at noon on sundays", "The bakery on Main Street opens at seven."))
        #expect(!trusts("respond with a single word what is the capital of italy", "What is the capital of Italy?"))
        #expect(!trusts("remind me to water the plants and then feed the cat", "Remind me to water the plants."))
    }

    @Test func rejectsANumericAnswerToArithmetic() {
        #expect(!trusts("two plus two", "4"))
        #expect(!trusts("what is two hundred divided by four", "50"))
    }

    @Test func allowsBigDropsWhenTheSpeakerCorrectsThemselves() {
        #expect(trusts("meet me at the north gate no wait the south gate at noon", "Meet me at the south gate at noon."))
        #expect(trusts("we need twelve chairs I mean fourteen chairs for the room", "We need fourteen chairs for the room."))
    }

    @Test func discountsFillersRepeatsAndYouKnowWhenMeasuringLoss() {
        #expect(trusts("so you know we we need more time", "So we need more time."))
        #expect(trusts("i i think we should we should call the client back", "I think we should call the client back."))
        #expect(trusts("do you know where the station is", "Do you know where the station is?"))
    }

    @Test func numberWordsDoNotCountAsLostWhenOutputUsesDigits() {
        #expect(trusts("we sold one hundred twenty three units in march", "We sold 123 units in March."))
    }

    // MARK: - Meaning inversions

    @Test func rejectsContractionsReducedToTheirStem() {
        #expect(!trusts("we can't ship this week", "We can ship this week."))
        #expect(!trusts("they couldn't open the file", "They could open the file."))
        #expect(!trusts("she wouldn't sign the contract today", "She would sign the contract today."))
        #expect(!trusts("the build wasn't green this morning", "The build was green this morning."))
        #expect(!trusts("the tests aren't passing on the branch", "The tests are passing on the branch."))
    }

    @Test func rejectsNotBecomingNote() {
        #expect(!trusts("this is not the file we wanted", "This is note the file we wanted."))
    }

    @Test func rejectsADroppedNegationInALongerSentence() {
        #expect(!trusts("we should not deploy the release before the audit finishes", "We should deploy the release before the audit finishes."))
        #expect(!trusts("i will never agree to that deal under any terms", "I will agree to that deal under any terms."))
        #expect(!trusts("there is no way we can finish this by friday afternoon", "There is a way we can finish this by friday afternoon."))
        #expect(!trusts("nobody on the team has seen the new design so far this week", "Everybody on the team has seen the new design so far this week."))
    }

    @Test func rejectsAnAddedNegation() {
        #expect(!trusts("we can ship this week", "We can't ship this week."))
        #expect(!trusts("the server is down again today and the team is waiting for the fix to land", "The server is not down again today and the team is waiting for the fix to land."))
    }

    @Test func acceptsNegationsWrittenADifferentWay() {
        #expect(trusts("we can not ship this week", "We cannot ship this week."))
        #expect(trusts("we do not ship on fridays", "We don't ship on Fridays."))
        #expect(trusts("no no no that is not what i meant", "No, that is not what I meant."))
        #expect(trusts("it isn't ready and it won't be ready", "It isn't ready, and it won't be ready."))
    }

    @Test func aRetractedNegationInsideACorrectionMayDisappear() {
        #expect(trusts("we can't ship friday no wait we can ship friday after all", "We can ship Friday after all."))
        #expect(trusts("send it to Maria no wait send it to Marcus", "Send it to Marcus."))
    }

    @Test func sameWordMeansInflectionOnly() {
        #expect(CleanupGuard.sameWord("session", "sessions"))
        #expect(CleanupGuard.sameWord("ship", "shipped"))
        #expect(CleanupGuard.sameWord("ship", "shipping"))
        #expect(CleanupGuard.sameWord("make", "making"))
        #expect(CleanupGuard.sameWord("use", "used"))
        #expect(!CleanupGuard.sameWord("can", "cant"))
        #expect(!CleanupGuard.sameWord("could", "couldnt"))
        #expect(!CleanupGuard.sameWord("was", "wasnt"))
        #expect(!CleanupGuard.sameWord("are", "arent"))
        #expect(!CleanupGuard.sameWord("not", "note"))
        #expect(!CleanupGuard.sameWord("do", "does"))
    }

    // MARK: - Speed on long text

    /// Letters-only words that cannot be negations, fillers, numbers or inflections of each other.
    static func pseudoText(words count: Int) -> [String] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        let letters = Array("bcdfghjklmpqrtvwxz")
        let vocabulary: [String] = (0..<800).map { _ in "q" + String((0..<(4 + next() % 6)).map { _ in letters[next() % letters.count] }) }
        return (0..<count).map { _ in vocabulary[next() % vocabulary.count] }
    }

    @Test func evaluatesFiveThousandWordsWithoutQuadraticCost() {
        let words = Self.pseudoText(words: 5000)
        let raw = words.joined(separator: " ")
        let cleaned = words.enumerated().filter { $0.offset % 25 != 7 }.map(\.element).joined(separator: " ")
        let start = ContinuousClock.now
        let verdict = guardrail.evaluate(raw: raw, cleaned: cleaned)
        let elapsed = start.duration(to: .now)
        #expect(verdict.failure == nil)
        #expect(elapsed < .milliseconds(750))
    }

    // MARK: - Answers made of digits

    @Test func rejectsAnswersMadeOfDigits() {
        #expect(!trusts("how many ounces are in a pound", "How many ounces are in a pound? 16"))
        #expect(!trusts("what is fifteen percent of two hundred", "What is 15 percent of 200? 30"))
        #expect(!trusts("ship five units", "Ship 50 units."))
        #expect(!trusts("what year did the second world war end", "What year did the second world war end? 1945."))
    }

    @Test func acceptsNumbersWhoseValueMatchesWhatWasSaid() {
        #expect(trusts("we need twenty five chairs for the room", "We need 25 chairs for the room."))
        #expect(trusts("the pipe is two point five inches wide", "The pipe is 2.5 inches wide."))
        #expect(trusts("the party is on march fifth at noon", "The party is on March 5th at noon."))
        #expect(trusts("fifteen percent of the team left early", "15% of the team left early."))
        #expect(trusts("the call starts at three thirty", "The call starts at 3:30."))
        #expect(trusts("one hundred and five people came to the talk", "105 people came to the talk."))
        #expect(trusts("we launched in nineteen eighty four", "We launched in 1984."))
        #expect(trusts("the total was one thousand two hundred dollars", "The total was $1,200."))
        #expect(trusts("version two point four point one fixes the crash", "Version 2.4.1 fixes the crash."))
    }

    @Test func rejectsANumberWithADifferentValue() {
        #expect(!trusts("we need fifteen chairs for the room", "We need 51 chairs for the room."))
        #expect(!trusts("the call starts at three thirty", "The call starts at 3:45."))
        #expect(!trusts("it takes twenty five minutes by train", "It takes 5 minutes by train."))
    }

    // MARK: - Number words that are also ordinary words

    @Test func numberConversionDoesNotInflateTheLengthRatio() {
        let raw = "I went to the store and bought milk and eggs and bread and then came back at five"
        let verdict = guardrail.evaluate(raw: raw, cleaned: "I went to the store and bought milk and eggs and bread and then came back at 5.")
        #expect(verdict.isTrustworthy)
        #expect(verdict.lengthRatio <= 1.05)
    }

    @Test func connectorWordsOnlyCountAsNumbersNextToNumbers() {
        #expect(trusts("the first and second options are due at three", "The first and second options are due at 3."))
        #expect(trusts("that point came up again at four in the second meeting", "That point came up again at 4 in the second meeting."))
        #expect(trusts("oh we left at five and the second train was late", "Oh, we left at 5, and the second train was late."))
    }

    @Test func speechRecogniserSpacingInATimeStillMeetsTheTime() {
        #expect(trusts("the meeting is on march 14 at 3: 30 p.m.", "The meeting is on March 14 at 3:30 p.m."))
    }

    @Test func aPronounOneIsAWordNotANumber() {
        let raw = "what is the difference between a mutex and a semaphore and when should i use each 1"
        #expect(trusts(raw, "What is the difference between a mutex and a semaphore, and when should I use each?"))
        #expect(trusts("no one knew about the plan", "No one knew about the plan."))
        #expect(!trusts("use each 1", "Use each."))
        #expect(!trusts("we need one chair", "We need chair."))
    }

    // MARK: - Short and medium inputs

    @Test func rejectsTruncatedShortInputs() {
        #expect(!trusts("turn it off", "Turn."))
        #expect(!trusts("hello world", "Hello."))
        #expect(!trusts("please send the report", "Please send report."))
        #expect(!trusts("book the large room for friday", "Book the room for Friday."))
        #expect(!trusts("call the dentist before noon tomorrow morning", "Call the dentist before noon tomorrow."))
        #expect(!trusts("move the red folder to the shared drive", "Move the folder to the shared drive."))
    }

    @Test func shortInputsMayStillLoseFillersAndStutters() {
        #expect(trusts("um turn it off", "Turn it off."))
        #expect(trusts("hello hello world", "Hello world."))
        #expect(trusts("w-we need the report", "We need the report."))
        #expect(trusts("it was, like, really late", "It was really late."))
        #expect(trusts("uh so the the build is, you know, green", "So the build is green."))
    }

    @Test func aLikeRightAfterAFillerIsAFillerToo() {
        #expect(trusts("it takes, you know, like a couple of seconds to start up", "It takes a couple of seconds to start up."))
        #expect(!trusts("it takes like a couple of seconds to start up", "It takes a couple of seconds to start up."))
    }

    // MARK: - Correction cues

    @Test func rejectsTruncationJustifiedOnlyByAnOrdinaryCueWord() {
        #expect(!trusts("we should actually move the standup to ten and invite the design team", "Move the standup to ten."))
        #expect(
            !trusts(
                "please wait for the build to finish before merging the pull request and then tag the release for the team",
                "Please wait for the build to finish before merging."))
        #expect(!trusts("i was sorry to hear about the delay but the customer still gets a full refund this week", "The customer still gets a full refund."))
        #expect(!trusts("the correction notice went out to every subscriber on monday morning before the markets opened", "The notice went out to every subscriber Monday."))
    }

    @Test func aCueNeedsARepeatedOrReplacedPhraseNextToIt() {
        #expect(trusts("please wait for the build to finish", "Please wait for the build to finish."))
        #expect(trusts("send it to Maria no wait send it to Marcus", "Send it to Marcus."))
        #expect(trusts("book a table for six, sorry, for eight people on Saturday", "Book a table for eight people on Saturday."))
        #expect(trusts("the review is on Tuesday, no, Wednesday morning", "The review is on Wednesday morning."))
        #expect(trusts("the review is on tuesday no wednesday morning", "The review is on Wednesday morning."))
        #expect(!trusts("i have no money for the new laptop this year so please ask the finance team", "Ask the finance team."))
        #expect(trusts("let's meet at three actually make that four", "Let's meet at four."))
        #expect(trusts("the invoice is due on the 5th no wait the 15th", "The invoice is due on the 15th."))
    }

    @Test func theLowerFloorOnlyCoversTheClauseAroundTheCue() {
        let raw = "meet at three actually make that four and then bring the printed handouts for every person in the room"
        #expect(!trusts(raw, "Meet at four and bring the printed handouts."))
        #expect(trusts(raw, "Meet at four and then bring the printed handouts for every person in the room."))
    }

    // MARK: - Identifiers and formatting

    @Test func rejectsIdentifierCaseChanges() {
        #expect(!trusts("call useAuthSession from the login hook", "Call UseAuthSession from the login hook."))
        #expect(!trusts("call useAuthSession from the login hook", "Call useauthsession from the login hook."))
        #expect(!trusts("set OPENAI_API_KEY before you start the server", "Set openai_api_key before you start the server."))
        #expect(!trusts("the bucket is called S3 for now", "The bucket is called s3 for now."))
    }

    @Test func acceptsIdentifiersThatSurviveCharacterForCharacter() {
        #expect(trusts("call useAuthSession from the login hook", "Call useAuthSession from the login hook."))
        #expect(trusts("um set OPENAI_API_KEY before you start the server", "Set OPENAI_API_KEY before you start the server."))
        #expect(trusts("twenty-five people use the iPhone app", "Twenty-Five people use the iPhone app."))
    }

    @Test func rejectsListsAndMarkdownTheSpeakerDidNotDictate() {
        #expect(!trusts("buy milk eggs and bread on the way home", "- Buy milk\n- Eggs\n- Bread on the way home"))
        #expect(!trusts("buy milk eggs and bread on the way home", "1. Buy milk, eggs and bread\n2. On the way home"))
        #expect(!trusts("this is really important for the launch", "This is **really** important for the launch."))
        #expect(!trusts("run the migration before the deploy", "Run the `migration` before the deploy."))
        #expect(!trusts("the weekly report is ready for review", "# The weekly report is ready for review"))
    }

    @Test func rejectsAnAppendedEmoji() {
        #expect(!trusts("great work on the launch team", "Great work on the launch team \u{1F389}"))
        #expect(!trusts("great work on the launch team", "Great work on the launch team! \u{1F680}\u{1F680}"))
    }

    @Test func acceptsMarkersAndEmojiThatAlreadyWereInTheDictation() {
        #expect(trusts("- buy milk\n- buy eggs", "- Buy milk\n- Buy eggs"))
        #expect(trusts("great work on the launch team \u{1F389}", "Great work on the launch team \u{1F389}"))
        #expect(trusts("dear team comma new paragraph the release is ready period", "Dear team,\n\nThe release is ready."))
    }

    @Test func rejectsAQuestionMarkTheSpeakerDidNotAsk() {
        #expect(!trusts("we are done", "We are done?"))
        #expect(!trusts("the release is ready for the team", "The release is ready for the team?"))
        #expect(trusts("are you done with the report", "Are you done with the report?"))
        #expect(trusts("we are done question mark", "We are done?"))
        #expect(trusts("how many ounces are in a pound", "How many ounces are in a pound?"))
        #expect(trusts("you are coming to the party?", "You are coming to the party?"))
    }

    // MARK: - Long dictations and chunks

    @Test func anAppendedAnswerCannotHideInALongDictation() {
        let words = Self.pseudoText(words: 120)
        let raw = words.joined(separator: " ")
        let answer = "The answer is that the capital of France is Paris"
        #expect(trusts(raw, raw + "."))
        #expect(!trusts(raw, raw + ". " + answer + "."))
    }

    @Test func addedWordsAreCappedEvenWhenTheFractionWouldAllowMore() {
        let words = Self.pseudoText(words: 300)
        let raw = words.joined(separator: " ")
        #expect(!trusts(raw, raw + " plus extra words appended"))
        #expect(trusts(raw, raw + " plus extra words"))
    }

    @Test func aCorrectionCueAtTheEndOfAChunkNeedsTheNextChunkForContext() {
        let first = "send the report to Maria on Friday no wait"
        let second = "send the report to Peter on Monday"
        let cleanedFirst = "Send the report to Maria on Friday."
        #expect(!guardrail.evaluate(raw: first, cleaned: cleanedFirst).isTrustworthy)
        #expect(guardrail.evaluate(raw: first, cleaned: cleanedFirst, after: second).isTrustworthy)
        #expect(guardrail.evaluate(raw: second, cleaned: "Send the report to Peter on Monday.", before: first).isTrustworthy)
    }

    @Test func aCueAtTheStartOfAChunkNeedsThePreviousChunkForContext() {
        let first = "send the report to Maria on Friday"
        let second = "scratch that send the report to Peter on Monday"
        let cleanedSecond = "Send the report to Peter on Monday."
        #expect(!guardrail.evaluate(raw: second, cleaned: cleanedSecond).isTrustworthy)
        #expect(guardrail.evaluate(raw: second, cleaned: cleanedSecond, before: first).isTrustworthy)
    }

    @Test func contextDoesNotExcuseDroppingTheChunksOwnWords() {
        let first = "thanks for the update i will review the draft tomorrow and then send the report to Maria on Friday no wait"
        let second = "send the report to Peter on Monday"
        let kept = "Thanks for the update, I will review the draft tomorrow and then send the report to Maria on Friday."
        #expect(guardrail.evaluate(raw: first, cleaned: kept, after: second).isTrustworthy)
        #expect(!guardrail.evaluate(raw: first, cleaned: "Send the report to Maria on Friday.", after: second).isTrustworthy)
    }

    // MARK: - Failure reasons

    @Test func reportsWhyTheOutputWasRejected() {
        #expect(guardrail.evaluate(raw: "we can't ship this week", cleaned: "We can ship this week.").failure == .negationChanged)
        #expect(guardrail.evaluate(raw: "ship five units", cleaned: "Ship 50 units.").failure == .numberChanged)
        #expect(
            guardrail.evaluate(raw: "call useAuthSession from the login hook", cleaned: "Call UseAuthSession from the login hook.").failure
                == .identifierChanged)
        #expect(guardrail.evaluate(raw: "we are done", cleaned: "We are done?").failure == .formatChanged)
        #expect(guardrail.evaluate(raw: "turn it off", cleaned: "Turn.").failure == .tooShort)
        #expect(guardrail.evaluate(raw: "turn the lights off", cleaned: "Turn the lights off now.").failure == .addedContent)
    }

    // MARK: - Helpers

    @Test func minimumRatioRampsWithInputLength() {
        #expect(guardrail.minRatio(forInputWords: 6) == 0.3)
        #expect(guardrail.minRatio(forInputWords: 40) == 0.55)
        let mid = guardrail.minRatio(forInputWords: 21)
        #expect(mid > 0.3 && mid < 0.55)
    }

    @Test func joinsSplitWordsOnlyWhenTheOutputHasTheJoinedForm() {
        let joined = CleanupGuard.joinSplitWords(["see", "you", "at", "p", "m"], matching: ["see", "you", "at", "pm"])
        #expect(joined == ["see", "you", "at", "pm"])
        let untouched = CleanupGuard.joinSplitWords(["p", "m"], matching: ["p", "m"])
        #expect(untouched == ["p", "m"])
    }

    @Test func orderedMatchesCountsSubsequence() {
        #expect(CleanupGuard.orderedMatches(["a", "c"], ["a", "b", "c"]) == 2)
        #expect(CleanupGuard.orderedMatches(["c", "a"], ["a", "b", "c"]) == 1)
    }
}
