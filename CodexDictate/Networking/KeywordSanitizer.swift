import Foundation

enum KeywordSanitizer {
    enum ValidationError: LocalizedError, Equatable {
        case forbiddenCharacters
        case termTooLong
        case tooManyTerms

        var errorDescription: String? {
            switch self {
            case .forbiddenCharacters: "Vocabulary terms cannot contain <, >, or line breaks"
            case .termTooLong: "Vocabulary terms must be 80 characters or fewer"
            case .tooManyTerms: "Use no more than 64 vocabulary terms"
            }
        }
    }

    static func sanitize(_ entries: [String], maximumCount: Int = 64, maximumLength: Int = 80) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            guard !entry.contains("<"), !entry.contains(">"), !entry.contains("\r"), !entry.contains("\n") else {
                throw ValidationError.forbiddenCharacters
            }
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maximumLength else { throw ValidationError.termTooLong }
            let identity = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(identity).inserted { result.append(trimmed) }
            guard result.count <= maximumCount else { throw ValidationError.tooManyTerms }
        }
        return result
    }
}
