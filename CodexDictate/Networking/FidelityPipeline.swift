import Foundation

protocol FidelityModelServicing: Sendable {
    func normalize(
        rawChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        apiKey: String
    ) async throws -> NormalizedTranscriptResponse

    func inventory(
        rawChunk: String,
        normalizedChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        protectedValues: [String],
        apiKey: String
    ) async throws -> SemanticInventoryResponse

    func generate(
        normalizedTranscript: String,
        semanticUnits: [SemanticUnit],
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse

    func verify(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        apiKey: String
    ) async throws -> FidelityVerificationResult

    func repair(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse
}

struct OpenAIFidelityModel: FidelityModelServicing {
    let client: OpenAIClient

    func normalize(
        rawChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        apiKey: String
    ) async throws -> NormalizedTranscriptResponse {
        try await client.structuredResponse(
            stage: .normalization,
            instructions: FidelityInstructions.normalization,
            input: try Self.jsonString(NormalizationInput(
                rawTranscriptChunk: rawChunk,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount
            )),
            schema: FidelityJSONSchemas.normalization,
            apiKey: apiKey
        )
    }

    func inventory(
        rawChunk: String,
        normalizedChunk: String,
        chunkIndex: Int,
        chunkCount: Int,
        protectedValues: [String],
        apiKey: String
    ) async throws -> SemanticInventoryResponse {
        try await client.structuredResponse(
            stage: .inventory,
            instructions: FidelityInstructions.inventory,
            input: try Self.jsonString(InventoryInput(
                rawTranscriptChunk: rawChunk,
                normalizedTranscriptChunk: normalizedChunk,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                protectedValues: protectedValues
            )),
            schema: FidelityJSONSchemas.inventory,
            apiKey: apiKey
        )
    }

    func generate(
        normalizedTranscript: String,
        semanticUnits: [SemanticUnit],
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse {
        try await client.structuredResponse(
            stage: .generation,
            instructions: FidelityInstructions.generator(mode: mode),
            input: try Self.jsonString(GenerationInput(
                normalizedTranscript: normalizedTranscript,
                semanticUnits: semanticUnits,
                protectedValues: protectedValues,
                formattingMode: mode.rawValue
            )),
            schema: FidelityJSONSchemas.prompt,
            apiKey: apiKey
        )
    }

    func verify(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        apiKey: String
    ) async throws -> FidelityVerificationResult {
        try await client.structuredResponse(
            stage: .verification,
            instructions: FidelityInstructions.verifier,
            input: try Self.jsonString(VerificationInput(
                rawTranscript: document.rawTranscript,
                normalizedTranscript: document.normalizedTranscript,
                semanticUnits: document.semanticUnits,
                finalPrompt: document.structuredPrompt,
                protectedValues: protectedValues
            )),
            schema: FidelityJSONSchemas.verification,
            apiKey: apiKey
        )
    }

    func repair(
        document: FidelityPipelineDocument,
        protectedValues: [String],
        mode: StructuringMode,
        apiKey: String
    ) async throws -> StructuredPromptResponse {
        try await client.structuredResponse(
            stage: .repair,
            instructions: FidelityInstructions.repair,
            input: try Self.jsonString(RepairInput(
                rawTranscript: document.rawTranscript,
                normalizedTranscript: document.normalizedTranscript,
                semanticUnits: document.semanticUnits,
                currentPrompt: document.structuredPrompt,
                verificationResult: document.verificationResult,
                exactRepairFindings: document.verificationResult.allRepairFindings,
                protectedValues: protectedValues,
                formattingMode: mode.rawValue
            )),
            schema: FidelityJSONSchemas.prompt,
            apiKey: apiKey
        )
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FidelityPipelineError.malformedModelResponse
        }
        return string
    }
}

struct TranscriptStructuringService: TranscriptStructuringServicing {
    let model: any FidelityModelServicing
    let chunker: TranscriptChunker
    let maximumRepairAttempts: Int
    let diagnostics: (any DiagnosticRecording)?

    init(
        model: any FidelityModelServicing,
        chunker: TranscriptChunker = TranscriptChunker(),
        maximumRepairAttempts: Int = 2,
        diagnostics: (any DiagnosticRecording)? = nil
    ) {
        self.model = model
        self.chunker = chunker
        self.maximumRepairAttempts = max(0, min(maximumRepairAttempts, 2))
        self.diagnostics = diagnostics
    }

    init(client: OpenAIClient, diagnostics: (any DiagnosticRecording)? = nil) {
        self.init(model: OpenAIFidelityModel(client: client), diagnostics: diagnostics)
    }

    func structure(
        transcript: String,
        mode: StructuringMode,
        apiKey: String
    ) async throws -> TranscriptStructuringResult {
        let rawTranscript = transcript
        var activeStage = DiagnosticStage.normalization
        do {
            let protected = ProtectedValueExtractor.extract(from: rawTranscript)
            let chunks = chunker.chunks(from: rawTranscript)
            guard !chunks.isEmpty else { throw FidelityPipelineError.emptyNormalizedTranscript }
            await record(DiagnosticEvent(
                name: .chunkPlan,
                stage: .normalization,
                outcome: .success,
                characterCount: rawTranscript.count,
                itemCount: chunks.count
            ))

            var normalizedChunks: [String] = []
            var allUnits: [SemanticUnit] = []
            for (offset, rawChunk) in chunks.enumerated() {
                let chunkIndex = offset + 1
                let localProtected = protected
                    .filter { rawChunk.localizedCaseInsensitiveContains($0.value) }
                    .map(\.value)
                activeStage = .normalization
                let normalized = try await model.normalize(
                    rawChunk: rawChunk,
                    chunkIndex: chunkIndex,
                    chunkCount: chunks.count,
                    apiKey: apiKey
                ).normalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw FidelityPipelineError.emptyNormalizedTranscript
                }
                normalizedChunks.append(normalized)

                activeStage = .inventory
                let inventory = try await model.inventory(
                    rawChunk: rawChunk,
                    normalizedChunk: normalized,
                    chunkIndex: chunkIndex,
                    chunkCount: chunks.count,
                    protectedValues: localProtected,
                    apiKey: apiKey
                )
                guard !inventory.semanticUnits.isEmpty else {
                    throw FidelityPipelineError.invalidSemanticInventory
                }
                allUnits.append(contentsOf: inventory.semanticUnits)
                await record(DiagnosticEvent(
                    name: .semanticInventory,
                    stage: .inventory,
                    outcome: .success,
                    attempt: chunkIndex,
                    itemCount: inventory.semanticUnits.count
                ))
            }

            let normalizedTranscript = normalizedChunks.joined(separator: "\n\n")
            var semanticUnits = try Self.validatedUnits(
                allUnits,
                protectedValues: protected
            )
            for index in semanticUnits.indices { semanticUnits[index].id = "U\(index + 1)" }

            activeStage = .generation
            let generated = try await model.generate(
                normalizedTranscript: normalizedTranscript,
                semanticUnits: semanticUnits,
                protectedValues: protected.map(\.value),
                mode: mode,
                apiKey: apiKey
            ).finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !generated.isEmpty else { throw FidelityPipelineError.invalidStructuredPrompt }

            var document = FidelityPipelineDocument(
                rawTranscript: rawTranscript,
                normalizedTranscript: normalizedTranscript,
                semanticUnits: semanticUnits,
                structuredPrompt: generated,
                verificationResult: .passing
            )

            for repairAttempt in 0...maximumRepairAttempts {
                activeStage = .verification
                var verification = try await model.verify(
                    document: document,
                    protectedValues: protected.map(\.value),
                    apiKey: apiKey
                )
                verification.mergeDeterministicFindings(
                    DeterministicFidelityVerifier.findings(
                        rawTranscript: rawTranscript,
                        finalPrompt: document.structuredPrompt,
                        protectedValues: protected
                    )
                )
                document.verificationResult = verification
                await record(DiagnosticEvent(
                    name: .verificationResult,
                    stage: .verification,
                    outcome: verification.passedStrictly ? .passed : .failed,
                    attempt: repairAttempt + 1,
                    itemCount: verification.allRepairFindings.count
                ))
                if verification.passedStrictly {
                    return TranscriptStructuringResult(
                        text: document.structuredPrompt,
                        usedRawFallback: false
                    )
                }
                guard repairAttempt < maximumRepairAttempts else { break }

                activeStage = .repair
                let repaired = try await model.repair(
                    document: document,
                    protectedValues: protected.map(\.value),
                    mode: mode,
                    apiKey: apiKey
                ).finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repaired.isEmpty else {
                    throw FidelityPipelineError.invalidStructuredPrompt
                }
                document.structuredPrompt = repaired
            }
        } catch {
            // Fidelity failures are deliberately fail-closed. The transcript itself is
            // preferable to a polished request with omitted or invented semantics.
            await record(DiagnosticEvent(
                name: .stageFailed,
                stage: activeStage,
                outcome: .fallback,
                errorCode: DiagnosticErrorSanitizer.code(for: error)
            ))
        }

        await record(DiagnosticEvent(
            name: .stageCompleted,
            stage: .generation,
            outcome: .fallback,
            characterCount: rawTranscript.count
        ))
        return TranscriptStructuringResult(
            text: FidelityFallback.prompt(rawTranscript: rawTranscript),
            usedRawFallback: true
        )
    }

    private func record(_ event: DiagnosticEvent) async {
        await diagnostics?.record(event, sessionID: DiagnosticContext.sessionID)
    }

    private static func validatedUnits(
        _ units: [SemanticUnit],
        protectedValues: [ProtectedValue]
    ) throws -> [SemanticUnit] {
        var result = units
        guard result.allSatisfy({
            !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.normalizedMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw FidelityPipelineError.invalidSemanticInventory
        }

        for protectedValue in protectedValues {
            var represented = false
            for index in result.indices where result[index].sourceText.localizedCaseInsensitiveContains(protectedValue.value)
                || result[index].normalizedMeaning.localizedCaseInsensitiveContains(protectedValue.value) {
                represented = true
                if !result[index].protectedValues.contains(protectedValue.value) {
                    result[index].protectedValues.append(protectedValue.value)
                }
            }
            guard represented else { throw FidelityPipelineError.invalidSemanticInventory }
        }
        return result
    }
}

struct TranscriptChunker: Sendable {
    let maximumCharacters: Int

    init(maximumCharacters: Int = 24_000) {
        self.maximumCharacters = max(64, maximumCharacters)
    }

    func chunks(from transcript: String) -> [String] {
        guard !transcript.isEmpty else { return [] }
        let characters = Array(transcript)
        guard characters.count > maximumCharacters else { return [transcript] }

        var result: [String] = []
        var start = 0
        while start < characters.count {
            var end = min(start + maximumCharacters, characters.count)
            if end < characters.count {
                let minimumBoundary = min(end, start + maximumCharacters / 2)
                if let safeBoundary = stride(from: end, through: minimumBoundary, by: -1)
                    .first(where: { isSafeBoundary(after: $0 - 1, characters: characters) }) {
                    end = safeBoundary
                } else if let forwardBoundary = (end..<min(characters.count, end + maximumCharacters / 2))
                    .first(where: { isSafeBoundary(after: $0, characters: characters) }) {
                    end = forwardBoundary + 1
                }
            }
            if end <= start { end = min(start + maximumCharacters, characters.count) }
            result.append(String(characters[start..<end]))
            start = end
        }
        return result
    }

    private func isSafeBoundary(after index: Int, characters: [Character]) -> Bool {
        guard characters.indices.contains(index) else { return false }
        let character = characters[index]
        if character == "\n" { return true }
        if character.isWhitespace { return true }
        guard ".!?;:".contains(character), index + 1 < characters.count else { return false }
        return characters[index + 1].isWhitespace
    }
}

struct ProtectedValue: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case url
        case path
        case repository
        case date
        case productName
        case quotedLabel
        case codeIdentifier
        case version
        case number
        case acronym
        case strongModality
    }

    let kind: Kind
    let value: String
    let requiresExactCase: Bool
}

enum ProtectedValueExtractor {
    static func extract(from text: String) -> [ProtectedValue] {
        var values: [ProtectedValue] = []
        append(pattern: #"https?://[^\s<>]+"#, kind: .url, text: text, into: &values)
        append(pattern: #"(?<![A-Za-z0-9])(?:~|/)[^\s,;]+"#, kind: .path, text: text, into: &values)
        append(pattern: #"[A-Za-z]:\\[^\s,;]+"#, kind: .path, text: text, into: &values)
        append(
            pattern: #"(?<![/A-Za-z0-9_.-])[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?![/A-Za-z0-9_.-])"#,
            kind: .repository,
            text: text,
            into: &values
        )
        append(pattern: #"\b(?:19|20)\d{2}-\d{2}-\d{2}\b"#, kind: .date, text: text, into: &values)
        append(
            pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:,\s*\d{4})?\b"#,
            kind: .date,
            text: text,
            into: &values
        )
        append(
            pattern: #"\b(?!(?:The|A|An)\s)[A-Z][A-Za-z0-9+.-]*(?:\s+[A-Z][A-Za-z0-9+.-]*){1,3}\b"#,
            kind: .productName,
            text: text,
            into: &values
        )
        append(
            pattern: #"\b(?:macOS|iOS|iPadOS|watchOS|tvOS|visionOS|Android|Windows|Linux)\b"#,
            kind: .productName,
            text: text,
            into: &values
        )
        append(pattern: #"[\"“][^\"”\n]+[\"”]"#, kind: .quotedLabel, text: text, into: &values)
        append(pattern: #"`[^`\n]+`"#, kind: .codeIdentifier, text: text, into: &values)
        append(pattern: #"\bv?\d+(?:\.\d+){1,4}\b"#, kind: .version, text: text, into: &values)
        append(pattern: #"\b\d+(?:[.,]\d+)?(?:\s?%|\s+percent)?\b"#, kind: .number, text: text, into: &values)
        append(pattern: #"\b[A-Z][A-Z0-9]{1,}\b"#, kind: .acronym, text: text, into: &values)
        append(
            pattern: #"(?i)\b(?:must not|must|do not|never|only|required|exactly|optional|preferred|permanent|temporary|investigate|possibly|probably|either|or)\b"#,
            kind: .strongModality,
            exactCase: false,
            text: text,
            into: &values
        )
        var seen = Set<String>()
        return values.filter {
            seen.insert("\($0.kind.rawValue)|\($0.value.lowercased())").inserted
        }
    }

    private static func append(
        pattern: String,
        kind: ProtectedValue.Kind,
        exactCase: Bool = true,
        text: String,
        into values: inout [ProtectedValue]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var value = String(text[matchRange])
            if kind == .url || kind == .path || kind == .repository {
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\""))
            }
            guard !value.isEmpty else { continue }
            values.append(ProtectedValue(kind: kind, value: value, requiresExactCase: exactCase))
        }
    }
}

enum DeterministicFidelityVerifier {
    static func findings(
        rawTranscript: String,
        finalPrompt: String,
        protectedValues: [ProtectedValue]? = nil
    ) -> [String] {
        let protectedValues = protectedValues ?? ProtectedValueExtractor.extract(from: rawTranscript)
        var findings: [String] = []
        for protectedValue in protectedValues {
            let represented: Bool
            if protectedValue.requiresExactCase {
                represented = finalPrompt.contains(protectedValue.value)
            } else {
                represented = finalPrompt.localizedCaseInsensitiveContains(protectedValue.value)
            }
            if !represented {
                findings.append("Missing or changed \(protectedValue.kind.rawValue): \(protectedValue.value)")
            }
        }
        findings.append(contentsOf: emptySectionFindings(in: finalPrompt))
        return findings
    }

    private static func emptySectionFindings(in prompt: String) -> [String] {
        let lines = prompt.components(separatedBy: .newlines)
        let headingPattern = try? NSRegularExpression(pattern: #"^[A-Z][A-Z -]+:$"#)
        var findings: [String] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard headingPattern?.firstMatch(in: line, range: range) != nil else { continue }
            var hasContent = false
            for candidate in lines[(index + 1)...] {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let candidateRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if headingPattern?.firstMatch(in: trimmed, range: candidateRange) != nil { break }
                hasContent = true
                break
            }
            if !hasContent { findings.append("Empty prompt section: \(line)") }
        }
        return findings
    }
}

private struct NormalizationInput: Encodable {
    let rawTranscriptChunk: String
    let chunkIndex: Int
    let chunkCount: Int

    enum CodingKeys: String, CodingKey {
        case rawTranscriptChunk = "raw_transcript_chunk"
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
    }
}

private struct InventoryInput: Encodable {
    let rawTranscriptChunk: String
    let normalizedTranscriptChunk: String
    let chunkIndex: Int
    let chunkCount: Int
    let protectedValues: [String]

    enum CodingKeys: String, CodingKey {
        case rawTranscriptChunk = "raw_transcript_chunk"
        case normalizedTranscriptChunk = "normalized_transcript_chunk"
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case protectedValues = "protected_values"
    }
}

private struct GenerationInput: Encodable {
    let normalizedTranscript: String
    let semanticUnits: [SemanticUnit]
    let protectedValues: [String]
    let formattingMode: String

    enum CodingKeys: String, CodingKey {
        case normalizedTranscript = "normalized_transcript"
        case semanticUnits = "semantic_units"
        case protectedValues = "protected_values"
        case formattingMode = "formatting_mode"
    }
}

private struct VerificationInput: Encodable {
    let rawTranscript: String
    let normalizedTranscript: String
    let semanticUnits: [SemanticUnit]
    let finalPrompt: String
    let protectedValues: [String]

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
        case normalizedTranscript = "normalized_transcript"
        case semanticUnits = "semantic_units"
        case finalPrompt = "final_prompt"
        case protectedValues = "protected_values"
    }
}

private struct RepairInput: Encodable {
    let rawTranscript: String
    let normalizedTranscript: String
    let semanticUnits: [SemanticUnit]
    let currentPrompt: String
    let verificationResult: FidelityVerificationResult
    let exactRepairFindings: [String]
    let protectedValues: [String]
    let formattingMode: String

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
        case normalizedTranscript = "normalized_transcript"
        case semanticUnits = "semantic_units"
        case currentPrompt = "current_prompt"
        case verificationResult = "verification_result"
        case exactRepairFindings = "exact_repair_findings"
        case protectedValues = "protected_values"
        case formattingMode = "formatting_mode"
    }
}
