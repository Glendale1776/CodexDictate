import Foundation
import XCTest
@testable import CodexDictate

final class NetworkingTests: XCTestCase {
    func testMultipartBuilderUsesRepeatedKeywordAndLanguageFields() {
        var form = MultipartFormData(boundary: "Boundary")
        form.appendField(name: "keywords[]", value: "Codex")
        form.appendField(name: "keywords[]", value: "SwiftUI")
        form.appendField(name: "languages[]", value: "en")
        form.appendField(name: "languages[]", value: "ru")
        form.finalize()
        let text = String(decoding: form.data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "name=\"keywords[]\"").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "name=\"languages[]\"").count - 1, 2)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertTrue(text.hasSuffix("--Boundary--\r\n"))
    }

    func testKeywordSanitizationTrimsDeduplicatesAndLimits() throws {
        XCTAssertEqual(try KeywordSanitizer.sanitize([" Codex ", "codex", "SwiftUI", "  "]), ["Codex", "SwiftUI"])
        XCTAssertThrowsError(try KeywordSanitizer.sanitize(["bad<term"]))
        XCTAssertThrowsError(try KeywordSanitizer.sanitize([String(repeating: "x", count: 81)]))
        XCTAssertThrowsError(try KeywordSanitizer.sanitize((0...64).map(String.init)))
    }

    func testTranscriptionJSONDecodingWithAndWithoutLanguages() throws {
        let decoder = JSONDecoder()
        let response = try decoder.decode(TranscriptionResponse.self, from: Data(#"{"text":"Use SwiftUI","languages":[{"code":"en"}]}"#.utf8))
        XCTAssertEqual(response.text, "Use SwiftUI")
        XCTAssertEqual(response.languages?.map(\.code), ["en"])
        let without = try decoder.decode(TranscriptionResponse.self, from: Data(#"{"text":"Bonjour"}"#.utf8))
        XCTAssertNil(without.languages)
    }

    func testResponsesAPIDecodingAndOutputTextExtraction() throws {
        let fixture = Data(#"""
        {
          "id":"resp_test",
          "output":[
            {"type":"reasoning","content":[]},
            {"type":"message","role":"assistant","content":[
              {"type":"output_text","text":"First paragraph.\n\n","annotations":[]},
              {"type":"output_text","text":"- Keep details","annotations":[]}
            ]}
          ]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: fixture)
        XCTAssertEqual(try response.extractedOutputText(), "First paragraph.\n\n- Keep details")
    }

    func testResponsesAPIRejectsMissingOutputText() throws {
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: Data(#"{"output":[{"type":"reasoning","content":[]}]}"#.utf8))
        XCTAssertThrowsError(try response.extractedOutputText()) { error in
            XCTAssertEqual(error as? OpenAIError, .invalidStructuringResponse)
        }
    }

    func testResponsesAPIRejectsAnyNonCompletedStatus() throws {
        let fixture = Data(#"{"status":"failed","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#.utf8)
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: fixture)
        XCTAssertThrowsError(try response.extractedOutputText()) { error in
            XCTAssertEqual(error as? FidelityPipelineError, .incompleteModelResponse)
        }
    }

    func testStructuringFallbackPreservesSuccessfulTranscript() {
        let failedResult: Result<TranscriptStructuringResult, Error> = .failure(OpenAIError.server(status: 500))
        let failed = StructuringFallback.result(rawTranscript: "Raw details", structuredResult: failedResult)
        XCTAssertEqual(failed.text, "DICTATED REQUEST:\n\nRaw details")
        XCTAssertTrue(failed.usedRaw)

        let succeeded = StructuringFallback.result(
            rawTranscript: "Raw",
            structuredResult: .success(.init(text: "  Cleaned  ", usedRawFallback: false))
        )
        XCTAssertEqual(succeeded.text, "Cleaned")
        XCTAssertFalse(succeeded.usedRaw)

        let pipelineFallback = StructuringFallback.result(
            rawTranscript: "Raw",
            structuredResult: .success(.init(text: "DICTATED REQUEST:\n\nRaw", usedRawFallback: true))
        )
        XCTAssertTrue(pipelineFallback.usedRaw)
    }

    func testCodexPromptInstructionsAreFidelityFirstAndAdaptive() {
        let instructions = FidelityInstructions.generator(mode: .structured)

        XCTAssertTrue(instructions.contains("Semantic fidelity is more important than brevity"))
        XCTAssertTrue(instructions.contains("secondary requirement"))
        XCTAssertTrue(instructions.contains("Always include TASK"))
        XCTAssertTrue(instructions.contains("CURRENT BEHAVIOR"))
        XCTAssertTrue(instructions.contains("REQUIREMENTS"))
        XCTAssertTrue(instructions.contains("CONSTRAINTS"))
        XCTAssertTrue(instructions.contains("NON-GOALS"))
        XCTAssertTrue(instructions.contains("ACCEPTANCE CRITERIA"))
        XCTAssertTrue(instructions.contains("OPEN QUESTIONS"))
        XCTAssertTrue(instructions.contains("Never emit empty sections"))
        XCTAssertTrue(instructions.contains("Do not invent features"))
    }

    func testCleanTranscriptInstructionsDoNotForceCodexSections() {
        let instructions = FidelityInstructions.generator(mode: .clean)

        XCTAssertTrue(instructions.contains("Preserve natural paragraph structure"))
        XCTAssertFalse(instructions.contains("Always include a TASK: section"))
        XCTAssertFalse(instructions.contains("preferably in this order: CONTEXT"))
    }

    func testStructuredResponseUsesStrictSchemaTerraAndDynamicBudget() async throws {
        let output = #"{"normalized_transcript":"Preserve every detail."}"#
        let transport = QueueTransport(stubs: [
            .init(status: 200, data: structuredResponseData(json: output))
        ])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })

        let response: NormalizedTranscriptResponse = try await client.structuredResponse(
            stage: .normalization,
            instructions: "Normalize faithfully",
            input: String(repeating: "x", count: 10_000),
            schema: FidelityJSONSchemas.normalization,
            apiKey: "test-key"
        )

        XCTAssertEqual(response.normalizedTranscript, "Preserve every detail.")
        let capturedRequest = await transport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(json["max_output_tokens"] as? Int, 9_096)
        let format = ((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(format?["name"] as? String, "codex_dictate_normalization")
        XCTAssertNotNil(format?["schema"] as? [String: Any])
    }

    func testStructuredResponseRetriesIncompleteResponseExactlyOnce() async throws {
        let transport = QueueTransport(stubs: [
            .init(status: 200, data: incompleteStructuredResponseData()),
            .init(status: 200, data: structuredResponseData(json: #"{"final_prompt":"TASK:\n\nKeep all details."}"#))
        ])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })

        let response: StructuredPromptResponse = try await client.structuredResponse(
            stage: .generation,
            instructions: "Generate faithfully",
            input: "input",
            schema: FidelityJSONSchemas.prompt,
            apiKey: "test-key"
        )

        XCTAssertEqual(response.finalPrompt, "TASK:\n\nKeep all details.")
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
    }

    func testStructuredResponseRejectsRepeatedMalformedOutput() async throws {
        let malformed = structuredResponseData(json: #"{"unexpected":"value"}"#)
        let transport = QueueTransport(stubs: [
            .init(status: 200, data: malformed),
            .init(status: 200, data: malformed)
        ])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })

        do {
            let _: StructuredPromptResponse = try await client.structuredResponse(
                stage: .generation,
                instructions: "Generate faithfully",
                input: "input",
                schema: FidelityJSONSchemas.prompt,
                apiKey: "test-key"
            )
            XCTFail("Expected malformed structured data to fail")
        } catch {
            XCTAssertEqual(error as? FidelityPipelineError, .malformedModelResponse)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
    }

    func testHTTPErrorMappingAndRetryPolicy() {
        XCTAssertEqual(OpenAIClient.mapHTTPError(response(status: 401)), .unauthorized)
        XCTAssertEqual(OpenAIClient.mapHTTPError(response(status: 403)), .forbidden)
        XCTAssertEqual(OpenAIClient.mapHTTPError(response(status: 404)), .notFound)
        XCTAssertEqual(OpenAIClient.mapHTTPError(response(status: 500)), .server(status: 500))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .unauthorized, attempt: 0))
        XCTAssertTrue(RetryPolicy.shouldRetry(error: .server(status: 503), attempt: 0))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .server(status: 503), attempt: 1))
    }

    func testClientRetriesTransientFailureExactlyOnce() async throws {
        let transport = QueueTransport(stubs: [
            .init(status: 500, data: Data()),
            .init(status: 200, data: Data(#"{"text":"Implement tests","languages":[{"code":"en"}]}"#.utf8))
        ])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })
        let file = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await client.transcribe(audioURL: file, prompt: "Context", keywords: ["Codex", "SwiftUI"], languages: ["en", "ru"], apiKey: "test-key")
        XCTAssertEqual(result.text, "Implement tests")
        let requestCount = await transport.requestCount
        let capturedRequest = await transport.lastRequest
        XCTAssertEqual(requestCount, 2)
        let request = try XCTUnwrap(capturedRequest)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "name=\"keywords[]\"").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: "name=\"languages[]\"").count - 1, 2)
        XCTAssertTrue(request.url?.path == "/v1/audio/transcriptions")
    }

    func testClientRetriesEmptyTranscriptionResponseExactlyOnce() async throws {
        let transport = QueueTransport(stubs: [
            .init(status: 200, data: Data(#"{"text":"","languages":[]}"#.utf8)),
            .init(status: 200, data: Data(#"{"text":"Recovered dictated task","languages":[{"code":"en"}]}"#.utf8))
        ])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })
        let file = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await client.transcribe(
            audioURL: file,
            prompt: "Context",
            keywords: [],
            languages: [],
            apiKey: "test-key"
        )

        XCTAssertEqual(result.text, "Recovered dictated task")
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testClientDoesNotRetryUnauthorizedRequest() async throws {
        let transport = QueueTransport(stubs: [.init(status: 401, data: Data())])
        let client = OpenAIClient(transport: transport, sleeper: { _ in })
        let file = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await client.transcribe(audioURL: file, prompt: "Context", keywords: [], languages: [], apiKey: "rejected")
            XCTFail("Expected unauthorized error")
        } catch {
            XCTAssertEqual(error as? OpenAIError, .unauthorized)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testClientRecordsSanitizedRequestTimelineWithoutContent() async throws {
        let transport = QueueTransport(stubs: [
            .init(status: 500, data: Data()),
            .init(status: 200, data: Data(#"{"text":"Private dictated content","languages":[{"code":"en"}]}"#.utf8))
        ])
        let diagnostics = DiagnosticStore()
        let sessionID = await diagnostics.beginSession(context: DiagnosticSessionContext(
            targetBundleIdentifier: "com.microsoft.VSCode",
            targetApplicationName: "Visual Studio Code",
            targetProcessIdentifier: 42,
            capturedWindow: true,
            capturedEditableElement: true,
            capturedCaret: false,
            capturedExactFocus: true,
            automaticPaste: true,
            restrictPasteToVSCode: true,
            formattingEnabled: false,
            formattingMode: StructuringMode.clean.rawValue,
            microphoneGranted: true,
            accessibilityGranted: true
        ))
        let client = OpenAIClient(transport: transport, diagnostics: diagnostics, sleeper: { _ in })
        let file = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await DiagnosticContext.$sessionID.withValue(sessionID) {
            try await client.transcribe(
                audioURL: file,
                prompt: "Private prompt context",
                keywords: ["PrivateKeyword"],
                languages: ["en"],
                apiKey: "sk-secret-api-key"
            )
        }

        let sessions = await diagnostics.snapshot()
        let events = try XCTUnwrap(sessions.first?.events)
        XCTAssertEqual(events.filter { $0.name == .httpResponse }.map(\.httpStatus), [500, 200])
        XCTAssertEqual(events.filter { $0.name == .retryScheduled }.count, 1)
        XCTAssertEqual(events.last { $0.name == .stageCompleted }?.characterCount, 24)
        let export = await diagnostics.exportJSON()
        XCTAssertFalse(export.contains("Private dictated content"))
        XCTAssertFalse(export.contains("Private prompt context"))
        XCTAssertFalse(export.contains("PrivateKeyword"))
        XCTAssertFalse(export.contains("sk-secret-api-key"))
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func structuredResponseData(json: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": json]]
            ]]
        ])
    }

    private func incompleteStructuredResponseData() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"],
            "output": []
        ])
    }
}

private actor QueueTransport: HTTPRequestTransport {
    struct Stub: Sendable {
        let status: Int
        let data: Data
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(stubs: [Stub]) { self.stubs = stubs }

    var requestCount: Int { requests.count }
    var lastRequest: URLRequest? { requests.last }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (stub.data, response)
    }
}
