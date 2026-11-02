import Foundation

/// One name, product or piece of jargon, and the wrong ways it tends to be heard.
public struct DictionaryEntry: Sendable, Equatable {
    /// The correct spelling, with the capitalisation you want: "Supabase", "useAuthSession", "GitHub".
    public let term: String
    /// Spoken or mis-heard forms to correct to `term`, e.g. "super base" for "Supabase".
    public let aliases: [String]
    /// Where it came from. A built-in term that is also an everyday word is not forced into the text.
    public let isUserDefined: Bool

    public init(term: String, aliases: [String] = [], isUserDefined: Bool = false) {
        self.term = term
        self.aliases = aliases
        self.isUserDefined = isUserDefined
    }
}

/// A personal dictionary: the words you use that a speech engine would not know how to spell.
///
/// File format, one entry per line:
///
///     # comment
///     Supabase
///     Vercel: versel, over cell
///     iPhone
///
/// `Term: alias, alias` also fixes the listed mis-hearings. It does two jobs. The speech engine is told to listen
/// for the terms, which fixes names it has never seen. And a cleanup pass corrects the capitalisation and the
/// aliases afterwards, which fixes "github" to "GitHub".
public struct PersonalDictionary: Sendable, Equatable {
    public let entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    // MARK: - Reading

    /// Lines starting with # and blank lines are ignored. A term listed twice keeps its first spelling and gains the
    /// aliases of both.
    public static func parse(_ text: String, isUserDefined: Bool = false) -> PersonalDictionary {
        var order: [String] = []
        var found: [String: DictionaryEntry] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var term = line
            var aliases: [String] = []
            if let colon = line.firstIndex(of: ":") {
                term = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                aliases = line[line.index(after: colon)...].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            if let existing = found[key] {
                let merged = existing.aliases + aliases.filter { alias in !existing.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame } }
                found[key] = DictionaryEntry(term: existing.term, aliases: merged, isUserDefined: existing.isUserDefined)
            } else {
                order.append(key)
                found[key] = DictionaryEntry(term: term, aliases: aliases, isUserDefined: isUserDefined)
            }
        }
        return PersonalDictionary(entries: order.compactMap { found[$0] })
    }

    /// Your own entries win: a term in `user` replaces the built-in entry of the same name, and comes first.
    public func merged(withUser user: PersonalDictionary) -> PersonalDictionary {
        let userKeys = Set(user.entries.map { $0.term.lowercased() })
        return PersonalDictionary(entries: user.entries + entries.filter { !userKeys.contains($0.term.lowercased()) })
    }

    // MARK: - For the speech engine

    /// FluidAudio ignores terms shorter than this.
    static let minimumBoostLength = 3

    /// Everyday words that are also names ("Go", "Swift", "Rust", "Next", "Claude"). Telling the speech engine to
    /// listen for them would swap them in for similar-sounding ordinary words, so they are never boosted.
    static let everydayWords: Set<String> = [
        "go", "swift", "rust", "next", "ray", "spark", "flask", "bun", "deno", "mint", "apple", "amazon", "meta", "gemini",
        "cursor", "claude", "windsurf", "zed", "vim", "nano", "code", "ruby", "python", "java", "scala", "dart", "julia",
        "lua", "perl", "kotlin", "elixir", "haskell", "swarm", "flow", "stripe", "slack", "notion", "linear", "figma",
        "loom", "arc", "brave", "edge", "safari", "chrome", "pages", "numbers", "keynote", "shortcuts", "messages", "mail",
        "maps", "music", "photos", "books", "news", "stocks", "home", "weather", "clock", "notes", "files", "preview",
        "terminal", "console", "docker", "git", "make", "just", "task", "fly", "render", "railway", "heroku", "netlify",
        "cloud", "run", "lambda", "glue", "step", "bedrock", "athena", "redshift", "aurora", "dynamo", "kinesis", "pulsar",
        "storm", "airflow", "prefect", "dagster", "kedro", "ray", "dask", "polars", "pandas", "torch",
        "keras", "jax", "mamba", "phi", "llama", "mistral", "falcon", "bloom", "orca", "vicuna", "alpaca",
    ]

    /// Terms to give the speech engine, your own first. Short terms, everyday words and plain numbers are left out,
    /// and `limit` caps the list because a longer list makes wrong swaps.
    /// 250 is the largest list that made no wrong swaps in flow-eval at a minimum similarity of 0.8 (on the first draft
    /// of the starter list, 400 terms made one and 622 made three, before the terms behind them were removed); at
    /// FluidAudio's default similarity of 0.52 even 100 terms swapped 15 words. The app must pass at least 0.8.
    public func boostTerms(limit: Int = 250) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for entry in entries {
            let key = entry.term.lowercased()
            guard entry.term.count >= Self.minimumBoostLength, !Self.everydayWords.contains(key),
                !entry.term.allSatisfy(\.isNumber), seen.insert(key).inserted
            else { continue }
            terms.append(entry.term)
            if terms.count == limit { break }
        }
        return terms
    }

    // MARK: - For the cleanup pass

    /// Spoken or mis-heard form (any case) to canonical spelling. Capitalisation comes from the terms themselves
    /// ("github" becomes "GitHub"); built-in terms that are everyday words are skipped, so "swift" stays lowercase.
    /// Aliases always apply and win over the capitalisation entries.
    public var replacements: [String: String] {
        var map: [String: String] = [:]
        for entry in entries {
            let lowered = entry.term.lowercased()
            let hasSpecialCasing = entry.term != lowered
            if hasSpecialCasing, entry.isUserDefined || !Self.everydayWords.contains(lowered) {
                map[lowered] = entry.term
            }
        }
        for entry in entries {
            for alias in entry.aliases { map[alias.lowercased()] = entry.term }
        }
        return map
    }
}
