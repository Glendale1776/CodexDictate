import Foundation

protocol TranscriptionServicing: Sendable {
    func transcribe(audioURL: URL, keywords: [String], languages: [String], apiKey: String) async throws -> TranscriptionResult
}

protocol TranscriptStructuringServicing: Sendable {
    func structure(transcript: String, mode: StructuringMode, apiKey: String) async throws -> String
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

struct TranscriptStructuringService: TranscriptStructuringServicing {
    let client: OpenAIClient

    func structure(transcript: String, mode: StructuringMode, apiKey: String) async throws -> String {
        try await client.structure(transcript: transcript, mode: mode, apiKey: apiKey)
    }
}

enum StructuringInstructions {
    static func text(for mode: StructuringMode) -> String {
        let formattingRules = switch mode {
        case .clean:
            """
            Formatting mode — Clean transcript:
            - Use lists only when the speaker explicitly requested one.
            - Otherwise preserve the transcript's natural paragraph structure.
            - Do not add section headings unless the speaker explicitly dictated them.
            """
        case .structured:
            """
            Formatting mode — Codex prompt:
            - Produce a lean, outcome-focused prompt for Codex.
            - Always include a TASK: section. Put the heading on its own line and start its content on the next line.
            - Add CONTEXT: before TASK: only when the transcript contains background, the current situation, an existing behavior, or a reason for the change.
            - Add only the other sections that the transcript genuinely supports. After TASK:, use this order: REQUIREMENTS:, CONSTRAINTS:, ACCEPTANCE CRITERIA:, REFERENCES:.
            - Use the exact uppercase headings shown above, each followed by a colon and placed on its own line.
            - Never create an empty section, invent missing content, or add generic boilerplate.
            - Put distinct requirements and constraints into concise bullets. Use numbered steps only when order matters.
            - Treat explicit “must,” “must not,” permission, compatibility, safety, and scope boundaries as CONSTRAINTS: when separating them improves clarity.
            - Treat explicit tests, observable outcomes, and definitions of done as ACCEPTANCE CRITERIA: when separating them improves clarity.
            - Preserve mentioned files, paths, screenshots, URLs, logs, and other supplied materials under REFERENCES: only when that grouping is useful.
            - A short direct request should remain short: TASK: plus the request is sufficient.
            """
        }
        return """
        You are a transcription editor for dictated prompts sent to an AI coding assistant.

        Transform the raw speech transcript into clear written instructions.

        Rules:
        1. Preserve the speaker’s exact intent, requirements, facts, constraints, and language.
        2. Do not answer the request.
        3. Do not add suggestions, explanations, requirements, or information.
        4. Remove filler words, stutters, accidental repetitions, and abandoned sentence fragments.
        5. Resolve obvious spoken self-corrections when the intended replacement is clear.
        6. Correct punctuation, capitalization, and obvious transcription mistakes only when well supported.
        7. Divide distinct ideas into concise paragraphs.
        8. Apply the selected formatting mode below.
        9. Interpret explicit formatting phrases such as “new paragraph,” “bullet point,” and “numbered list.”
        10. Preserve code, terminal commands, URLs, file paths, identifiers, model names, product names, acronyms, numerical values, and version numbers.
        11. Preserve English technical terminology used inside another language.
        12. Do not translate unless the speaker explicitly requests translation.
        13. Do not summarize away details or soften requirements.
        14. Do not place the whole result inside quotation marks or a Markdown code fence.
        15. Return only the edited text.
        16. Do not add a final instruction to submit, send, or execute the prompt.

        \(formattingRules)
        """
    }
}
