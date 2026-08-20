import Foundation
import OSLog

protocol HTTPRequestTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionTransport: HTTPRequestTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OpenAIError.invalidJSON }
        return (data, response)
    }
}

actor OpenAIClient {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let configuration: OpenAIConfiguration
    private let transport: HTTPRequestTransport
    private let sleeper: Sleeper
    private let logger = Logger(subsystem: "com.personal.CodexDictate", category: "OpenAI")

    init(
        configuration: OpenAIConfiguration = OpenAIConfiguration(),
        transport: HTTPRequestTransport = URLSessionTransport(),
        sleeper: @escaping Sleeper = { seconds in
            try await Task<Never, Never>.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleeper = sleeper
    }

    func transcribe(
        audioURL: URL,
        prompt: String,
        keywords: [String],
        languages: [String],
        apiKey: String
    ) async throws -> TranscriptionResult {
        guard let audio = try? Data(contentsOf: audioURL), !audio.isEmpty,
              audio.count < AudioRecorderService.maximumUploadBytes else {
            throw OpenAIError.invalidFile
        }
        var form = MultipartFormData()
        form.appendField(name: "model", value: configuration.transcriptionModel)
        form.appendField(name: "prompt", value: prompt)
        for keyword in keywords { form.appendField(name: "keywords[]", value: keyword) }
        for language in languages { form.appendField(name: "languages[]", value: language) }
        form.appendFile(name: "file", filename: "dictation.m4a", mimeType: "audio/mp4", contents: audio)
        form.finalize()

        var request = URLRequest(url: endpoint("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data
        for attempt in 0...1 {
            let data = try await perform(request, apiKey: apiKey)
            guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                throw OpenAIError.invalidJSON
            }
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return TranscriptionResult(text: text, languages: decoded.languages?.map(\.code) ?? [])
            }
            if attempt == 0 {
                logger.notice("Empty transcription response; retrying once")
            }
        }
        throw OpenAIError.emptyTranscript
    }

    func structure(transcript: String, mode: StructuringMode, apiKey: String) async throws -> String {
        struct RequestBody: Encodable {
            struct Reasoning: Encodable { let effort: String }
            let model: String
            let reasoning: Reasoning
            let instructions: String
            let input: String
            let maxOutputTokens: Int

            enum CodingKeys: String, CodingKey {
                case model, reasoning, instructions, input
                case maxOutputTokens = "max_output_tokens"
            }
        }

        let body = RequestBody(
            model: configuration.structuringModel,
            reasoning: .init(effort: "low"),
            instructions: StructuringInstructions.text(for: mode),
            input: transcript,
            maxOutputTokens: configuration.maximumOutputTokens
        )
        var request = URLRequest(url: endpoint("v1/responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await perform(request, apiKey: apiKey)
        guard let decoded = try? JSONDecoder().decode(ResponsesAPIResponse.self, from: data) else {
            throw OpenAIError.invalidJSON
        }
        return try decoded.extractedOutputText()
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func perform(_ unsignedRequest: URLRequest, apiKey: String) async throws -> Data {
        var request = unsignedRequest
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for attempt in 0...1 {
            do {
                let (data, response) = try await transport.data(for: request)
                if (200..<300).contains(response.statusCode) { return data }
                let error = Self.mapHTTPError(response)
                guard RetryPolicy.shouldRetry(error: error, attempt: attempt) else { throw error }
                let delay = min(Self.retryDelay(from: response) ?? 0.5, 10)
                logger.notice("Retrying a transient OpenAI request")
                try await sleeper(delay)
            } catch let error as OpenAIError {
                guard RetryPolicy.shouldRetry(error: error, attempt: attempt) else { throw error }
                try await sleeper(0.5)
            } catch let error as URLError {
                let mapped = Self.mapNetworkError(error)
                guard RetryPolicy.shouldRetry(error: mapped, attempt: attempt) else { throw mapped }
                try await sleeper(0.5)
            } catch {
                throw OpenAIError.networkUnavailable
            }
        }
        throw OpenAIError.networkUnavailable
    }

    static func mapHTTPError(_ response: HTTPURLResponse) -> OpenAIError {
        switch response.statusCode {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited(retryAfter: retryDelay(from: response))
        case 500...599: .server(status: response.statusCode)
        default: .invalidRequest(status: response.statusCode)
        }
    }

    static func mapNetworkError(_ error: URLError) -> OpenAIError {
        switch error.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost: .networkUnavailable
        default: .networkUnavailable
        }
    }

    static func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
