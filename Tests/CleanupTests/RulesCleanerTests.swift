import Testing
@testable import Cleanup

@Suite struct RulesCleanerTests {
    let rules = RulesCleaner()

    private func clean(_ text: String) -> String { rules.cleaned(text) }

    // MARK: - Fillers

    @Test func removesFillerWords() {
        #expect(clean("um I think we should uh go") == "I think we should go.")
        #expect(clean("so ummm that works hmm for me") == "So that works for me.")
    }

    @Test func removesFillersAndTheirCommas() {
        #expect(clean("Um, I think we should, uh, go to the store.") == "I think we should go to the store.")
        #expect(clean("It works, um.") == "It works.")
        #expect(clean("We left early, uh") == "We left early")
    }

    @Test func keepsTheCommaAfterAnIntroWord() {
        #expect(clean("So, um, it works.") == "So, it works.")
        #expect(clean("Well, uh, maybe.") == "Well, maybe.")
    }

    @Test func removesYouKnowOnlyWhenItIsAFiller() {
        #expect(clean("It was, you know, a long day.") == "It was a long day.")
        #expect(clean("You know, I think so.") == "I think so.")
        #expect(clean("That is all, you know.") == "That is all.")
        #expect(clean("Do you know the way to the station?") == "Do you know the way to the station?")
        #expect(clean("As you know, the meeting moved.") == "As you know, the meeting moved.")
        #expect(clean("I think you know what I mean.") == "I think you know what I mean.")
    }

    @Test func removesCommaBoundedLike() {
        #expect(clean("It was, like, really hot.") == "It was really hot.")
        #expect(clean("I like pizza, like a lot.") == "I like pizza, like a lot.")
    }

    @Test func leavesAllCapsAbbreviationsAlone() {
        #expect(clean("She works in the ER at night.") == "She works in the ER at night.")
    }

    @Test func fillerOnlyInputBecomesEmpty() {
        #expect(clean("um uh") == "")
        #expect(clean("   ") == "")
        #expect(clean("") == "")
    }

    // MARK: - Stutters and repeats

    @Test func collapsesRepeatedWords() {
        #expect(clean("i i think the the plan is is solid") == "I think the plan is solid.")
        #expect(clean("we need to we need to leave") == "We need to leave.")
        #expect(clean("It is the the best option.") == "It is the best option.")
    }

    @Test func collapsesRepeatsAcrossACommaForFunctionWords() {
        #expect(clean("I, I think so.") == "I think so.")
    }

    @Test func keepsLegitimateRepeats() {
        #expect(clean("He had had enough.") == "He had had enough.")
        #expect(clean("I know that that is true.") == "I know that that is true.")
        #expect(clean("No, no, no, that is wrong.") == "No, no, no, that is wrong.")
        #expect(clean("They said bye bye and left.") == "They said bye bye and left.")
        #expect(clean("Room 101 101 is on the left.") == "Room 101 101 is on the left.")
    }

    @Test func removesWordFragments() {
        #expect(clean("th- the plan is ready") == "The plan is ready.")
        #expect(clean("w-w-we should go") == "We should go.")
        #expect(clean("Pre- and post-processing both run.") == "Pre- and post-processing both run.")
    }

    // MARK: - Spoken commands

    @Test func turnsSpokenPunctuationIntoPunctuation() {
        #expect(clean("hello comma how are you question mark") == "Hello, how are you?")
        #expect(clean("see you tomorrow period") == "See you tomorrow.")
        #expect(clean("that was great exclamation point") == "That was great!")
        #expect(clean("we are done full stop") == "We are done.")
    }

    @Test func leavesPunctuationWordsAloneWhenTheyAreMentionedNotCommanded() {
        #expect(clean("Put a period at the end.") == "Put a period at the end.")
        #expect(clean("The waiting period is two weeks.") == "The waiting period is two weeks.")
        #expect(clean("Remove the comma after hello.") == "Remove the comma after hello.")
        #expect(clean("Over a period of three months we grew.") == "Over a period of three months we grew.")
        #expect(clean("The question mark key is stuck.") == "The question mark key is stuck.")
        #expect(clean("It cost us over the billing period") == "It cost us over the billing period")
    }

    @Test func periodMidSentenceNeedsACapitalizedNextWord() {
        #expect(clean("The period ends Friday.") == "The period ends Friday.")
        #expect(clean("We shipped it period Then we left.") == "We shipped it. Then we left.")
    }

    @Test func turnsNewLineAndNewParagraphIntoBreaks() {
        #expect(clean("first line new line second line new paragraph third") == "First line\nSecond line\n\nThird.")
        #expect(clean("thanks period new paragraph best regards") == "Thanks.\n\nBest regards.")
    }

    @Test func leavesNewLineAloneWhenItIsANounPhrase() {
        #expect(clean("Add a new line to the file.") == "Add a new line to the file.")
        #expect(clean("The new line character is invisible.") == "The new line character is invisible.")
    }

    // MARK: - Capitalization and spacing

    @Test func capitalizesSentencesAndTheWordI() {
        #expect(clean("it works. we shipped it! did it break? no.") == "It works. We shipped it! Did it break? No.")
        #expect(clean("i think i'm right and i'll prove it") == "I think I'm right and I'll prove it.")
    }

    @Test func doesNotCapitalizeAfterAbbreviations() {
        #expect(clean("See e.g. the docs for details.") == "See e.g. the docs for details.")
        #expect(clean("Ask Dr. patel about it.") == "Ask Dr. patel about it.")
    }

    @Test func leavesIdentifiersAtSentenceStartAlone() {
        #expect(clean("useAuthSession returns the session. iPhone sales rose.") == "useAuthSession returns the session. iPhone sales rose.")
        #expect(clean("v2 is out. main.swift compiles.") == "v2 is out. main.swift compiles.")
    }

    @Test func fixesSpacingAroundPunctuation() {
        #expect(clean("hello , world .") == "Hello, world.")
        #expect(clean("Too    many   spaces here.") == "Too many spaces here.")
    }

    @Test func closesUncasedQuestionsWithAQuestionMark() {
        #expect(clean("what is the capital of france") == "What is the capital of france?")
        #expect(clean("can you send me the file") == "Can you send me the file?")
        #expect(clean("how to fix the build") == "How to fix the build.")
        #expect(clean("what a great day") == "What a great day.")
        #expect(clean("the report is due at 5") == "The report is due at 5.")
    }

    @Test func closesUncasedTextWithAPeriodButNotCasedText() {
        #expect(clean("send it to the team") == "Send it to the team.")
        #expect(clean("Meeting notes for Friday") == "Meeting notes for Friday")
    }

    // MARK: - Dictionary

    @Test func appliesTheCallersDictionary() {
        let custom = RulesCleaner(dictionary: ["cube control": "kubectl", "flow kit": "FlowKit", "github": "GitHub"])
        #expect(custom.cleaned("run cube control get pods in flow kit") == "Run kubectl get pods in FlowKit.")
        #expect(custom.cleaned("Push it to github, then rebuild.") == "Push it to GitHub, then rebuild.")
    }

    @Test func dictionaryTermsKeepTheirSpellingAtSentenceStart() {
        let custom = RulesCleaner(dictionary: ["cube control": "kubectl"])
        #expect(custom.cleaned("cube control get pods works. kubectl is installed.") == "kubectl get pods works. kubectl is installed.")
    }

    @Test func prefersTheLongestDictionaryPhrase() {
        let custom = RulesCleaner(dictionary: ["flow kit": "FlowKit", "flow kit pro": "FlowKit Pro"])
        #expect(custom.cleaned("We use flow kit pro daily.") == "We use FlowKit Pro daily.")
    }

    @Test func withoutADictionaryNothingIsReplaced() {
        #expect(clean("Run cube control get pods.") == "Run cube control get pods.")
    }

    // MARK: - Never alter clean text

    @Test func leavesAlreadyCleanTextUnchanged() {
        let samples = [
            "The useAuthSession hook returns the current session.",
            "Run kubectl get pods in the staging namespace.",
            "We use FluidAudio for speech recognition.",
            "Email me at dana@example.com or visit https://example.com/docs.",
            "Version 2.1.3 ships on March 5th at 3:30 PM.",
            "He said, \"We will leave at noon.\"",
            "Can you send me the report?",
            "Write me an email to Bob about the delay.",
            "What is the capital of France?",
            "First, open the file. Second, run the build.\n\nThird, check the logs.",
            "Thanks!",
            "It costs $4.50 (plus tax), which is fair.",
            "The array is [1, 2, 3] and the map is {a: 1}.",
        ]
        for sample in samples {
            #expect(clean(sample) == sample, "changed: \(sample)")
        }
    }

    @Test func isIdempotent() {
        let samples = [
            "um so i i think we should uh go comma if you know it works period new paragraph thanks",
            "th- the plan, you know, is is ready question mark",
            "Hello comma world period",
        ]
        for sample in samples {
            let once = clean(sample)
            #expect(clean(once) == once, "not stable: \(sample)")
        }
    }

    @Test func asyncInterfaceMatchesTheSyncOne() async throws {
        try await rules.prepare()
        let result = try await rules.clean("um hello there my friend")
        #expect(result == "Hello there my friend.")
        #expect(rules.name == "rules")
    }
}
