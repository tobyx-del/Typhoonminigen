import SwiftUI
import AppKit

// ============================================================
//  Checkpoint compare matrix — the review heart of a finished run.
//  One COLUMN per validation prompt, one ROW per checkpoint, and the
//  engine's step-0 "no LoRA" baseline pinned as the top row (the engine
//  renders every validation prompt once WITHOUT the adapter before a
//  fresh training and writes them to outputDir/baseline/).
//  Clicking any cell opens a lightbox where ↑/↓ scrub the SAME prompt
//  through training time (same seed — only the training changed) and
//  ←/→ move between prompts.
// ============================================================

/// Disk-scanned matrix of validation images. The engine's filename pattern is
/// `prompt_{i}{_trigger}{_i2i}_{512x512|1024x1024}.png` inside `baseline/` and each
/// `checkpoint_%06d/` — the prompt index prefix is what keys a column.
struct ValidationMatrix: Sendable {
    struct Row: Identifiable, Sendable {
        var id: String { label }
        let label: String
        let step: Int?              // nil → the no-LoRA baseline row
        let images: [Int: URL]      // prompt index → image file
    }
    let promptIndices: [Int]
    let rows: [Row]                 // baseline first, then checkpoints ascending

    /// nil when the run has nothing reviewable (no checkpoint has validation images).
    /// Baseline images exist only for runs STARTED fresh with validation prompts — a resumed
    /// or preview-less run simply has no baseline row (the matrix degrades gracefully).
    static func scan(run: TrainingRun) -> ValidationMatrix? {
        let fm = FileManager.default
        func images(in dir: URL) -> [Int: URL] {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
            var out: [Int: URL] = [:]
            for f in files where f.pathExtension.lowercased() == "png" {
                let name = f.lastPathComponent
                guard name.hasPrefix("prompt_") else { continue }
                guard let i = Int(name.dropFirst("prompt_".count).prefix(while: { $0.isNumber })) else { continue }
                // When both 512 and 1024 renders exist for a prompt, keep the larger one.
                if let existing = out[i], existing.lastPathComponent.contains("1024x1024") { continue }
                out[i] = f
            }
            return out
        }
        var rows: [Row] = []
        let baseline = images(in: run.outputDir.appendingPathComponent("baseline"))
        if !baseline.isEmpty {
            rows.append(Row(label: "No LoRA", step: nil, images: baseline))
        }
        for cp in run.runtime.checkpoints.sorted(by: { $0.step < $1.step }) {
            let imgs = images(in: run.outputDir.appendingPathComponent(cp.dirName))
            if !imgs.isEmpty { rows.append(Row(label: "Step \(cp.step)", step: cp.step, images: imgs)) }
        }
        guard rows.contains(where: { $0.step != nil }) else { return nil }   // baseline alone isn't a comparison
        let indices = Set(rows.flatMap { $0.images.keys }).sorted()
        guard !indices.isEmpty else { return nil }
        return ValidationMatrix(promptIndices: indices, rows: rows)
    }
}

/// A cell address inside the matrix (row index × column position), presented as the lightbox item.
/// The identity is CONSTANT: arrow-navigation mutates row/col in place, and a changing item id
/// would make .sheet(item:) dismiss + re-present the sheet on every keystroke.
struct CompareSelection: Identifiable, Equatable {
    var row: Int
    var col: Int      // position within promptIndices, NOT the raw prompt index
    var id: String { "compare-lightbox" }
}

// MARK: - Grid

struct CheckpointCompareGrid: View {
    let run: TrainingRun
    let matrix: ValidationMatrix
    /// step → its weight file is still on disk. Fed from the host's `CheckpointDiskStats`
    /// snapshot so the lightbox footer doesn't stat the filesystem on every body evaluation.
    let hasWeights: (Int) -> Bool
    let onPublish: (Int) -> Void

    @State private var selection: CompareSelection? = nil
    private let cell: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compare checkpoints").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
                Spacer()
                // Per-prompt seed overrides render THEIR seed, not the run seed — claiming one
                // blanket number would break anyone trying to reproduce a column in Generate.
                Text(run.params.validationPrompts.contains { $0.seed != nil }
                     ? "same prompt · fixed seed per column — only the training differs"
                     : "same prompt · same seed \(run.params.validationSeed) — only the training differs")
                    .font(.fxMono(10)).foregroundStyle(Color.fxText3)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("").frame(width: 74, alignment: .leading)
                        ForEach(Array(matrix.promptIndices.enumerated()), id: \.offset) { pos, idx in
                            Text("P\(pos + 1)")
                                .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                                .frame(width: cell)
                                .help(promptText(idx))
                        }
                    }
                    ForEach(Array(matrix.rows.enumerated()), id: \.element.id) { r, row in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                    .font(.fxMono(10.5))
                                    .foregroundStyle(row.step == nil ? Color.fxText3 : Color.fxText2)
                                if row.step != nil, run.publishedCheckpointStep == row.step {
                                    Text("published").font(.fxMono(8.5)).foregroundStyle(Color.fxOk)
                                }
                            }
                            .frame(width: 74, alignment: .leading)
                            ForEach(Array(matrix.promptIndices.enumerated()), id: \.offset) { pos, idx in
                                cellView(row: r, pos: pos, url: row.images[idx])
                            }
                        }
                    }
                }
            }
            if matrix.rows.first?.step == nil {
                Text("Top row = the model WITHOUT your LoRA. If a checkpoint row looks the same, the LoRA hasn't learned your subject yet — compare its fine identity, not the general class.")
                    .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $selection) { _ in
            CompareLightbox(run: run, matrix: matrix, selection: $selection,
                            promptText: promptText, hasWeights: hasWeights, onPublish: onPublish)
        }
    }

    @ViewBuilder private func cellView(row: Int, pos: Int, url: URL?) -> some View {
        if let url {
            Button { selection = CompareSelection(row: row, col: pos) } label: {
                MatrixThumb(url: url, side: cell)
            }
            .buttonStyle(.plain)
            .help("Click to zoom — ↑/↓ scrubs this prompt through the checkpoints")
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.fxInset.opacity(0.5))
                .frame(width: cell, height: cell)
                .overlay(Image(systemName: "minus").font(.system(size: 9)).foregroundStyle(Color.fxText3.opacity(0.5)))
        }
    }

    private func promptText(_ index: Int) -> String {
        // One shared resolver: an inline [trigger] resolves in place, otherwise the
        // applyTrigger prepend applies — the tooltip shows what the model really received.
        TrainingViewModel.resolvedValidationPrompt(run, index: index)
    }
}

/// Small square matrix thumbnail (downsampled off-main).
private struct MatrixThumb: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(Color.fxInset)
            .frame(width: side, height: side)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            .task(id: url) { image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 160) }
    }
}

// MARK: - Lightbox

/// Zoomed compare viewer. ↑/↓ move through checkpoints for the SAME prompt (time-travel),
/// ←/→ switch prompts. Publish sits right here so "this one looks best" is one click.
private struct CompareLightbox: View {
    let run: TrainingRun
    let matrix: ValidationMatrix
    @Binding var selection: CompareSelection?
    let promptText: (Int) -> String
    let hasWeights: (Int) -> Bool
    let onPublish: (Int) -> Void

    @State private var image: NSImage?
    @FocusState private var keysFocused: Bool   // onKeyPress only fires on a FOCUSED view

    private var sel: CompareSelection { selection ?? CompareSelection(row: 0, col: 0) }
    private var row: ValidationMatrix.Row { matrix.rows[min(sel.row, matrix.rows.count - 1)] }
    private var promptIndex: Int { matrix.promptIndices[min(sel.col, matrix.promptIndices.count - 1)] }
    private var url: URL? { row.images[promptIndex] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.fxLogBg
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(10)
                } else if url == nil {
                    Text("No image for this prompt at \(row.label.lowercased()).")
                        .font(.fx(12)).foregroundStyle(Color.fxText3)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 420)
            Divider().overlay(Color.fxBorder)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Color.fxBg)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onAppear { keysFocused = true }
        .task(id: sel) {   // keyed on the VALUE — the id is deliberately constant (sheet identity)
            image = nil
            if let url { image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 1200) }
        }
        .onKeyPress(.upArrow)    { move(dRow: -1); return .handled }
        .onKeyPress(.downArrow)  { move(dRow: +1); return .handled }
        .onKeyPress(.leftArrow)  { move(dCol: -1); return .handled }
        .onKeyPress(.rightArrow) { move(dCol: +1); return .handled }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.label).font(.fxMono(12)).foregroundStyle(row.step == nil ? Color.fxText3 : Color.fxText)
                    stepperHint
                }
                Text(promptText(promptIndex))
                    .font(.fx(11)).foregroundStyle(Color.fxText3).lineLimit(2)
            }
            Spacer()
            if let step = row.step {
                // Retention may have stripped this checkpoint's weights — preview-only then.
                // Answered from the host's disk-stats snapshot, not a per-body fileExists.
                if hasWeights(step) {
                    let published = run.publishedCheckpointStep == step
                    Button { onPublish(step) } label: {
                        Text(published ? "Republish" : "Publish this checkpoint")
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 28, accentText: true))
                } else {
                    Text("preview only").font(.fxMono(10)).foregroundStyle(Color.fxText3)
                        .help("Retention removed this checkpoint's weight files — it can't be published.")
                }
            }
            Button { selection = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(FxIconButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var stepperHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 8))
            Text("checkpoints")
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 8))
            Text("prompts")
        }
        .font(.fxMono(9)).foregroundStyle(Color.fxText3.opacity(0.8))
    }

    private func move(dRow: Int = 0, dCol: Int = 0) {
        guard var s = selection else { return }
        s.row = max(0, min(matrix.rows.count - 1, s.row + dRow))
        s.col = max(0, min(matrix.promptIndices.count - 1, s.col + dCol))
        selection = s
    }
}
