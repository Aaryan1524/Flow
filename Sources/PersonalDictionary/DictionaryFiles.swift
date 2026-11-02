import Foundation

/// Where the dictionary lives on disk, and how the built-in list and your own are combined.
public enum DictionaryFiles {
    /// Your own list. It holds your names and company jargon, so it is private to you (0600) and is never part of the repo.
    public static var userURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flow", isDirectory: true)
            .appendingPathComponent("dictionary.txt")
    }

    /// The built-in list shipped with the app.
    public static func starter() -> PersonalDictionary {
        guard let url = Bundle.module.url(forResource: "starter-dictionary", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return PersonalDictionary() }
        return PersonalDictionary.parse(text)
    }

    /// Your list, or an empty one if the file doesn't exist yet.
    public static func user(at url: URL = userURL) -> PersonalDictionary {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return PersonalDictionary() }
        return PersonalDictionary.parse(text, isUserDefined: true)
    }

    /// The built-in list with your own entries layered on top.
    public static func combined(userURL: URL = userURL) -> PersonalDictionary {
        starter().merged(withUser: user(at: userURL))
    }

    static let header = """
        # Your personal dictionary. One entry per line; lines starting with # are ignored.
        #
        #   Supabase                      listen for this name and spell it exactly like this
        #   Vercel: versel, over cell     also fix these mis-hearings to "Vercel"
        #   iPhone                        capitalise it this way every time
        #
        # Flow already knows a long built-in list of developer and AI terms. Add your own names, teammates,
        # customers and internal tools here. Changes are picked up within a few seconds.

        """

    /// Creates your file, with instructions at the top, if it isn't there. Returns its location.
    @discardableResult
    public static func ensureUserFileExists(at url: URL = userURL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return url }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileManager.createFile(atPath: url.path, contents: Data(header.utf8), attributes: [.posixPermissions: 0o600])
        return url
    }

    /// When your file last changed, so the app can reload it without being restarted.
    public static func modificationDate(of url: URL = userURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
