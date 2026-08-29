import Foundation

enum SemanticCategory: String, Codable, CaseIterable, Sendable {
    case context
    case currentBehavior = "current_behavior"
    case problem
    case task
    case requirement
    case prohibition
    case constraint
    case nonGoal = "non_goal"
    case example
    case rationale
    case uncertainty
    case alternative
    case acceptance
}

enum SemanticModality: String, Codable, CaseIterable, Sendable {
    case fact
    case must
    case mustNot = "must_not"
    case should
    case may
    case uncertain
    case question
}

struct SemanticUnit: Codable, Equatable, Sendable {
    var id: String
    let category: SemanticCategory
    let sourceText: String
    let normalizedMeaning: String
    let modality: SemanticModality
    var protectedValues: [String]

    enum CodingKeys: String, CodingKey {
        case id, category, modality
        case sourceText = "source_text"
        case normalizedMeaning = "normalized_meaning"
        case protectedValues = "protected_values"
    }
}

struct NormalizedTranscriptResponse: Codable, Equatable, Sendable {
    let normalizedTranscript: String

    enum CodingKeys: String, CodingKey {
        case normalizedTranscript = "normalized_transcript"
    }
}

struct SemanticInventoryResponse: Codable, Equatable, Sendable {
    let semanticUnits: [SemanticUnit]

    enum CodingKeys: String, CodingKey {
        case semanticUnits = "semantic_units"
    }
}

struct StructuredPromptResponse: Codable, Equatable, Sendable {
    let finalPrompt: String

    enum CodingKeys: String, CodingKey {
        case finalPrompt = "final_prompt"
    }
}

struct FidelityVerificationResult: Codable, Equatable, Sendable {
    var pass: Bool
    var omissions: [String]
    var partialCoverage: [String]
    var distortions: [String]
    var unsupportedAdditions: [String]
    var protectedValueErrors: [String]
    var repairInstructions: [String]

    enum CodingKeys: String, CodingKey {
        case pass, omissions, distortions
        case partialCoverage = "partial_coverage"
        case unsupportedAdditions = "unsupported_additions"
        case protectedValueErrors = "protected_value_errors"
        case repairInstructions = "repair_instructions"
    }

    static let passing = FidelityVerificationResult(
        pass: true,
        omissions: [],
        partialCoverage: [],
        distortions: [],
        unsupportedAdditions: [],
        protectedValueErrors: [],
        repairInstructions: []
    )

    var hasNoIssues: Bool {
        omissions.isEmpty
            && partialCoverage.isEmpty
            && distortions.isEmpty
            && unsupportedAdditions.isEmpty
            && protectedValueErrors.isEmpty
    }

    var passedStrictly: Bool { pass && hasNoIssues }

    var allRepairFindings: [String] {
        repairInstructions
            + omissions.map { "Restore omitted detail: \($0)" }
            + partialCoverage.map { "Fully represent partial detail: \($0)" }
            + distortions.map { "Correct distortion: \($0)" }
            + unsupportedAdditions.map { "Remove unsupported addition: \($0)" }
            + protectedValueErrors.map { "Restore exact protected value: \($0)" }
    }

    mutating func mergeDeterministicFindings(_ findings: [String]) {
        for finding in findings where !protectedValueErrors.contains(finding) {
            protectedValueErrors.append(finding)
        }
        if !findings.isEmpty { pass = false }
        if !hasNoIssues { pass = false }
    }
}

struct TranscriptStructuringResult: Equatable, Sendable {
    let text: String
    let usedRawFallback: Bool
}

struct FidelityPipelineDocument: Equatable, Sendable {
    let rawTranscript: String
    let normalizedTranscript: String
    let semanticUnits: [SemanticUnit]
    var structuredPrompt: String
    var verificationResult: FidelityVerificationResult
}

enum FidelityFallback {
    static func prompt(rawTranscript: String) -> String {
        "DICTATED REQUEST:\n\n\(rawTranscript)"
    }
}

enum FidelityPipelineError: LocalizedError, Equatable, Sendable {
    case emptyNormalizedTranscript
    case invalidSemanticInventory
    case invalidStructuredPrompt
    case incompleteModelResponse
    case malformedModelResponse

    var errorDescription: String? {
        switch self {
        case .emptyNormalizedTranscript: "Normalization returned no transcript"
        case .invalidSemanticInventory: "Semantic inventory was incomplete"
        case .invalidStructuredPrompt: "Prompt generation returned no prompt"
        case .incompleteModelResponse: "OpenAI returned an incomplete structured response"
        case .malformedModelResponse: "OpenAI returned malformed structured data"
        }
    }
}

enum FidelityStage: String, Sendable {
    case normalization
    case inventory
    case generation
    case verification
    case repair
}

indirect enum JSONSchemaValue: Encodable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case array([JSONSchemaValue])
    case object([String: JSONSchemaValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum FidelityJSONSchemas {
    static let normalization = object(
        properties: ["normalized_transcript": string()],
        required: ["normalized_transcript"]
    )

    static let inventory = object(
        properties: [
            "semantic_units": array(items: object(
                properties: [
                    "id": string(),
                    "category": string(enumValues: SemanticCategory.allCases.map(\.rawValue)),
                    "source_text": string(),
                    "normalized_meaning": string(),
                    "modality": string(enumValues: SemanticModality.allCases.map(\.rawValue)),
                    "protected_values": array(items: string())
                ],
                required: [
                    "id", "category", "source_text", "normalized_meaning",
                    "modality", "protected_values"
                ]
            ))
        ],
        required: ["semantic_units"]
    )

    static let prompt = object(
        properties: ["final_prompt": string()],
        required: ["final_prompt"]
    )

    static let verification = object(
        properties: [
            "pass": .object(["type": .string("boolean")]),
            "omissions": array(items: string()),
            "partial_coverage": array(items: string()),
            "distortions": array(items: string()),
            "unsupported_additions": array(items: string()),
            "protected_value_errors": array(items: string()),
            "repair_instructions": array(items: string())
        ],
        required: [
            "pass", "omissions", "partial_coverage", "distortions",
            "unsupported_additions", "protected_value_errors", "repair_instructions"
        ]
    )

    private static func string(enumValues: [String]? = nil) -> JSONSchemaValue {
        var schema: [String: JSONSchemaValue] = ["type": .string("string")]
        if let enumValues { schema["enum"] = .array(enumValues.map(JSONSchemaValue.string)) }
        return .object(schema)
    }

    private static func array(items: JSONSchemaValue) -> JSONSchemaValue {
        .object(["type": .string("array"), "items": items])
    }

    private static func object(
        properties: [String: JSONSchemaValue],
        required: [String]
    ) -> JSONSchemaValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONSchemaValue.string)),
            "additionalProperties": .bool(false)
        ])
    }
}
