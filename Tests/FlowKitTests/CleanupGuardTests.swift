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
