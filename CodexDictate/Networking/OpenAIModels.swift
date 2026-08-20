import Foundation

struct OpenAIConfiguration: Sendable {
    var baseURL = URL(string: "https://api.openai.com")!
    var transcriptionModel = "gpt-transcribe"
    var structuringModel = "gpt-5.6-terra"
    var maximumOutputTokens = 4096
}

struct TranscriptionResult: Equatable, Sendable {
    let text: String
    let languages: [String]
}

struct TranscriptionResponse: Decodable, Equatable, Sendable {
    struct Language: Decodable, Equatable, Sendable {
        let code: String
    }

    let text: String
    let languages: [Language]?
}

struct ResponsesAPIResponse: Decodable, Equatable, Sendable {
    struct OutputItem: Decodable, Equatable, Sendable {
        struct ContentItem: Decodable, Equatable, Sendable {
            let type: String
            let text: String?
        }

        let type: String?
        let content: [ContentItem]?
    }

    let output: [OutputItem]

    func extractedOutputText() throws -> String {
        let pieces = output.flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
        let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIError.invalidStructuringResponse }
        return text
    }
}

enum OpenAIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case invalidRequest(status: Int)
    case timeout
    case networkUnavailable
    case invalidJSON
    case emptyTranscript
    case invalidStructuringResponse
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .unauthorized: "OpenAI rejected the API key"
        case .forbidden: "OpenAI billing or model access is unavailable"
        case .notFound: "The configured OpenAI model or endpoint is unavailable"
        case .rateLimited: "OpenAI rate limit reached"
        case .server: "OpenAI server failure"
        case .invalidRequest: "OpenAI rejected the request"
        case .timeout: "OpenAI request timed out"
        case .networkUnavailable: "Network unavailable"
        case .invalidJSON: "Invalid OpenAI response"
        case .emptyTranscript: "OpenAI returned an empty transcript"
        case .invalidStructuringResponse: "Invalid structuring response"
        case .invalidFile: "Recording file is invalid"
        }
    }
}

enum RetryPolicy {
    static func shouldRetry(error: OpenAIError, attempt: Int) -> Bool {
        guard attempt == 0 else { return false }
        return switch error {
        case .rateLimited, .server, .timeout, .networkUnavailable: true
        default: false
        }
    }
}

enum TranscriptionFailurePolicy {
    static func isNoSpeech(_ error: Error, peakLevel: Float) -> Bool {
        (error as? OpenAIError) == .emptyTranscript
            && peakLevel < AudioRecordingPolicy.minimumSpeechLevel
    }
}

enum StructuringFallback {
    static func result(rawTranscript: String, structuredResult: Result<String, Error>) -> (text: String, usedRaw: Bool) {
        switch structuredResult {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? (rawTranscript, true) : (trimmed, false)
        case .failure:
            return (rawTranscript, true)
        }
    }
}
