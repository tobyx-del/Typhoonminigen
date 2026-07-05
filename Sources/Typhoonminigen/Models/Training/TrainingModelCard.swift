import Foundation

/// The model card snapshotted when a checkpoint is PUBLISHED: the full recipe, the loss series
/// and the checkpoint's validation images, copied out of the run's output dir at publish time —
/// deleting the run later deletes that dir, so everything the card needs must live with the
/// published adapter, not be referenced. One card per library file, replaced on republish
/// (mirrors the one-published-LoRA-per-run semantics).
struct TrainingModelCard: Codable, Sendable {
    struct ValidationEntry: Codable, Sendable {
        var fileName: String     // image file inside the card folder (copied at publish)
        var prompt: String       // resolved prompt text — trigger placed exactly as trained
    }

    var libraryFileName: String  // the published .safetensors name this card belongs to
    var runID: String
    var runName: String
    var workshopName: String?
    var trigger: String
    var tier: String             // ModelTier.rawValue
    var conceptType: String?
    var publishedStep: Int?      // nil = the final adapter
    var maxSteps: Int
    var rank: Int
    var alpha: Float
    var learningRate: Float
    var resolution: Int
    var imageCount: Int
    var dopEnabled: Bool
    var dopClass: String?
    var mirrored: Bool?          // flip-X augmentation was on at forge time
    var lossHistory: [Float]     // downsampled loss series for the curve snapshot
    var validation: [ValidationEntry]
    var validationStep: Int?     // which checkpoint the images came from (final adapter → newest)
    var trainedAt: Date?
    var publishedAt: Date
}

/// Owns the per-adapter card folders under `LoRAs/.cards/<fileName>/` (card.json + the copied
/// validation PNGs). Plain static file IO — cards are KBs of JSON plus a handful of small PNGs.
/// The dot-prefixed folder is invisible to `LoRAStore.discover()`.
enum ModelCardStore {
    static func dir(forLibraryFile name: String) -> URL {
        AppPaths.loraCards.appendingPathComponent(name, isDirectory: true)
    }

    static func cardURL(forLibraryFile name: String) -> URL {
        dir(forLibraryFile: name).appendingPathComponent("card.json")
    }

    static func exists(forLibraryFile name: String) -> Bool {
        FileManager.default.fileExists(atPath: cardURL(forLibraryFile: name).path)
    }

    static func load(forLibraryFile name: String) -> TrainingModelCard? {
        guard let data = try? Data(contentsOf: cardURL(forLibraryFile: name)) else { return nil }
        return try? JSONDecoder().decode(TrainingModelCard.self, from: data)
    }

    /// Write the card + copy its validation images in. REPLACES any previous card for the same
    /// library file (republish semantics). File IO — call OFF the main actor.
    static func write(_ card: TrainingModelCard, copyingImages images: [(source: URL, fileName: String)]) throws {
        let fm = FileManager.default
        let folder = dir(forLibraryFile: card.libraryFileName)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for img in images {
            try? fm.copyItem(at: img.source, to: folder.appendingPathComponent(img.fileName))
        }
        let data = try JSONEncoder().encode(card)
        try data.write(to: folder.appendingPathComponent("card.json"), options: .atomic)
    }

    /// Remove an adapter's card folder — called when the adapter is deleted or replaced by a
    /// different file under the same name (a new adapter must not inherit a stale card).
    static func delete(forLibraryFile name: String) {
        try? FileManager.default.removeItem(at: dir(forLibraryFile: name))
    }

    // MARK: card.html (export package)

    /// Self-contained HTML card for the export package: the images sit next to card.html, the
    /// loss curve is an inline SVG — opens anywhere, no app needed.
    static func html(for card: TrainingModelCard, recommendedScale: Float?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let tierName = ModelTier(rawValue: card.tier)?.shortName ?? card.tier
        let stepLabel = card.publishedStep.map { "checkpoint at step \($0) of \(card.maxSteps)" }
            ?? "final adapter (\(card.maxSteps) steps)"
        let strength = recommendedScale.map { String(format: "%.2f", $0) } ?? "1.00"
        var facts: [(String, String)] = [
            ("Trigger word", card.trigger.isEmpty ? "—" : card.trigger),
            ("Model", tierName),
            ("Published", stepLabel),
            ("Recommended strength", strength),
            ("Rank / Alpha", "\(card.rank) / \(Int(card.alpha))"),
            ("Learning rate", String(format: "%g", card.learningRate)),
            ("Resolution", "\(card.resolution)px"),
            ("Dataset", "\(card.imageCount) image\(card.imageCount == 1 ? "" : "s")"
                + (card.mirrored == true ? " (mirror-augmented)" : "")),
            ("DOP", card.dopEnabled ? "on (\(card.dopClass ?? "—"))" : "off"),
        ]
        if let ct = card.conceptType { facts.insert(("Concept", ct), at: 2) }
        if let ws = card.workshopName { facts.append(("Workshop", ws)) }
        facts.append(("Published on", card.publishedAt.formatted(date: .abbreviated, time: .shortened)))

        let factRows = facts.map {
            "<tr><td class=\"k\">\(esc($0.0))</td><td>\(esc($0.1))</td></tr>"
        }.joined(separator: "\n")

        let gallery = card.validation.map {
            "<figure><img src=\"\(esc($0.fileName))\" alt=\"\"><figcaption>\(esc($0.prompt))</figcaption></figure>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(esc(card.libraryFileName)) — model card</title>
        <style>
          body { background: #121317; color: #e6e4de; font: 14px/1.5 -apple-system, "Segoe UI", sans-serif;
                 max-width: 780px; margin: 0 auto; padding: 32px 20px; }
          h1 { font-size: 19px; word-break: break-all; }
          h2 { font-size: 13px; color: #9a968d; text-transform: uppercase; letter-spacing: .06em; margin-top: 28px; }
          .trigger { color: #d9a24a; font-family: ui-monospace, monospace; }
          table { border-collapse: collapse; width: 100%; }
          td { padding: 5px 10px 5px 0; border-bottom: 1px solid #24262c; vertical-align: top; }
          td.k { color: #9a968d; width: 200px; }
          .grid { display: flex; flex-wrap: wrap; gap: 14px; }
          figure { margin: 0; width: 220px; }
          figure img { width: 100%; border-radius: 8px; border: 1px solid #2a2c33; display: block; }
          figcaption { font-size: 11.5px; color: #9a968d; margin-top: 5px; }
          svg { display: block; }
          footer { margin-top: 32px; font-size: 11px; color: #63605a; }
        </style>
        </head>
        <body>
        <h1>\(esc(card.runName)) <span class="trigger">\(esc(card.trigger))</span></h1>
        <p>LoRA adapter <strong>\(esc(card.libraryFileName))</strong> for FLUX.2 \(esc(tierName)). Add it with strength \(strength)\(card.trigger.isEmpty ? "" : " and use the trigger word “<span class=\"trigger\">\(esc(card.trigger))</span>” in your prompt").</p>
        <h2>Training recipe</h2>
        <table>\(factRows)</table>
        \(card.lossHistory.count > 1 ? "<h2>Loss curve</h2>\n" + lossSVG(card.lossHistory) : "")
        \(gallery.isEmpty ? "" : "<h2>Validation images (step \(card.validationStep.map(String.init) ?? "—"), same seed per prompt)</h2>\n<div class=\"grid\">\n\(gallery)\n</div>")
        <footer>Generated by Typhoonminigen — trained locally with MLX on Apple silicon.</footer>
        </body>
        </html>
        """
    }

    /// Inline SVG: faint raw loss + amber trailing moving average (same look as the app's chart).
    private static func lossSVG(_ values: [Float], width: Double = 740, height: Double = 150) -> String {
        guard values.count > 1 else { return "" }
        let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
        let span = (hi - lo) == 0 ? 1 : (hi - lo)
        func pts(_ series: [Double]) -> String {
            series.enumerated().map { i, v in
                let x = Double(i) / Double(series.count - 1) * width
                let y = height - 6 - (v - lo) / span * (height - 12)
                return String(format: "%.1f,%.1f", x, y)
            }.joined(separator: " ")
        }
        let raw = values.map(Double.init)
        var smooth: [Double] = []
        let window = 20
        for i in raw.indices {
            let start = max(0, i - window + 1)
            let slice = raw[start...i]
            smooth.append(slice.reduce(0, +) / Double(slice.count))
        }
        return """
        <svg viewBox="0 0 \(Int(width)) \(Int(height))" width="100%" style="background:#0d0e11;border:1px solid #24262c;border-radius:8px">
          <polyline points="\(pts(raw))" fill="none" stroke="#5a5c63" stroke-width="1"/>
          <polyline points="\(pts(smooth))" fill="none" stroke="#d9a24a" stroke-width="1.8"/>
        </svg>
        """
    }
}
