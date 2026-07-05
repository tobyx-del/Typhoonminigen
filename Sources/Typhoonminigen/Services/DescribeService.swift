import Foundation
import CoreGraphics
import FluxTextEncoders

/// Describes reference images with the small Qwen3.5-VLM 4B (4-bit, ~3 GB) and returns
/// FLUX-ready prose (the engine ships a dedicated FLUX.2 description system prompt).
///
/// This is the SAFE replacement for the engine's Mistral-24B interpret path that froze
/// the 32 GB M4: download (once) → load → describe → unload. The VLM coexists with a
/// resident Klein (~3 GB on top) — no swap risk.
enum DescribeService {
    private static let preferenceKey = "preferredVLMVariant"

    /// The user's explicit pick from the Models tab ("Use" button), if any.
    private static var preferred: Qwen35Variant? {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Qwen35Variant.init(rawValue:))
    }

    /// Record which quantization to use for Describe / Auto-caption (the Models-tab "Use" action).
    static func setPreferred(_ variant: Qwen35Variant) {
        UserDefaults.standard.set(variant.rawValue, forKey: preferenceKey)
    }

    /// Which Qwen3.5-VLM quantization is ACTIVE: the user's explicit pick if that one is on disk;
    /// otherwise the higher-fidelity 8-bit when present, else the recommended 4-bit (also what
    /// auto-downloads when neither is present). Same vision model either way — a quality/size trade.
    static var variant: Qwen35Variant {
        if let pref = preferred, TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: pref) {
            return pref
        }
        return TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: .qwen35_4B_8bit)
            ? .qwen35_4B_8bit : .qwen35_4B_4bit
    }

    /// Either quantization on disk counts as available.
    static var isModelDownloaded: Bool {
        TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: .qwen35_4B_8bit)
            || TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: .qwen35_4B_4bit)
    }

    /// One source of truth for the VLM load/download status line (describe / ask / compare share it).
    private static var vlmLoadStatus: String {
        isModelDownloaded ? "Loading Qwen3.5-VLM…"
                          : "Downloading Qwen3.5-VLM (~3 GB, one time)…"
    }

    // MARK: - Workshop caption instructions (concept-type presets)

    /// Default auto-caption instruction per concept type, sent as the VLM SYSTEM prompt.
    /// Adapted from ai-toolkit's captioner prompt. Subject presets (object/pet/person) use the
    /// standard subject-LoRA trick — describe the scene/pose/lighting/context and name the subject
    /// only by its class word, so the LoRA (not the caption) owns the identity; the Style preset is
    /// the inverse. None of them mention the trigger word: captions are stored bare and the engine
    /// prepends the trigger at train time.
    static func captionInstruction(for conceptType: ConceptType) -> String {
        let voice = "Be decisive and concrete. Write one flowing paragraph of plain prose — "
            + "no preamble like \"This image shows\", no lists, no quotes. Output only the caption."
        switch conceptType {
        case .object:
            return "Caption this image as if the caption were used to generate it with an image model. "
                + "Describe the scene, the subject's pose and placement, the camera angle and framing, "
                + "the lighting and the background. Refer to the main subject only briefly by a simple "
                + "class word (for example \"a lamp\" or \"a mug\") — do not describe its brand, exact "
                + "colors or distinctive details; the model learns those from the pixels. " + voice
        case .pet:
            return "Caption this image as if the caption were used to generate it with an image model. "
                + "Describe the scene, the animal's pose and placement, the camera angle and framing, "
                + "the lighting and the background. Refer to the animal only briefly by a simple class "
                + "word (for example \"a dog\" or \"a cat\") — do not describe its breed, coloring or "
                + "distinctive markings; the model learns those from the pixels. " + voice
        case .person:
            return "Caption this image as if the caption were used to generate it with an image model. "
                + "Describe the scene, the person's pose and placement, the camera angle and framing, "
                + "the clothing, the lighting and the background. Refer to the person only briefly by a "
                + "simple class word (\"a person\", \"a woman\", \"a man\") — do not describe their face, "
                + "hair or distinctive features; the model learns those from the pixels. " + voice
        case .style:
            return "Caption this image as if the caption were used to generate it with an image model. "
                + "Describe only what is depicted — the subjects, objects, setting, composition and "
                + "camera angle. Do not describe the artistic style, medium, color palette or rendering "
                + "technique — the style itself must stay out of the caption. " + voice
        }
    }

    /// Download if needed, load, describe every image, then unload. Status strings are
    /// streamed to `onStatus`. The blocking inference runs OFF the main thread.
    ///
    /// - Parameter instruction: custom SYSTEM prompt (workshop auto-caption). When set, each image
    ///   goes through `analyzeImageWithQwen35` at temperature 0 — the same deterministic setting as
    ///   the describe path (the engine's default 0.7 would make batch captions nondeterministic).
    ///   nil → the engine's fixed FLUX.2 describe prompt, exactly as before.
    /// - Parameter onResult: fired after EACH image with (index into `images`, caption) so callers
    ///   can persist captions as they land instead of all-at-once at the end.
    static func describe(
        images: [CGImage],
        context: String?,
        instruction: String? = nil,
        onStatus: @escaping @Sendable (String) -> Void,
        onResult: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> [String] {
        onStatus(Self.vlmLoadStatus)
        let path = try await TextEncoderModelDownloader().downloadQwen35(variant: variant) { p, _ in
            if p < 1 { onStatus("Downloading Qwen3.5-VLM… \(Int(p * 100))%") }
        }
        try await FluxTextEncoders.shared.loadQwen35VLM(from: path.path)
        do {
            var out: [String] = []
            for (i, img) in images.enumerated() {
                // Honor a user Cancel between images (one image's inference itself is
                // uninterruptible, ~10-30 s; the download above cancels natively).
                try Task.checkCancellation()
                let noun = instruction == nil ? "reference" : "image"
                onStatus(images.count > 1 ? "Describing \(noun) \(i + 1) of \(images.count)…"
                                          : "Describing \(noun)…")
                // The inference is synchronous and heavy (~10–30 s) — keep it off-main
                // even if the caller awaited us from the MainActor.
                let result = try await Task.detached(priority: .userInitiated) { () throws -> GenerationResult in
                    if let instruction {
                        // Mirrors describeImageForFlux's shape: context (the workshop's concept
                        // description) is the user prompt; the instruction replaces the system prompt.
                        return try FluxTextEncoders.shared.analyzeImageWithQwen35(
                            image: img,
                            prompt: context ?? "Caption this image.",
                            systemPrompt: instruction,
                            maxTokens: 300,
                            temperature: 0)
                    }
                    return try FluxTextEncoders.shared.describeImageForFlux(image: img, context: context)
                }.value
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(text)
                onResult?(i, text)
            }
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            return out
        } catch {
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            throw error
        }
    }

    /// Parsed reference-vs-generated fidelity scores (app-side type so view models don't import the engine).
    struct ComparisonResult: Sendable {
        let sceneScore: Int
        let styleScore: Int
        let sceneReason: String
        let styleReason: String
    }

    /// Free-form question about ONE image (the VLM "ask anything" path): download → load → ask → unload.
    static func ask(
        about image: CGImage,
        question: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        onStatus(Self.vlmLoadStatus)
        let path = try await TextEncoderModelDownloader().downloadQwen35(variant: variant) { p, _ in
            if p < 1 { onStatus("Downloading Qwen3.5-VLM… \(Int(p * 100))%") }
        }
        try await FluxTextEncoders.shared.loadQwen35VLM(from: path.path)
        do {
            try Task.checkCancellation()
            onStatus("Thinking…")
            let result = try await Task.detached(priority: .userInitiated) {
                try FluxTextEncoders.shared.analyzeImageWithQwen35(image: image, prompt: question)
            }.value
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            throw error
        }
    }

    /// Score a generated image against its reference (FLUX.2 scene+style): download → load → compare → unload.
    static func compare(
        reference: CGImage,
        generated: CGImage,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> ComparisonResult {
        onStatus(Self.vlmLoadStatus)
        let path = try await TextEncoderModelDownloader().downloadQwen35(variant: variant) { p, _ in
            if p < 1 { onStatus("Downloading Qwen3.5-VLM… \(Int(p * 100))%") }
        }
        try await FluxTextEncoders.shared.loadQwen35VLM(from: path.path)
        do {
            try Task.checkCancellation()
            onStatus("Comparing to reference…")
            let c = try await Task.detached(priority: .userInitiated) {
                try FluxTextEncoders.shared.compareImagesForFlux(reference: reference, generated: generated)
            }.value
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            return ComparisonResult(sceneScore: c.sceneScore, styleScore: c.styleScore,
                                    sceneReason: c.sceneReason, styleReason: c.styleReason)
        } catch {
            await MainActor.run { FluxTextEncoders.shared.unloadQwen35VLM() }
            throw error
        }
    }
}
