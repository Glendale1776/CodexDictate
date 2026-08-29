import Foundation
import XCTest
@testable import CodexDictate

final class FidelityPipelineTests: XCTestCase {
    func testSuccessfulPipelineReturnsOnlyFinishedPrompt() async throws {
        let raw = "Please preserve the settings screen behavior and update its spacing."
        let prompt = "TASK:\n\nPreserve the settings screen behavior and update its spacing."
        let model = ScriptedFidelityModel(generatedPrompt: prompt)
        let service = TranscriptStructuringService(model: model)

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, prompt)
        XCTAssertFalse(result.usedRawFallback)
        XCTAssertFalse(result.text.contains("semantic_units"))
        XCTAssertFalse(result.text.contains("U1"))
        XCTAssertFalse(result.text.contains("repair_instructions"))
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.normalizeCount, 1)
        XCTAssertEqual(snapshot.inventoryCount, 1)
        XCTAssertEqual(snapshot.generateCount, 1)
        XCTAssertEqual(snapshot.verifyCount, 1)
        XCTAssertEqual(snapshot.repairCount, 0)
    }

    func testDeterministicProtectedValueLossForcesRepairEvenWhenModelPasses() async throws {
        let raw = "Update /Users/franklin/App.swift for API v2.4 and keep `retryCount` at 15."
        let incomplete = "TASK:\n\nUpdate the application for API v2.4 and keep `retryCount` at 15."
        let repaired = "TASK:\n\nUpdate /Users/franklin/App.swift for API v2.4 and keep `retryCount` at 15."
        let model = ScriptedFidelityModel(
            generatedPrompt: incomplete,
            repairPrompts: [repaired],
            verifications: [.passing, .passing]
        )
        let service = TranscriptStructuringService(model: model)

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, repaired)
        XCTAssertFalse(result.usedRawFallback)
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.repairCount, 1)
        XCTAssertTrue(snapshot.repairFindings.joined().contains("/Users/franklin/App.swift"))
    }

    func testVerifierIssuesDriveTargetedRepair() async throws {
        let raw = "The screen flashes. Investigate whether the cache is stale; it is possibly caused by the renderer."
        let generated = "TASK:\n\nReplace the renderer."
        let repaired = "CURRENT BEHAVIOR:\n\nThe screen flashes.\n\nTASK:\n\nInvestigate whether the cache is stale; it is possibly caused by the renderer."
        let failure = FidelityVerificationResult(
            pass: false,
            omissions: ["The screen currently flashes."],
            partialCoverage: ["The cause remains uncertain."],
            distortions: ["An investigation became an implementation command."],
            unsupportedAdditions: ["Replace the renderer."],
            protectedValueErrors: [],
            repairInstructions: ["Preserve investigate and possibly as uncertain wording."]
        )
        let model = ScriptedFidelityModel(
            generatedPrompt: generated,
            repairPrompts: [repaired],
            verifications: [failure, .passing]
        )
        let service = TranscriptStructuringService(model: model)

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, repaired)
        XCTAssertFalse(result.text.contains("verification_result"))
        let snapshot = await model.snapshot()
        let findings = snapshot.repairFindings.joined(separator: " ")
        XCTAssertTrue(findings.contains("Restore omitted detail"))
        XCTAssertTrue(findings.contains("Remove unsupported addition"))
        XCTAssertTrue(findings.contains("Correct distortion"))
    }

    func testTwoFailedRepairsFallBackToExactRawTranscriptEnvelope() async throws {
        let raw = "Keep every secondary behavior and do not add a new button."
        let failure = FidelityVerificationResult(
            pass: false,
            omissions: ["A meaningful detail is missing."],
            partialCoverage: [],
            distortions: [],
            unsupportedAdditions: [],
            protectedValueErrors: [],
            repairInstructions: []
        )
        let model = ScriptedFidelityModel(
            generatedPrompt: "TASK:\n\nKeep behavior.",
            repairPrompts: ["TASK:\n\nKeep behavior.", "TASK:\n\nKeep behavior."],
            verifications: [failure, failure, failure]
        )
        let service = TranscriptStructuringService(model: model, maximumRepairAttempts: 2)

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, "DICTATED REQUEST:\n\n\(raw)")
        XCTAssertTrue(result.usedRawFallback)
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.verifyCount, 3)
        XCTAssertEqual(snapshot.repairCount, 2)
    }

    func testInvalidGenerationFailsClosedToRawTranscript() async throws {
        let raw = "Retain the complete request."
        let model = ScriptedFidelityModel(generatedPrompt: "   ")
        let service = TranscriptStructuringService(model: model)

        let result = try await service.structure(transcript: raw, mode: .clean, apiKey: "test-key")

        XCTAssertEqual(result.text, "DICTATED REQUEST:\n\n\(raw)")
        XCTAssertTrue(result.usedRawFallback)
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.verifyCount, 0)
    }

    func testRepeatedStructuringAlwaysStartsFromOriginalTranscript() async throws {
        let raw = "Preserve the primary request and its secondary requirement."
        let prompt = "TASK:\n\nPreserve the primary request and its secondary requirement."
        let model = ScriptedFidelityModel(generatedPrompt: prompt)
        let service = TranscriptStructuringService(model: model)

        let first = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")
        let second = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(first, second)
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.rawChunks, [raw, raw])
        XCTAssertEqual(snapshot.generateCount, 2)
    }

    func testChunkerPartitionsLongTranscriptWithoutLossOrOverlap() {
        let raw = (1...80).map { "Sentence \($0) keeps its detail. " }.joined()
        let chunks = TranscriptChunker(maximumCharacters: 100).chunks(from: raw)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), raw)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testLongPipelineNormalizesAndInventoriesEveryChunk() async throws {
        let raw = (1...45).map { "Requirement \($0) remains represented. " }.joined()
        let model = ScriptedFidelityModel(generatedPrompt: raw)
        let service = TranscriptStructuringService(
            model: model,
            chunker: TranscriptChunker(maximumCharacters: 90)
        )

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(result.usedRawFallback)
        let snapshot = await model.snapshot()
        XCTAssertGreaterThan(snapshot.normalizeCount, 1)
        XCTAssertEqual(snapshot.normalizeCount, snapshot.inventoryCount)
        XCTAssertEqual(snapshot.rawChunks.joined(), raw)
    }

    func testProtectedValueExtractorAndVerifierKeepExactTechnicalData() {
        let raw = #"Use https://example.com/v1 from openai/codex on 2026-08-24 in Reading Assistant and Android at /tmp/App.swift with `retryCount`, API v3.2, 95 percent, and the label "Send Now"; it must not be renamed."#
        let values = ProtectedValueExtractor.extract(from: raw)
        let extracted = Set(values.map(\.value))

        XCTAssertTrue(extracted.contains("https://example.com/v1"))
        XCTAssertTrue(extracted.contains("openai/codex"))
        XCTAssertTrue(extracted.contains("2026-08-24"))
        XCTAssertTrue(extracted.contains("Reading Assistant"))
        XCTAssertTrue(extracted.contains("Android"))
        XCTAssertTrue(extracted.contains("/tmp/App.swift"))
        XCTAssertTrue(extracted.contains("`retryCount`"))
        XCTAssertTrue(extracted.contains("API"))
        XCTAssertTrue(extracted.contains("v3.2"))
        XCTAssertTrue(extracted.contains("95 percent"))
        XCTAssertTrue(extracted.contains(#""Send Now""#))
        XCTAssertTrue(extracted.contains("must not"))

        let changed = raw.replacingOccurrences(of: "/tmp/App.swift", with: "/tmp/App2.swift")
        let findings = DeterministicFidelityVerifier.findings(
            rawTranscript: raw,
            finalPrompt: changed,
            protectedValues: values
        )
        XCTAssertTrue(findings.contains { $0.contains("/tmp/App.swift") })
    }

    func testEmptyPromptSectionsFailDeterministicVerification() {
        let prompt = "TASK:\n\nImplement the requested behavior.\n\nCONSTRAINTS:\n\nNON-GOALS:\n\nDo not redesign the UI."
        let findings = DeterministicFidelityVerifier.findings(
            rawTranscript: "Implement the requested behavior.",
            finalPrompt: prompt,
            protectedValues: []
        )

        XCTAssertEqual(findings, ["Empty prompt section: CONSTRAINTS:"])
    }

    func testReadingAssistantVagueSummariesAreRejected() async throws {
        let raw = Self.readingAssistantFixture
        let vagueSummaries = [
            "Fix the dialogue layout.",
            "Preserve it as closely as possible.",
            "Improve readability.",
            "Keep names on the left."
        ]
        let verificationFailure = FidelityVerificationResult(
            pass: false,
            omissions: ["The summary omits multiple independent dialogue-layout behaviors."],
            partialCoverage: [],
            distortions: [],
            unsupportedAdditions: [],
            protectedValueErrors: [],
            repairInstructions: []
        )

        for summary in vagueSummaries {
            let model = ScriptedFidelityModel(
                generatedPrompt: summary,
                verifications: [verificationFailure]
            )
            let service = TranscriptStructuringService(model: model, maximumRepairAttempts: 0)
            let result = try await service.structure(
                transcript: raw,
                mode: .structured,
                apiKey: "test-key"
            )

            XCTAssertNotEqual(result.text, summary)
            XCTAssertEqual(result.text, "DICTATED REQUEST:\n\n\(raw)")
            XCTAssertTrue(result.usedRawFallback)
        }
    }

    func testSemanticPreservationFixtureKeepsModalityRelationshipsAndExamples() async throws {
        let raw = """
        The Android screen currently places the optional badge above the title. Only modify Android; never change iOS. First investigate whether `layoutMode` is stale, then either repair the existing layout or document both alternatives if no choice is supported. The badge must remain optional, and it must not become mandatory. When compact mode is active, keep the title on one line except when accessibility text is enlarged. For example, a two-line title at 200 percent is acceptable. Do not add a button. This preserves the reading order.
        """
        let prompt = """
        CONTEXT:

        The Android screen currently places the optional badge above the title.

        TASK:

        - Only modify Android; never change iOS.
        - First investigate whether `layoutMode` is stale, then either repair the existing layout or document both alternatives if no choice is supported.

        REQUIREMENTS:

        - The badge must remain optional and must not become mandatory.
        - When compact mode is active, keep the title on one line except when accessibility text is enlarged.

        EXAMPLES:

        - A two-line title at 200 percent is acceptable when accessibility text is enlarged.

        CONSTRAINTS:

        - Do not add a button.
        - Preserve the reading order.
        """
        let model = ScriptedFidelityModel(generatedPrompt: prompt)
        let service = TranscriptStructuringService(model: model)

        let result = try await service.structure(transcript: raw, mode: .structured, apiKey: "test-key")

        XCTAssertEqual(result.text, prompt)
        XCTAssertFalse(result.usedRawFallback)
        for protectedValue in ProtectedValueExtractor.extract(from: raw) {
            if protectedValue.requiresExactCase {
                XCTAssertTrue(result.text.contains(protectedValue.value), "Missing \(protectedValue.value)")
            } else {
                XCTAssertTrue(result.text.localizedCaseInsensitiveContains(protectedValue.value), "Missing \(protectedValue.value)")
            }
        }
    }

    private static let readingAssistantFixture = """
    Dialogue selections contain participant names positioned on the left. Dialogue text is not necessarily placed beneath or assigned to a specific participant name. The current Reading Assistant rendering flattens the content into a single line. Participant names are visually placed on the same line as the beginning of the dialogue. Continuing or wrapped dialogue can then appear beneath the participant-name area. Preserve the original dialogue structure during progressive revealing. Participant names must remain on the left. Dialogue must not be incorrectly associated with a participant. The content must not be flattened into one line. The original line structure and visual relationship must remain stable.
    """
}

private actor ScriptedFidelityModel: FidelityModelServicing {
    struct Snapshot: Sendable {
        let rawChunks: [String]
        let normalizeCount: Int
        let inventoryCount: Int
        let generateCount: Int
        let verifyCount: Int
        let repairCount: Int
        let repairFindings: [String]
    }

    private let generatedPrompt: String
    private var repairPrompts: [String]
    private var verifications: [FidelityVerificationResult]
    private var rawChunks: [String] = []
    private var normalizeCount = 0
    private var inventoryCount = 0
    private var generateCount = 0
    private var verifyCount = 0
    private var repairCount = 0
    private var repairFindings: [String] = []

    init(
        generatedPrompt: String,
        repairPrompts: [String] = [],
        verifications: [FidelityVerificationResult] = [.passing]
    ) {
        self.generatedPrompt = generatedPrompt
        self.repairPrompts = repairPrompts
        self.verifications = verifications
    }

    func normalize(
        rawChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        apiKey: String
    ) async throws -> NormalizedTranscriptResponse {
        rawChunks.append(rawChunk)
        normalizeCount += 1
        return NormalizedTranscriptResponse(normalizedTranscript: rawChunk)
    }

    func inventory(
        rawChunk: String,
        normalizedChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        protectedValues: [String],
        apiKey: String
    ) async throws -> SemanticInventoryResponse {
        inventoryCount += 1
        return SemanticInventoryResponse(semanticUnits: [
            SemanticUnit(
                id: "chunk-\(chunkIndex)",
                category: .requirement,
                sourceText: rawChunk,
                normalizedMeaning: normalizedChunk,
                modality: .fact,
                protectedValues: protectedValues
            )
        ])
    }

    func generate(
        normalizedTranscript: String,
        semanticUnits: [SemanticUnit],
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse {
        generateCount += 1
        return StructuredPromptResponse(finalPrompt: generatedPrompt)
    }

    func verify(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        apiKey: String
    ) async throws -> FidelityVerificationResult {
        verifyCount += 1
        return verifications.isEmpty ? .passing : verifications.removeFirst()
    }

    func repair(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse {
        repairCount += 1
        repairFindings.append(contentsOf: document.verificationResult.allRepairFindings)
        let prompt = repairPrompts.isEmpty ? document.structuredPrompt : repairPrompts.removeFirst()
        return StructuredPromptResponse(finalPrompt: prompt)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            rawChunks: rawChunks,
            normalizeCount: normalizeCount,
            inventoryCount: inventoryCount,
            generateCount: generateCount,
            verifyCount: verifyCount,
            repairCount: repairCount,
            repairFindings: repairFindings
        )
    }
}
