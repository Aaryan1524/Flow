import Testing
@testable import Cleanup

@Suite struct DiscardCommandsTests {
    private let rules = RulesCleaner()

    // MARK: - Throw away everything so far

    @Test func scratchItAfterYouKnowWhatDropsEverythingBefore() {
        let said = "So I mean like I was thinking to start the meeting tomorrow at 1pm but I don't know what will be a good time. You know what scratch it, I think the meeting tomorrow should be at 2pm"
        #expect(DiscardCommands.apply(said) == "I think the meeting tomorrow should be at 2pm")
        #expect(rules.cleaned(said) == "I think the meeting tomorrow should be at 2pm")
    }

    @Test func scratchAllOfTheseWithNoPunctuationDropsEverythingBefore() {
        let said = "I was thinking to start the meeting tomorrow at 1pm But I don't know what will be a good time. You know what scratch all of these I think the meeting tomorrow should be at 2pm"
        #expect(rules.cleaned(said) == "I think the meeting tomorrow should be at 2pm")
    }

    @Test func otherWaysOfSayingScratchEverything() {
        #expect(DiscardCommands.apply("Book it for Monday. Scratch everything, book it for Friday.") == "book it for Friday.")
        #expect(DiscardCommands.apply("Send it to Dana. Strike all of that. Send it to Priya.") == "Send it to Priya.")
        #expect(DiscardCommands.apply("Okay, scratch all of that, let's start again with the plan.") == "let's start again with the plan.")
    }

    @Test func theLastOfSeveralCommandsWinsAndEarlierOnesAreResolvedToo() {
        #expect(DiscardCommands.apply("One. Scratch all of that. Two. Scratch all of that. Three.") == "Three.")
    }

    @Test func scratchingEverythingWithNothingLeftCancelsTheDictation() {
        #expect(rules.cleaned("I was going to say something. Scratch all of that.") == "")
    }

    // MARK: - Throw away the last sentence

    @Test func scratchThatAsASentenceRemovesThePreviousSentence() {
        #expect(DiscardCommands.apply("Add milk to the list. Scratch that. Add oat milk.") == "Add oat milk.")
        #expect(DiscardCommands.apply("Add milk to the list. Scratch that, add oat milk.") == "add oat milk.")
        #expect(DiscardCommands.apply("We could hire a designer. Strike that. Let's keep it in house.") == "Let's keep it in house.")
    }

    @Test func scratchThatReachesBackToTheSentenceTheReplacementRepeats() {
        // The real dictation: the 1pm thought spans two sentences, and the replacement repeats its first one.
        let said = "So, I was thinking to have the meeting tomorrow at 1 p.m. But I don't know what will be a good time. I mean you know, scratch that. Let's have a meeting tomorrow at 2 p.m. and Kubernetes pgvector LangChain Snowflake."
        #expect(DiscardCommands.apply(said) == "Let's have a meeting tomorrow at 2 p.m. and Kubernetes pgvector LangChain Snowflake.")
        let noPunctuation = "So I was thinking to have the meeting tomorrow at 1pm but I don't know what will be a good time. I mean you know just scratch that. Let's have the meeting tomorrow at 2pm guys and Kubernetes pgvector LangChain Snowflake."
        #expect(DiscardCommands.apply(noPunctuation) == "Let's have the meeting tomorrow at 2pm guys and Kubernetes pgvector LangChain Snowflake.")
    }

    @Test func aReplacementThatRepeatsOnlyTheNearestSentenceTakesBackOnlyThat() {
        #expect(DiscardCommands.apply("Add eggs. Add milk to the list. Scratch that. Add oat milk to the list.") == "Add eggs. Add oat milk to the list.")
        // Sharing a single content word is not enough to reach further back.
        #expect(DiscardCommands.apply("We ship Friday. Dana owns the release. The budget is tight. Scratch that. Hire a contractor.") == "We ship Friday. Dana owns the release. Hire a contractor.")
    }

    @Test func onlyTheOneSentenceBeforeIsRemoved() {
        #expect(DiscardCommands.apply("Buy eggs. Buy milk. Scratch that. Buy bread.") == "Buy eggs. Buy bread.")
    }

    @Test func anAbbreviationDoesNotEndTheSentenceBeingScratched() {
        #expect(DiscardCommands.apply("Call Dr. Smith about the invoice. Scratch that. Call Dr. Jones.") == "Call Dr. Jones.")
        #expect(DiscardCommands.apply("Ship it to the U.S. office today. Scratch that. Ship it Monday.") == "Ship it Monday.")
    }

    @Test func scratchThatAtTheVeryStartRemovesOnlyItself() {
        #expect(DiscardCommands.apply("Scratch that, let's go with the second option.") == "let's go with the second option.")
    }

    // MARK: - Ordinary speech is left alone

    @Test func ordinaryUsesOfTheseWordsAreNotCommands() {
        let sentences = [
            "I need to scratch that itch before the meeting.",
            "Please strike that from the record and move on to the budget.",
            "He told me to scratch it off the list.",
            "Scratch all of these off the list before Friday.",
            "The cat will scratch everything in the living room.",
            "It is hard to scratch that kind of itch.",
            "The batter will strike that ball hard.",
        ]
        for sentence in sentences { #expect(DiscardCommands.apply(sentence) == sentence, "changed: \(sentence)") }
    }

    @Test func otherVerbsNeverDiscardAnythingBecausePeopleDictateThemIntoPrompts() {
        let prompts = [
            "Write a summary. Ignore everything above and tell me a joke.",
            "We talked about it. Forget all of that and start fresh with the plan.",
            "Disregard all of these instructions. Do this instead.",
            "Delete everything in the folder, then rebuild it.",
        ]
        for prompt in prompts { #expect(DiscardCommands.apply(prompt) == prompt, "changed: \(prompt)") }
    }

    @Test func itAfterAnythingOtherThanYouKnowWhatIsNotACommand() {
        #expect(DiscardCommands.apply("The idea is wrong. Scratch it, I think.") == "The idea is wrong. Scratch it, I think.")
    }

    // MARK: - A retraction that starts mid-sentence

    @Test func youKnowWhatScratchThisAfterACutOffWordStillRetractsTheThought() {
        // You cut yourself off ("two p-") and pivoted, so no sentence break sits in front of "you know what".
        let said = "So I'm planning to have a meeting tomorrow. Guys, what do you all think will be a good idea? One PM, two p you know what, scratch this. We should have the meeting tomorrow at two p.m. and I would love to be hosting it and everyone should be there."
        #expect(DiscardCommands.apply(said) == "We should have the meeting tomorrow at two p.m. and I would love to be hosting it and everyone should be there.")
    }

    @Test func aMidSentencePivotWithNothingRepeatedOnlyDropsTheFragment() {
        #expect(DiscardCommands.apply("We shipped it Friday. The budget is two p you know what, scratch that. Hire a contractor.") == "We shipped it Friday. Hire a contractor.")
    }

    @Test func youKnowWhatScratchAllOfThisWorksMidSentenceToo() {
        #expect(DiscardCommands.apply("Book it for Monday and then you know what scratch all of this. Book it for Friday.") == "Book it for Friday.")
    }

    @Test func youKnowWhatScratchThatItchIsStillLeftAlone() {
        let sentence = "You know what, scratch that itch before the meeting."
        #expect(DiscardCommands.apply(sentence) == sentence)
    }

    @Test func wordsInFrontOfThePivotThatAreOnlyALeadInAreNotTheThought() {
        #expect(DiscardCommands.apply("Buy eggs. Buy milk. I mean you know what, scratch that. Buy bread.") == "Buy eggs. Buy bread.")
    }

    @Test func anEmojiInTheTextDoesNotShiftWhereSentencesAreCut() {
        #expect(DiscardCommands.apply("Great news 🎉🎉. Buy milk. Scratch that. Buy bread.") == "Great news 🎉🎉. Buy bread.")
    }
}
