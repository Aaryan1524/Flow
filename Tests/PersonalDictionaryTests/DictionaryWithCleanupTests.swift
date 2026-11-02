import Cleanup
import Testing
@testable import PersonalDictionary

/// The dictionary's spelling map applied by the real cleanup rules, on what the speech engine actually produced.
@Suite struct DictionaryWithCleanupTests {
    private let dictionary = PersonalDictionary.parse(
        """
        Vercel: versal, versel, over cell
        Supabase: superbase, super base
        kubectl: cube c d l, cube ctl, cube control
        pgvector: Pgvector, pg vector
        Qwen: quen, quenn
        pytest: pie test
        scikit-learn: skit learning, scikit learn
        Claude Code: clotcode, cloud code
        GitHub
        PostgreSQL
        """, isUserDefined: true)

    private func clean(_ text: String) -> String { RulesCleaner(dictionary: dictionary.replacements).cleaned(text) }

    @Test func fixesTheThreeMishearingsFromARealDictation() {
        #expect(clean("Versal Superbase and Cube C D L.") == "Vercel Supabase and kubectl.")
    }

    @Test func fixesAliasesInsideSentences() {
        #expect(clean("We deploy the frontend on Versal and use Superbase for the database.") ==
            "We deploy the frontend on Vercel and use Supabase for the database.")
        #expect(clean("I am running pie test with coverage.") == "I am running pytest with coverage.")
        #expect(clean("Use skit learning to build the model.") == "Use scikit-learn to build the model.")
        #expect(clean("Cursor and Cloud Code both support it.") == "Cursor and Claude Code both support it.")
    }

    @Test func keepsToolNamesInTheirOwnCasing() {
        // Parakeet title-cases some tool names; the alias spelled with a capital pins the lowercase form.
        #expect(clean("Index it with Pgvector for search.") == "Index it with pgvector for search.")
        #expect(clean("I pushed it to github.") == "I pushed it to GitHub.")
        #expect(clean("Our postgresql database is slow.") == "Our PostgreSQL database is slow.")
    }

    @Test func aTermAtTheStartOfASentenceKeepsItsSpelling() {
        #expect(clean("kubectl get pods is the command.").hasPrefix("kubectl get pods"))
    }

    @Test func leavesOrdinaryTextAloneEvenWhenItSoundsSimilar() {
        let text = "The queen visited the village and told everyone about the weather."
        #expect(clean(text) == text)
    }

    @Test func punctuationAroundAnAliasIsKept() {
        #expect(clean("Deploy to Versal, then check Superbase.") == "Deploy to Vercel, then check Supabase.")
    }
}
