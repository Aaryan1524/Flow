import Foundation
import Testing
@testable import PersonalDictionary

@Suite struct PersonalDictionaryTests {
    // MARK: - Parsing

    @Test func parsesTermsAliasesCommentsAndBlankLines() {
        let dictionary = PersonalDictionary.parse(
            """
            # a comment

            Supabase
            Vercel: versel, over cell
               iPhone
            """)
        #expect(dictionary.entries.map(\.term) == ["Supabase", "Vercel", "iPhone"])
        #expect(dictionary.entries[1].aliases == ["versel", "over cell"])
        #expect(dictionary.entries[0].aliases.isEmpty)
    }

    @Test func aTermListedTwiceKeepsItsFirstSpellingAndGathersAliases() {
        let dictionary = PersonalDictionary.parse("GitHub: git hub\ngithub: get hub, git hub\n")
        #expect(dictionary.count == 1)
        #expect(dictionary.entries[0].term == "GitHub")
        #expect(dictionary.entries[0].aliases == ["git hub", "get hub"])
    }

    @Test func ignoresEntriesWithNoTerm() {
        #expect(PersonalDictionary.parse(": alias only\n   \n#").isEmpty)
    }

    @Test func aliasesWithOddSpacingAndEmptyPiecesAreTidied() {
        let entry = PersonalDictionary.parse("Vercel:  versel ,, over cell ,").entries[0]
        #expect(entry.aliases == ["versel", "over cell"])
    }

    // MARK: - Layering your own list over the built-in one

    @Test func yourEntriesComeFirstAndReplaceBuiltInOnesOfTheSameName() {
        let builtIn = PersonalDictionary.parse("Alpha\nBravo: bravo alias\nCharlie")
        let mine = PersonalDictionary.parse("bravo\nDelta: dlta", isUserDefined: true)
        let merged = builtIn.merged(withUser: mine)
        #expect(merged.entries.map(\.term) == ["bravo", "Delta", "Alpha", "Charlie"])
        #expect(merged.entries[0].isUserDefined)
        #expect(merged.entries[0].aliases.isEmpty)
    }

    // MARK: - What the speech engine is told to listen for

    @Test func boostsDistinctiveTermsInOrderAndLeavesOutShortAndEverydayOnes() {
        let dictionary = PersonalDictionary.parse("Vercel\nGo\nSwift\nAI\nS3\nSupabase\n2024\nClaude Code\nRust")
        // "Go", "Swift" and "Rust" are everyday words, "AI" and "S3" are too short, and 2024 is a bare number.
        #expect(dictionary.boostTerms() == ["Vercel", "Supabase", "Claude Code"])
    }

    @Test func boostTermsHonoursTheLimitAndNeverRepeats() {
        let dictionary = PersonalDictionary.parse((0..<50).map { "Term\($0)" }.joined(separator: "\n") + "\nterm1")
        let terms = dictionary.boostTerms(limit: 10)
        #expect(terms.count == 10)
        #expect(Set(terms.map { $0.lowercased() }).count == 10)
        #expect(terms.first == "Term0")
    }

    @Test func yourTermsAreBoostedBeforeBuiltInOnesWhenTheListIsCapped() {
        let builtIn = PersonalDictionary.parse("Alpha1\nAlpha2\nAlpha3")
        let mine = PersonalDictionary.parse("MyCompany", isUserDefined: true)
        #expect(builtIn.merged(withUser: mine).boostTerms(limit: 2) == ["MyCompany", "Alpha1"])
    }

    // MARK: - Spelling and capitalisation afterwards

    @Test func capitalisationComesFromTheTermsThemselves() {
        let replacements = PersonalDictionary.parse("GitHub\nkubectl\niPhone\nOpenAI").replacements
        #expect(replacements["github"] == "GitHub")
        #expect(replacements["iphone"] == "iPhone")
        #expect(replacements["openai"] == "OpenAI")
        // Already lowercase: nothing to correct.
        #expect(replacements["kubectl"] == nil)
    }

    @Test func aliasesMapToTheTermAndWinOverCapitalisation() {
        let replacements = PersonalDictionary.parse("Vercel: versel, over cell\nSupabase: super base").replacements
        #expect(replacements["versel"] == "Vercel")
        #expect(replacements["over cell"] == "Vercel")
        #expect(replacements["super base"] == "Supabase")
        #expect(replacements["vercel"] == "Vercel")
    }

    @Test func aBuiltInEverydayWordIsNotForcedIntoTheTextButYourOwnIs() {
        #expect(PersonalDictionary.parse("Swift\nRust").replacements.isEmpty)
        #expect(PersonalDictionary.parse("Swift", isUserDefined: true).replacements["swift"] == "Swift")
    }

    // MARK: - Files

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flow-dict-\(UUID().uuidString)").appendingPathComponent("dictionary.txt")
    }

    @Test func createsAPrivateFileWithInstructionsOnce() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DictionaryFiles.ensureUserFileExists(at: url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
        // The instructions are all comments, so a fresh file defines nothing.
        #expect(DictionaryFiles.user(at: url).isEmpty)

        try "MyCompany\n".appendedTo(url)
        try DictionaryFiles.ensureUserFileExists(at: url)  // must not overwrite
        #expect(DictionaryFiles.user(at: url).entries.map(\.term) == ["MyCompany"])
    }

    @Test func aMissingFileIsAnEmptyDictionary() {
        #expect(DictionaryFiles.user(at: temporaryFile()).isEmpty)
        #expect(DictionaryFiles.modificationDate(of: temporaryFile()) == nil)
    }

    @Test func theBuiltInListLoadsFromTheAppBundle() {
        let starter = DictionaryFiles.starter()
        #expect(!starter.isEmpty)
        #expect(starter.entries.allSatisfy { !$0.isUserDefined })
    }

    @Test func combinedLayersYourFileOverTheBuiltInList() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DictionaryFiles.ensureUserFileExists(at: url)
        try "ZzzMyCompany\n".appendedTo(url)
        let combined = DictionaryFiles.combined(userURL: url)
        #expect(combined.entries.first?.term == "ZzzMyCompany")
        #expect(combined.count == DictionaryFiles.starter().count + 1)
    }

    @Test func theBuiltInListHasNoDuplicatesAndBoostsOnlySensibleTerms() {
        let starter = DictionaryFiles.starter()
        let keys = starter.entries.map { $0.term.lowercased() }
        #expect(Set(keys).count == keys.count)
        for term in starter.boostTerms(limit: 10_000) {
            #expect(term.count >= PersonalDictionary.minimumBoostLength)
            #expect(!PersonalDictionary.everydayWords.contains(term.lowercased()))
        }
    }
}

private extension String {
    func appendedTo(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
