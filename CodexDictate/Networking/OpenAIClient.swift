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

private struct StructuredResponsesRequestBody: Encodable {
    struct Reasoning: Encodable { let effort: String }
    struct TextConfiguration: Encodable {
        struct Format: Encodable {
            let type = "json_schema"
            let name: String
            let strict = true
            let schema: JSONSchemaValue
        }
        let format: Format
    }

    let model: String
    let reasoning: Reasoning
    let instructions: String
    let input: String
    let text: TextConfiguration
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, reasoning, instructions, input, text
        case maxOutputTokens = "max_output_tokens"
    }
}

actor OpenAIClient {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let configuration: OpenAIConfiguration
    private let transport: HTTPRequestTransport
    private let sleeper: Sleeper
    private let diagnostics: (any DiagnosticRecording)?
    private let logger = Logger(subsystem: "com.personal.CodexDictate", category: "OpenAI")

    init(
        configuration: OpenAIConfiguration = OpenAIConfiguration(),
        transport: HTTPRequestTransport = URLSessionTransport(),
        diagnostics: (any DiagnosticRecording)? = nil,
        sleeper: @escaping Sleeper = { seconds in
            try await Task<Never, Never>.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.diagnostics = diagnostics
        self.sleeper = sleeper
    }

    func transcribe(
        audioURL: URL,
        prompt: String,
        keywords: [String],
        languages: [String],
        apiKey: String
    ) async throws -> TranscriptionResult {
        let startedAt = Date()
        await record(DiagnosticEvent(name: .stageStarted, stage: .transcription, outcome: .started))
        do {
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
                let data = try await perform(request, apiKey: apiKey, stage: .transcription)
                guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                    throw OpenAIError.invalidJSON
                }
                let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let result = TranscriptionResult(text: text, languages: decoded.languages?.map(\.code) ?? [])
                    await record(DiagnosticEvent(
                        name: .stageCompleted,
                        stage: .transcription,
                        outcome: .success,
                        durationMilliseconds: Self.milliseconds(since: startedAt),
                        characterCount: text.count,
                        itemCount: result.languages.count
                    ))
                    return result
                }
                if attempt == 0 {
                    logger.notice("Empty transcription response; retrying once")
                    await record(DiagnosticEvent(
                        name: .retryScheduled,
                        stage: .transcription,
                        outcome: .retry,
                        attempt: 2,
                        errorCode: "openai.empty_transcript"
                    ))
                }
            }
            throw OpenAIError.emptyTranscript
        } catch {
            await record(DiagnosticEvent(
                name: .stageFailed,
                stage: .transcription,
                outcome: .failure,
                durationMilliseconds: Self.milliseconds(since: startedAt),
                errorCode: DiagnosticErrorSanitizer.code(for: error)
            ))
            throw error
        }
    }

    func structuredResponse<T: Decodable & Sendable>(
        stage: FidelityStage,
        instructions: String,
        input: String,
        schema: JSONSchemaValue,
        apiKey: String
    ) async throws -> T {
        let diagnosticStage = stage.diagnosticStage
        let startedAt = Date()
        await record(DiagnosticEvent(name: .stageStarted, stage: diagnosticStage, outcome: .started))
        let body = StructuredResponsesRequestBody(
            model: configuration.structuringModel,
            reasoning: .init(effort: "low"),
            instructions: instructions,
            input: input,
            text: .init(format: .init(
                name: "codex_dictate_\(stage.rawValue)",
                schema: schema
            )),
            maxOutputTokens: configuration.structuredOutputTokenBudget(
                inputByteCount: input.utf8.count
            )
        )
        var request = URLRequest(url: endpoint("v1/responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            for responseAttempt in 0...1 {
                let data = try await perform(request, apiKey: apiKey, stage: diagnosticStage)
                do {
                    let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)
                    let output = try response.extractedOutputText()
                    guard let decodedData = output.data(using: .utf8) else {
                        throw FidelityPipelineError.malformedModelResponse
                    }
                    let decoded = try JSONDecoder().decode(T.self, from: decodedData)
                    await record(DiagnosticEvent(
                        name: .stageCompleted,
                        stage: diagnosticStage,
                        outcome: .success,
                        durationMilliseconds: Self.milliseconds(since: startedAt),
                        byteCount: decodedData.count
                    ))
                    return decoded
                } catch let error as FidelityPipelineError {
                    guard responseAttempt == 0 else { throw error }
                    logger.notice("Retrying an incomplete structured response")
                    await record(DiagnosticEvent(
                        name: .retryScheduled,
                        stage: diagnosticStage,
                        outcome: .retry,
                        attempt: 2,
                        errorCode: DiagnosticErrorSanitizer.code(for: error)
                    ))
                } catch {
                    guard responseAttempt == 0 else {
                        throw FidelityPipelineError.malformedModelResponse
                    }
                    logger.notice("Retrying a malformed structured response")
                    await record(DiagnosticEvent(
                        name: .retryScheduled,
                        stage: diagnosticStage,
                        outcome: .retry,
                        attempt: 2,
                        errorCode: "fidelity.malformed_model_response"
                    ))
                }
            }
            throw FidelityPipelineError.malformedModelResponse
        } catch {
            await record(DiagnosticEvent(
                name: .stageFailed,
                stage: diagnosticStage,
                outcome: .failure,
                durationMilliseconds: Self.milliseconds(since: startedAt),
                errorCode: DiagnosticErrorSanitizer.code(for: error)
            ))
            throw error
        }
    }

    private func endpoint(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func perform(
        _ unsignedRequest: URLRequest,
        apiKey: String,
        stage: DiagnosticStage
    ) async throws -> Data {
        var request = unsignedRequest
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for attempt in 0...1 {
            let attemptStartedAt = Date()
            do {
                let (data, response) = try await transport.data(for: request)
                await record(DiagnosticEvent(
                    name: .httpResponse,
                    stage: stage,
                    outcome: (200..<300).contains(response.statusCode) ? .success : .failure,
                    durationMilliseconds: Self.milliseconds(since: attemptStartedAt),
                    attempt: attempt + 1,
                    httpStatus: response.statusCode,
                    byteCount: data.count
                ))
                if (200..<300).contains(response.statusCode) { return data }
                let error = Self.mapHTTPError(response)
                guard RetryPolicy.shouldRetry(error: error, attempt: attempt) else { throw error }
                let delay = min(Self.retryDelay(from: response) ?? 0.5, 10)
                logger.notice("Retrying a transient OpenAI request")
                await record(DiagnosticEvent(
                    name: .retryScheduled,
                    stage: stage,
                    outcome: .retry,
                    attempt: attempt + 2,
                    httpStatus: response.statusCode,
                    errorCode: DiagnosticErrorSanitizer.code(for: error)
                ))
                try await sleeper(delay)
            } catch let error as OpenAIError {
                guard RetryPolicy.shouldRetry(error: error, attempt: attempt) else { throw error }
                await record(DiagnosticEvent(
                    name: .retryScheduled,
                    stage: stage,
                    outcome: .retry,
                    attempt: attempt + 2,
                    errorCode: DiagnosticErrorSanitizer.code(for: error)
                ))
                try await sleeper(0.5)
            } catch let error as URLError {
                let mapped = Self.mapNetworkError(error)
                guard RetryPolicy.shouldRetry(error: mapped, attempt: attempt) else { throw mapped }
                await record(DiagnosticEvent(
                    name: .retryScheduled,
                    stage: stage,
                    outcome: .retry,
                    attempt: attempt + 2,
                    errorCode: DiagnosticErrorSanitizer.code(for: mapped)
                ))
                try await sleeper(0.5)
            } catch {
                throw OpenAIError.networkUnavailable
            }
        }
        throw OpenAIError.networkUnavailable
    }

    private func record(_ event: DiagnosticEvent) async {
        await diagnostics?.record(event, sessionID: DiagnosticContext.sessionID)
    }

    private static func milliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
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
