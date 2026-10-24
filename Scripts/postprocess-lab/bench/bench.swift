import Foundation
import FoundationModels

/// Decomposes the clean-up call's latency: fixed overhead vs prefill vs
/// decode, cold vs prewarmed, guided vs plain output. One call at a time.
@main struct Bench {
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    enum Output: String { case generable, noSchema, string, stream, shortField, shortFieldNoSchema }

    @Generable struct Short: Sendable { let text: String }

    static let transcripts: [(String, String)] = [
        ("1w", "yeah"),
        ("8w", "can you check if whisper is still running"),
        ("100w", "so I just got off the call with the client and um basically they want to move the launch back by two weeks which I think is actually fine because we were never going to hit the original date anyway the main thing is that they want us to redo the onboarding flow so that new users see the pricing page before they create an account and I said we could probably get a first version of that done by the end of next week can you let the design team know and also um can you check whether the analytics events for the pricing page are actually firing because last time I looked they were not"),
    ]

    static func call(_ text: String, output: Output, prewarm: Bool, instructions: String?, wait: Duration) async throws -> (Double, Double?, String) {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = instructions.map { LanguageModelSession(model: model, instructions: $0) } ?? LanguageModelSession(model: model)
        if prewarm {
            session.prewarm(promptPrefix: Prompt { PostProcessor.promptPrefix })
            try await Task.sleep(for: wait)
        }
        let user = PostProcessor.prompt(for: text)
        let opts = GenerationOptions(sampling: .greedy)
        let t0 = ContinuousClock.now
        switch output {
        case .generable:
            let r = try await session.respond(to: user, generating: PostProcessor.CleanedTranscript.self, options: opts)
            return (ms(ContinuousClock.now - t0), nil, r.content.cleanedText)
        case .noSchema:
            let r = try await session.respond(to: user, generating: PostProcessor.CleanedTranscript.self, includeSchemaInPrompt: false, options: opts)
            return (ms(ContinuousClock.now - t0), nil, r.content.cleanedText)
        case .shortField:
            let r = try await session.respond(to: user, generating: Short.self, options: opts)
            return (ms(ContinuousClock.now - t0), nil, r.content.text)
        case .shortFieldNoSchema:
            let r = try await session.respond(to: user, generating: Short.self, includeSchemaInPrompt: false, options: opts)
            return (ms(ContinuousClock.now - t0), nil, r.content.text)
        case .string:
            let r = try await session.respond(to: user, options: opts)
            return (ms(ContinuousClock.now - t0), nil, r.content)
        case .stream:
            var first: Double?
            var last = ""
            for try await partial in session.streamResponse(to: user, generating: PostProcessor.CleanedTranscript.self, options: opts) {
                if first == nil, let t = partial.content.cleanedText, !t.isEmpty { first = ms(ContinuousClock.now - t0) }
                last = partial.content.cleanedText ?? last
            }
            return (ms(ContinuousClock.now - t0), first, last)
        }
    }

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let reps = Int(env["REPS"] ?? "5")!
        let wait = Duration.milliseconds(Int(env["PREWARM_MS"] ?? "1500")!)
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if #available(macOS 26.4, *) {
            let i = try await model.tokenCount(for: Instructions(PostProcessor.instructions))
            print("instructions tokens: \(i)")
            for (name, t) in transcripts {
                let p = try await model.tokenCount(for: Prompt(PostProcessor.prompt(for: t)))
                print("prompt tokens \(name): \(p)")
            }
            let s = try await model.tokenCount(for: PostProcessor.CleanedTranscript.generationSchema)
            print("schema tokens: \(s)")
        }
        // Warm-up.
        _ = try await call("hello", output: .generable, prewarm: false, instructions: PostProcessor.instructions, wait: wait)
        let only = env["CONFIGS"].map { Set($0.split(separator: ",").map(String.init)) }
        let configs: [(String, Output, Bool, String?)] = [
            ("shortField prewarm", .shortField, true, PostProcessor.instructions),
            ("shortFieldNoSchema prewarm", .shortFieldNoSchema, true, PostProcessor.instructions),
            ("generable cold", .generable, false, PostProcessor.instructions),
            ("generable prewarm", .generable, true, PostProcessor.instructions),
            ("noSchema cold", .noSchema, false, PostProcessor.instructions),
            ("noSchema prewarm", .noSchema, true, PostProcessor.instructions),
            ("string cold", .string, false, PostProcessor.instructions),
            ("string prewarm", .string, true, PostProcessor.instructions),
            ("stream prewarm", .stream, true, PostProcessor.instructions),
            ("string no-instr cold", .string, false, nil),
        ]
        print("config                   len    median ms   (ttft)   runs")
        for (name, output, prewarm, instr) in configs where only?.contains(name) ?? true {
            for (len, t) in transcripts {
                var totals: [Double] = [], ttfts: [Double] = []
                var sample = ""
                for _ in 0..<reps {
                    let (total, ttft, text) = try await call(t, output: output, prewarm: prewarm, instructions: instr, wait: wait)
                    totals.append(total); if let ttft { ttfts.append(ttft) }
                    sample = text
                }
                let tt = ttfts.isEmpty ? "" : String(format: "(%.0f)", median(ttfts))
                print(String(format: "%-24@ %-5@ %8.0f   %8@   %@", name as NSString, len as NSString, median(totals), tt as NSString, totals.map { String(format: "%.0f", $0) }.joined(separator: " ")))
                if len == "8w" { print("    -> \(sample.prefix(120))") }
            }
        }
    }
}
