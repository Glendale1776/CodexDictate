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

    func testStructuringFallbackPreservesSuccessfulTranscript() {
        let failed = StructuringFallback.result(rawTranscript: "Raw details", structuredResult: .failure(OpenAIError.server(status: 500)))
        XCTAssertEqual(failed.text, "Raw details")
        XCTAssertTrue(failed.usedRaw)

        let succeeded = StructuringFallback.result(rawTranscript: "Raw", structuredResult: .success("  Cleaned  "))
        XCTAssertEqual(succeeded.text, "Cleaned")
        XCTAssertFalse(succeeded.usedRaw)
    }

    func testCodexPromptInstructionsUseAdaptiveSectionsWithoutInventingContent() {
        let instructions = StructuringInstructions.text(for: .structured)

        XCTAssertTrue(instructions.contains("Always include a TASK: section"))
        XCTAssertTrue(instructions.contains("Add CONTEXT: before TASK: only when"))
        XCTAssertTrue(instructions.contains("REQUIREMENTS:"))
        XCTAssertTrue(instructions.contains("CONSTRAINTS:"))
        XCTAssertTrue(instructions.contains("ACCEPTANCE CRITERIA:"))
        XCTAssertTrue(instructions.contains("Never create an empty section, invent missing content"))
        XCTAssertTrue(instructions.contains("A short direct request should remain short"))
    }

    func testCleanTranscriptInstructionsDoNotForceCodexSections() {
        let instructions = StructuringInstructions.text(for: .clean)

        XCTAssertTrue(instructions.contains("preserve the transcript's natural paragraph structure"))
        XCTAssertFalse(instructions.contains("Always include a TASK: section"))
        XCTAssertFalse(instructions.contains("Add CONTEXT: before TASK:"))
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

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
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
