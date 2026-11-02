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

    @Test func keepsMillimetresAfterANumber() {
        #expect(clean("The bolt is 10 mm wide.") == "The bolt is 10 mm wide.")
        #expect(clean("mm okay that works") == "Okay that works.")
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

    @Test func doesNotCapitalizeAfterAnEllipsis() {
        #expect(clean("Well... maybe it works.") == "Well... maybe it works.")
        #expect(clean("Well\u{2026} maybe it works.") == "Well\u{2026} maybe it works.")
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
            "- buy milk\n- call the plumber\n- send the invoice",
            "1. Open the file.\n2. Run the build.\n3. Check the logs.",
            "Well... maybe. I'm not sure (see the notes below).",
            "NASA launched the probe from Cape Canaveral on Tuesday.",
            "Call fetchUser() and then read user.name from the result.",
            "Do you know what time it is? I do not.",
            "She replied, \"I know, you know.\" Then she left.",
            "Use the -v flag, or set LOG_LEVEL=debug in .env.",
            "That's all, folks!",
            "I think that that's right, but I'd double-check it.",
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

// MARK: - Whitespace contract

extension RulesCleanerTests {
    @Test func keepsIndentationTabsAndBlankLines() {
        let samples = [
            "Steps:\n    First, open the file.\n    Second, run the build.",
            "Notes\n\n\n\nBody after three blank lines.",
            "Item one.\n\n  - nested item\n  - another item\n\nDone.",
            "Name:\tDana\nRole:\tEditor",
            "Column A\tColumn B\tColumn C",
            "  Indented first line.",
        ]
        for sample in samples {
            #expect(clean(sample) == sample, "changed: \(sample.debugDescription)")
        }
    }

    @Test func normalisesLineEndingsAndSpaceRunsOnly() {
        #expect(clean("Line one.\r\nLine two.") == "Line one.\nLine two.")
        #expect(clean("Too    many   spaces here.") == "Too many spaces here.")
        #expect(clean("Ends with spaces.   \nNext line.") == "Ends with spaces.\nNext line.")
        #expect(clean("Hello there.\n\n") == "Hello there.")
    }

    @Test func returnsTextWithoutWordsUnchanged() {
        #expect(clean("...") == "...")
        #expect(clean("?") == "?")
        #expect(clean("!!") == "!!")
        #expect(clean("\u{2026}") == "\u{2026}")
        #expect(clean("  ...  ") == "...")
    }
}

// MARK: - Punctuation words used as ordinary nouns

extension RulesCleanerTests {
    @Test func keepsPeriodAsAWordWhenItEndsASentence() {
        let samples = [
            "It was a long period. Then it ended.",
            "Sales dipped during the holiday period.",
            "Put it after the second comma.",
            "The trial period ended on Friday.",
            "Expect delays over the next period.",
            "He asked what the period was for.",
        ]
        for sample in samples {
            #expect(clean(sample) == sample, "changed: \(sample)")
        }
    }

    @Test func keepsNewlineAndCommaAsWordsAfterEditingVerbsAndPrepositions() {
        #expect(clean("strip newline from the string") == "Strip newline from the string.")
        #expect(clean("split the string on comma") == "Split the string on comma.")
        #expect(clean("replace each newline with a space") == "Replace each newline with a space.")
        #expect(clean("remove newline characters") == "Remove newline characters.")
        #expect(clean("swap period for comma") == "Swap period for comma.")
        #expect(clean("save it as comma separated values") == "Save it as comma separated values.")
    }

    @Test func aPunctuationWordWithItsOwnPunctuationIsNotACommand() {
        #expect(clean("We talked about the placement of comma, and period.") == "We talked about the placement of comma, and period.")
        #expect(clean("Is that a question mark? It is not.") == "Is that a question mark? It is not.")
        #expect(clean("She ended it with an exclamation point.") == "She ended it with an exclamation point.")
        #expect(clean("The car came to a full stop.") == "The car came to a full stop.")
    }

    @Test func keepsPunctuationWordsThatAreTheObjectOfAnEarlierVerb() {
        let samples = [
            "Add one more comma before the quote.",
            "Please remove the extra comma and the stray period.",
            "Print newline after each item.",
            "We expect newline at the end of the file.",
            "The parser treats newline as whitespace.",
            "Collapse every newline into a single space.",
            "Write period at the end of each sentence.",
        ]
        for sample in samples {
            #expect(clean(sample) == sample, "changed: \(sample)")
        }
        #expect(clean("add one more comma before the quote") == "Add one more comma before the quote.")
    }

    @Test func inPunctuatedTextPeriodNeedsACapitalizedWordAfterIt() {
        #expect(clean("During the Victorian period Queen Victoria reigned.") == "During the Victorian period Queen Victoria reigned.")
        #expect(clean("Remember the holiday period") == "Remember the holiday period")
        #expect(clean("We shipped it period Then we left.") == "We shipped it. Then we left.")
    }
}

// MARK: - Commands next to words that only sometimes take a noun

extension RulesCleanerTests {
    @Test func convertsACommandAfterVerbsAndNumbersThatDoNotTakeIt() {
        #expect(clean("that is exactly what I need period") == "That is exactly what I need.")
        #expect(clean("we want period Talk soon") == "We want. Talk soon.")
        #expect(clean("that is the tool we use period") == "That is the tool we use.")
        #expect(clean("add item one comma item two") == "Add item one, item two.")
        #expect(clean("step one comma open the file") == "Step one, open the file.")
        #expect(clean("my favorite color is red comma blue or green") == "My favorite color is red, blue or green.")
        #expect(clean("take the last one period Thanks") == "Take the last one. Thanks.")
    }

    @Test func stillLeavesThemAloneWhenTheNounPhraseContinues() {
        #expect(clean("use period as the delimiter") == "Use period as the delimiter.")
        #expect(clean("use one comma here") == "Use one comma here.")
        #expect(clean("put one comma after the name") == "Put one comma after the name.")
        #expect(clean("start new line when you reach the margin") == "Start new line when you reach the margin.")
        #expect(clean("we need new line items for the invoice") == "We need new line items for the invoice.")
        #expect(clean("Put it after the first comma and before the last one.") == "Put it after the first comma and before the last one.")
    }

    @Test func convertsASecondNewLineRightAfterTheFirst() {
        #expect(clean("first line new line new line second line") == "First line\n\nSecond line.")
        #expect(clean("hello there new paragraph new paragraph bye") == "Hello there\n\nBye.")
        #expect(clean("hello there\nnew line world") == "Hello there\n\nWorld.")
    }
}

// MARK: - Repeated names and phrases

extension RulesCleanerTests {
    @Test func keepsRepeatedProperNouns() {
        #expect(clean("New York New York is a great song") == "New York New York is a great song")
        #expect(clean("we went to Bora Bora") == "We went to Bora Bora.")
        #expect(clean("Mahi Mahi tastes best grilled.") == "Mahi Mahi tastes best grilled.")
        #expect(clean("They sing Hakuna Matata Hakuna Matata every night.") == "They sing Hakuna Matata Hakuna Matata every night.")
    }

    @Test func keepsDeliberateTriples() {
        #expect(clean("ho ho ho merry christmas") == "Ho ho ho merry christmas.")
        #expect(clean("na na na na goodbye") == "Na na na na goodbye.")
        #expect(clean("go team go team go team") == "Go team go team go team.")
    }

    @Test func keepsRepeatedPhrasesWithoutAStutterSignal() {
        #expect(clean("good morning good morning everyone") == "Good morning good morning everyone.")
        #expect(clean("thank you thank you so much") == "Thank you thank you so much.")
    }

    @Test func stillCollapsesRealStutters() {
        #expect(clean("i i think we should we should call") == "I think we should call.")
        #expect(clean("the the the server is down again") == "The server is down again.")
        #expect(clean("I I think so.") == "I think so.")
        #expect(clean("we need to we need to leave") == "We need to leave.")
        #expect(clean("send it to the to the team") == "Send it to the team.")
        #expect(clean("it is it is ready") == "It is ready.")
    }
}

// MARK: - Closing punctuation and the word I

extension RulesCleanerTests {
    @Test func doesNotTurnUncasedStatementsIntoQuestions() {
        #expect(clean("when you get a chance send me the file") == "When you get a chance send me the file.")
        #expect(clean("would love to help with that") == "Would love to help with that.")
        #expect(clean("which is why we left early") == "Which is why we left early.")
        #expect(clean("should be done by friday") == "Should be done by friday.")
        #expect(clean("how I fixed it was simple") == "How I fixed it was simple.")
        #expect(clean("who I hire is my business") == "Who I hire is my business.")
        #expect(clean("do this before lunch") == "Do this before lunch.")
        #expect(clean("have it done by friday") == "Have it done by friday.")
    }

    @Test func closesPlainUncasedQuestionsWithAQuestionMark() {
        #expect(clean("would you mind sending it") == "Would you mind sending it?")
        #expect(clean("is the server down") == "Is the server down?")
        #expect(clean("where are you") == "Where are you?")
        #expect(clean("how do I fix this") == "How do I fix this?")
        #expect(clean("what time is it") == "What time is it?")
        #expect(clean("how many ounces are in a pound") == "How many ounces are in a pound?")
        #expect(clean("who's coming to lunch") == "Who's coming to lunch?")
        #expect(clean("do you know where it is") == "Do you know where it is?")
        #expect(clean("have you seen the report") == "Have you seen the report?")
        #expect(clean("it works. can you send me the file") == "It works. Can you send me the file?")
    }

    @Test func onlyAsksWhenTheWholeTextIsOneClause() {
        #expect(clean("what is the capital of france and why does it matter now") == "What is the capital of france and why does it matter now?")
        #expect(clean("is it ready, i need it today") == "Is it ready, I need it today.")
        #expect(clean("first check the logs, is the server down") == "First check the logs, is the server down.")
    }

    @Test func doesNotCloseCommandsWithAPeriod() {
        #expect(!clean("git rebase main branch").hasSuffix("."))
        #expect(!clean("docker compose up -d").hasSuffix("."))
        #expect(!clean("run the build with --release flag").hasSuffix("."))
        #expect(clean("npm install left pad").hasSuffix(".") == false)
    }

    @Test func onlyCapitalizesIWhenItIsThePronoun() {
        #expect(clean("use i as the index") == "Use i as the index.")
        #expect(clean("set i to zero") == "Set i to zero.")
        #expect(clean("the value of i was three") == "The value of i was three.")
        #expect(clean("loop while i is less than ten") == "Loop while i is less than ten.")
        #expect(clean("i think i should go") == "I think I should go.")
        #expect(clean("so do i") == "So do I.")
        #expect(clean("can i have a minute") == "Can I have a minute?")
        #expect(clean("maybe i wanted more time") == "Maybe I wanted more time.")
        #expect(clean("i'm sure i'll finish and i've checked") == "I'm sure I'll finish and I've checked.")
    }

    @Test func capitalizesIBeforeAnyVerbAtTheStartOfAClause() {
        #expect(clean("we talked and i ate lunch") == "We talked and I ate lunch.")
        #expect(clean("when i misplace my keys") == "When I misplace my keys.")
        #expect(clean("sorry, i met him yesterday") == "Sorry, I met him yesterday.")
        #expect(clean("print i then print j") == "Print i then print j.")
        #expect(clean("pass i to the function") == "Pass i to the function.")
        #expect(clean("the loop runs while i is less than ten") == "The loop runs while i is less than ten.")
    }
}

// MARK: - Hyphen stutters and command names

extension RulesCleanerTests {
    @Test func removesAHyphenatedFirstLetterStutter() {
        #expect(clean("w-we need to to finish the slides before lunch") == "We need to finish the slides before lunch.")
        #expect(clean("I think t-they already left.") == "I think they already left.")
        #expect(clean("W-we should go.") == "We should go.")
    }

    @Test func keepsRealHyphenatedWords() {
        let samples = [
            "The t-test showed a difference.",
            "Check the D-Day schedule.",
            "Please write an e-mail to the team.",
            "We re-read and re-recorded the clips.",
            "She wore a T-shirt and an X-ray badge.",
            "The C-corp filed on time.",
        ]
        for sample in samples {
            #expect(clean(sample) == sample, "changed: \(sample)")
        }
    }

    @Test func leavesCommandNamesLowercaseAtTheStartOfASentence() {
        #expect(clean("kubectl get pods") == "kubectl get pods")
        #expect(clean("git rebase main branch") == "git rebase main branch")
        #expect(clean("docker compose up. then check the logs") == "docker compose up. Then check the logs.")
        #expect(clean("run it. git status shows the changes") == "Run it. git status shows the changes")
        #expect(clean("npm install left pad and restart") == "npm install left pad and restart")
    }

    @Test func stillCapitalizesCommandNamesUsedAsWords() {
        #expect(clean("git is a version control system") == "Git is a version control system.")
        #expect(clean("swift is fast") == "Swift is fast.")
        #expect(clean("brew is installed") == "Brew is installed.")
    }
}

// MARK: - Already-clean text, including words that double as commands

extension RulesCleanerTests {
    private static let cleanSentences = [
        // Punctuation and layout words used as ordinary nouns and verbs.
        "The period of the lease ends in June.",
        "This period was marked by rapid growth.",
        "A comma splice joins two sentences incorrectly.",
        "The comma after the greeting is optional.",
        "Take the second line and move it down.",
        "The line at the bakery was long today.",
        "We drew a straight line between the two points.",
        "Add a new line at the end of the file.",
        "The new line of products launches in spring.",
        "We opened a new account last week.",
        "A new paragraph begins after the heading.",
        "That is the point of the exercise.",
        "The point is that we shipped on time.",
        "Please stop by my desk this afternoon.",
        "The bus stop is two blocks away.",
        "We came to a full stop at the light.",
        "Mark the box that applies to you.",
        "Mark will join us for lunch on Friday.",
        "She asked a question about the invoice.",
        "Is that a question mark or a comma?",
        "The exclamation point at the end made it sound angry.",
        "Use a period to end the sentence.",
        "The question mark goes at the end of a question.",
        "Put a comma after each item in the list.",
        "Press Enter for a new line.",
        "Line 42 of the file has a typo.",
        "It was a long period. Then it ended.",
        "Sales dipped during the holiday period.",
        "Put it after the second comma.",
        "Over the next period we will hire three people.",
        // Repeated proper nouns and deliberate repeats.
        "New York New York is a great song.",
        "We went to Bora Bora last summer.",
        "Mahi Mahi is on the menu tonight.",
        "Walla Walla is a city in Washington.",
        "Hawaii and Bora Bora are both beautiful.",
        "Hey hey hey, that's my seat!",
        "He said, \"Wait, wait, wait.\" Then he left.",
        "It was very, very cold.",
        "Yes, yes, of course.",
        "They said bye bye and left.",
        "I think that that is correct.",
        // Code, paths, flags and identifiers.
        "Run kubectl get pods -n staging to list them.",
        "Set LOG_LEVEL=debug before you start the server.",
        "See src/main.swift for the entry point.",
        "Call fetchUser(id) and check the result.",
        "The file config.json lives in ~/.config/flow.",
        "Use the --verbose flag for more output.",
        "The loop variable i runs from 0 to 9.",
        "Version 1.2.3 was released on 2024-05-01.",
        "Email me at dana@example.com or call 555-0100.",
        // Questions, openers and short forms.
        "Can you send me the file?",
        "Would you like some tea?",
        "When is the meeting?",
        "How many ounces are in a pound?",
        "Which is why we left early.",
        "Would love to help with that.",
        "Should be fine by tomorrow.",
        "Thanks, that works for me.",
        "Hello, world.",
        "Step one: open the file. Step two: run the build.",
        "Item one, item two, and item three.",
        "I'm sure it's fine, but let's check.",
        "Mr. Patel will arrive at 3 p.m. today.",
        "The U.S. economy grew last year.",
        "Don't stop believing.",
        "What a great day!",
        "Anyway, back to the point.",
        "First, we wash. Second, we rinse.",
        "The city of Winston-Salem is in North Carolina.",
        "Pre- and post-processing both run.",
        // Layout.
        "Dear team,\n\nThe release is ready.\n\nBest regards,\nDana",
        "Agenda\n\n1. Budget review.\n2. Hiring plan.\n3. Open questions.",
    ]

    @Test func leavesManyMoreAlreadyCleanSentencesUnchanged() {
        #expect(Self.cleanSentences.count >= 40)
        for sample in Self.cleanSentences {
            #expect(clean(sample) == sample, "changed: \(sample.debugDescription) -> \(clean(sample).debugDescription)")
        }
    }

    @Test func leavesGeneratedPunctuatedSentencesUnchanged() {
        var random = SplitMix64(seed: 20_260_501)
        for _ in 0..<400 {
            let sample = Self.generatedText(&random)
            #expect(clean(sample) == sample, "changed: \(sample.debugDescription) -> \(clean(sample).debugDescription)")
        }
    }

    private static func generatedText(_ random: inout SplitMix64) -> String {
        let subjects = [
            "The team", "My manager", "Dana", "Marco and Sofia", "The editor", "She", "They", "Our new line of products",
            "The comma key", "The period of rest", "Everyone at the new office", "Priya", "The question mark", "A full stop",
        ]
        let predicates = [
            "reviewed the draft", "added a comma after the greeting", "spent the holiday period at home",
            "asked about the exclamation point", "moved to New York New York", "visited Bora Bora", "split the line in two",
            "marked the new paragraph", "forgot the period at the end", "waited at the bus stop", "said no, no, no",
            "pressed the new line key", "ran kubectl get pods", "opened config.json", "checked the loop variable i",
            "used the --verbose flag", "called fetchUser(id)", "read src/main.swift", "stopped at the second comma",
            "found a long period of silence", "typed a question mark", "left a stop sign on the desk",
        ]
        let tails = ["", " on Monday", " before lunch", " without any trouble", " this week", " at 3:30 PM", " in Q3"]
        let questions = [
            "Did the team finish the draft", "Can you send the file", "Is the new line of products ready",
            "Would Dana review it", "Where is the period key", "How many commas are in the list",
        ]
        func pick(_ values: [String], _ random: inout SplitMix64) -> String { values[Int(random.next() % UInt64(values.count))] }

        var sentences: [String] = []
        for _ in 0..<(1 + Int(random.next() % 3)) {
            if random.next() % 4 == 0 {
                sentences.append(pick(questions, &random) + pick(tails, &random) + "?")
            } else {
                let mark = random.next() % 6 == 0 ? "!" : "."
                sentences.append(pick(subjects, &random) + " " + pick(predicates, &random) + pick(tails, &random) + mark)
            }
        }
        let separator = [" ", " ", "\n", "\n\n"][Int(random.next() % 4)]
        return sentences.joined(separator: separator)
    }
}

/// A small seedable generator, so the fuzz test is reproducible.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
