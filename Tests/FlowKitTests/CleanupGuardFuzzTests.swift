import Testing
@testable import FlowKit

/// Takes cleanups the guard trusts and damages each in the three ways a model damages text: it adds a word, loses
/// a word, or puts two words in the wrong order. The guard must reject every one.
@Suite struct CleanupGuardFuzzTests {
    let guardrail = CleanupGuard.standard

    /// (dictation, cleanup) pairs that are faithful. The same sentence is used plain, with a filler after its first
    /// word, and with its first word stuttered, so the guard sees each allowed edit alongside the damage.
    static let bases: [(raw: String, cleaned: String)] = [
        ("please close the garage door before you leave", "Please close the garage door before you leave."),
        ("the quarterly numbers came in higher than we expected", "The quarterly numbers came in higher than we expected."),
        ("remind me to call the plumber about the leak in the kitchen", "Remind me to call the plumber about the leak in the kitchen."),
        ("we should ship the fix on friday and tell the customers about it", "We should ship the fix on Friday and tell the customers about it."),
        ("send the invoice to dana by friday", "Send the invoice to Dana by Friday."),
        ("book the conference room for the offsite on monday", "Book the conference room for the offsite on Monday."),
        ("our flight lands in boston at noon and we drive to cambridge", "Our flight lands in Boston at noon, and we drive to Cambridge."),
        ("the design team and the product managers need the new mockups", "The design team and the product managers need the new mockups."),
        ("we are moving the standup because the room is booked", "We are moving the standup because the room is booked."),
        ("I think the build failed because of the missing dependency", "I think the build failed because of the missing dependency."),
        ("the dentist said the cleaning takes about an hour", "The dentist said the cleaning takes about an hour."),
        ("tell the customers that the delivery will arrive early", "Tell the customers that the delivery will arrive early."),
        ("the dog bit the man and the man called the vet", "The dog bit the man, and the man called the vet."),
        ("the review with legal is on thursday afternoon", "The review with legal is on Thursday afternoon."),
        ("do you want coffee or tea with the sandwich", "Do you want coffee or tea with the sandwich?"),
        ("what time does the pharmacy close on weekends", "What time does the pharmacy close on weekends?"),
        ("can you send me the latest numbers by friday", "Can you send me the latest numbers by Friday?"),
        ("we have twenty five chairs for the room", "We have 25 chairs for the room."),
        ("the call starts at three thirty tomorrow", "The call starts at 3:30 tomorrow."),
        ("the pipe is two point five inches wide", "The pipe is 2.5 inches wide."),
        ("about fifteen percent of the team left early", "About 15% of the team left early."),
        ("we raised ten million dollars last year", "We raised $10 million last year."),
        ("version two point four point one fixes the crash", "Version 2.4.1 fixes the crash."),
        ("the party is on march fifth at noon", "The party is on March 5th at noon."),
        ("dear team comma new paragraph the release is ready period", "Dear team,\n\nThe release is ready."),
        ("thank you for the update comma i will review it today period", "Thank you for the update, I will review it today."),
        ("rename use auth session to use session in the hook", "Rename useAuthSession to useSession in the hook."),
        ("set the environment variable api base url to the staging host", "Set the environment variable API_BASE_URL to the staging host."),
        ("ask john to call the vendor no wait ask mike to call the vendor", "Ask Mike to call the vendor."),
        ("meet me at the north gate no wait the south gate at noon", "Meet me at the south gate at noon."),
        ("the deadline is friday I mean monday because of the holiday", "The deadline is Monday because of the holiday."),
        ("please bring the laptop sorry the tablet to the meeting", "Please bring the tablet to the meeting."),
        ("send the report to maria on friday scratch that send the report to peter on monday", "Send the report to Peter on Monday."),
        ("the car in the driveway is red no blue and it needs a wash", "The car in the driveway is blue and it needs a wash."),
        ("book a table for six sorry for eight people on saturday", "Book a table for eight people on Saturday."),
        ("it takes, you know, a couple of seconds to start up", "It takes a couple of seconds to start up."),
    ]

    static func corpus() -> [(raw: String, cleaned: String)] {
        var pairs: [(raw: String, cleaned: String)] = []
        for base in bases {
            var words = base.raw.split(separator: " ").map(String.init)
            pairs.append(base)
            words.insert("um", at: 1)
            pairs.append((words.joined(separator: " "), base.cleaned))
            words.remove(at: 1)
            words.insert(words[0], at: 0)
            pairs.append((words.joined(separator: " "), base.cleaned))
        }
        return Array(pairs.prefix(100))
    }

    /// Small deterministic generator, so a failure names the same pair every run.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let extraWords = [
        "banana", "maybe", "however", "tomorrow", "blue", "Paris", "indeed", "kindly", "urgent", "never", "twice", "Okay", "answer",
    ]
    private static let skippedWords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "so", "if", "is", "are", "was",
        "were", "be", "it", "its", "this", "that", "i", "you", "we", "they", "me", "my", "our", "do", "does", "did", "can", "will",
    ]

    /// Splits a chunk like "(Friday)," into its punctuation and its letters.
    private static func core(of chunk: String) -> (lead: String, word: String, trail: String) {
        let letters = chunk.drop(while: { !$0.isLetter && !$0.isNumber })
        let lead = String(chunk.prefix(chunk.count - letters.count))
        let word = String(letters.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
        return (lead, word, String(letters.dropFirst(word.count)))
    }

    private static func isContent(_ chunk: String) -> Bool {
        let word = core(of: chunk).word
        return word.count >= 3 && word.allSatisfy(\.isLetter) && !skippedWords.contains(word.lowercased())
    }

    static func inserting(into text: String, using generator: inout SeededGenerator) -> String {
        var chunks = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let word = extraWords.randomElement(using: &generator)!
        chunks.insert(word, at: Int.random(in: 0...chunks.count, using: &generator))
        return chunks.joined(separator: " ")
    }

    static func deleting(from text: String, using generator: inout SeededGenerator) -> String? {
        var chunks = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let candidates = chunks.indices.filter { isContent(chunks[$0]) }
        guard let index = candidates.randomElement(using: &generator) else { return nil }
        chunks.remove(at: index)
        return chunks.joined(separator: " ")
    }

    static func swapping(in text: String, using generator: inout SeededGenerator) -> String? {
        var chunks = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let candidates = chunks.indices.filter { isContent(chunks[$0]) }
        guard candidates.count >= 2 else { return nil }
        for _ in 0..<20 {
            let pair = candidates.shuffled(using: &generator).prefix(2).sorted()
            let first = core(of: chunks[pair[0]])
            let second = core(of: chunks[pair[1]])
            if first.word.lowercased() == second.word.lowercased() { continue }
            func recased(_ word: String, like other: String) -> String {
                guard let head = other.first, let own = word.first else { return word }
                return (head.isUppercase ? own.uppercased() : own.lowercased()) + word.dropFirst()
            }
            chunks[pair[0]] = first.lead + recased(second.word, like: first.word) + first.trail
            chunks[pair[1]] = second.lead + recased(first.word, like: second.word) + second.trail
            return chunks.joined(separator: " ")
        }
        return nil
    }

    /// A damaged output that is in fact another faithful edit of its dictation (for example, deleting a word
    /// the speaker also stuttered would still be a fault, but swapping two identical words is no change at all).
    /// Empty: no mutation of this corpus produced one. Add `corpus index:mutation` here, with the reason, if one does.
    static let exemptions: Set<String> = []

    @Test func theCorpusItselfIsTrusted() {
        let pairs = Self.corpus()
        #expect(pairs.count == 100)
        for (index, pair) in pairs.enumerated() {
            let verdict = guardrail.evaluate(raw: pair.raw, cleaned: pair.cleaned)
            #expect(verdict.isTrustworthy, "pair \(index): \(pair.raw) -> \(pair.cleaned): \(String(describing: verdict.failure))")
        }
    }

    @Test func rejectsEveryAddedLostOrSwappedWord() {
        var generator = SeededGenerator(state: 20_260_501)
        var tried = 0
        for (index, pair) in Self.corpus().enumerated() {
            for round in 0..<3 {
                var damaged: [(kind: String, text: String)] = [("insert", Self.inserting(into: pair.cleaned, using: &generator))]
                if let lost = Self.deleting(from: pair.cleaned, using: &generator) { damaged.append(("delete", lost)) }
                if let swapped = Self.swapping(in: pair.cleaned, using: &generator) { damaged.append(("swap", swapped)) }
                for (kind, text) in damaged {
                    tried += 1
                    let key = "\(index):\(kind)"
                    if Self.exemptions.contains(key) { continue }
                    let verdict = guardrail.evaluate(raw: pair.raw, cleaned: text)
                    #expect(!verdict.isTrustworthy, "round \(round) \(key) was trusted: \(pair.raw) -> \(text)")
                }
            }
        }
        // Every pair got three rounds of each damage that applies to it.
        #expect(tried >= 800)
    }
}
