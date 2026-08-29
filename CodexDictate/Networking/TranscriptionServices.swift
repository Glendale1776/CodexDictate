import Foundation

protocol TranscriptionServicing: Sendable {
    func transcribe(audioURL: URL, keywords: [String], languages: [String], apiKey: String) async throws -> TranscriptionResult
}

protocol TranscriptStructuringServicing: Sendable {
    func structure(
        transcript: String,
        mode: StructuringMode,
        apiKey: String
    ) async throws -> TranscriptStructuringResult
}

struct TranscriptionService: TranscriptionServicing {
    static let defaultContext = "A single speaker is dictating a software-development request for an AI coding assistant. Preserve technical terminology, product names, acronyms, code identifiers, file paths, terminal commands, URLs, version numbers, punctuation cues, and English technical terms spoken inside another language."

    let client: OpenAIClient

    func transcribe(audioURL: URL, keywords: [String], languages: [String], apiKey: String) async throws -> TranscriptionResult {
        try await client.transcribe(
            audioURL: audioURL,
            prompt: Self.defaultContext,
            keywords: keywords,
            languages: languages,
            apiKey: apiKey
        )
    }
}
