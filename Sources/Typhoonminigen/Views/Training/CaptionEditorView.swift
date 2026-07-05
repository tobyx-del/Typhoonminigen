import SwiftUI
import AppKit

/// Per-image caption editor, shown as a sheet over the workshop. Mirrors FluxForge's caption
/// navigator: a large preview, an editable caption, char count + position, ⌘[ / ⌘] navigation,
/// per-image VLM caption, "use as reference", remove and reveal-in-Finder. Captions are stored
/// BARE — the trigger word is prepended by the engine at train time, never typed here.
struct CaptionEditorView: View {
    @Bindable var vm: TrainingViewModel
    let workshopID: UUID
    @Binding var index: Int
    let onClose: () -> Void

    @State private var draft: String = ""
    @State private var preview: NSImage?
    @FocusState private var captionFocused: Bool
    // Whether the batch that's currently running belongs to THIS workshop — remembered at batch
    // START, because captioningWorkshopID is already nil again when `captioning` flips to false.
    @State private var batchWasHere = false

    // Live workshop state — so a caption written by the VLM shows up immediately.
    private var workshop: Workshop? { vm.workshops.first { $0.id == workshopID } }
    private var images: [TrainingImageRef] { workshop?.images ?? [] }
    private var current: TrainingImageRef? { images.indices.contains(index) ? images[index] : nil }
    /// A caption batch is running FOR THIS workshop — only then does the editor lock (a batch in
    /// another workshop must not grey out manual typing here for its whole duration).
    private var captioningHere: Bool { vm.captioning && vm.captioningWorkshopID == workshopID }
    private var isReference: Bool {
        guard let cur = current, let cover = workshop?.coverImageFileName else { return false }
        return cur.fileName == cover
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.fxBorder)
            if current != nil {
                content
            } else {
                Spacer()
                Text("No image").font(.fx(13)).foregroundStyle(Color.fxText3)
                Spacer()
            }
            Divider().overlay(Color.fxBorder)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Color.fxBg)
        .onAppear {
            syncForCurrentImage()
            batchWasHere = captioningHere   // sheet opened while our batch was already running
        }
        .onChange(of: index) { _, _ in syncForCurrentImage() }
        // Preview decode keyed to the CURRENT image (same idiom as GalleryView's `.task(id:)`
        // cells). This used to be a fire-and-forget Task per ‹ › press — last-decode-wins, so
        // rapid navigation could land a slow decode of image N under image N+1's caption.
        // `.task(id:)` cancels the previous decode on every id change; the isCancelled guard
        // covers the decoder not being cancellation-aware (the await still returns a stale image
        // after cancellation — it just must not be assigned).
        .task(id: current?.id) {
            preview = nil
            guard let cur = current, let url = workshop?.imageURL(cur) else { return }
            let image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 900)
            if !Task.isCancelled { preview = image }
        }
        // Batch lifecycle. A QUEUED caption job can auto-start with no user interaction (queue
        // chaining), possibly mid-typing — persist the draft the moment OUR batch starts, so the
        // finish-refresh below can never silently discard typed-but-unsaved text. Batches for
        // OTHER workshops are ignored entirely (they never touch this workshop's captions).
        .onChange(of: vm.captioning) { _, busy in
            if busy {
                batchWasHere = vm.captioningWorkshopID == workshopID
                if batchWasHere { saveDraft() }
            } else if batchWasHere {
                batchWasHere = false
                draft = current?.caption ?? ""   // refresh with the model's text
            }
        }
        // Live fill during a batch job: each caption is committed the moment the VLM finishes that
        // image — show it right away. Safe: the editor is disabled (read-only) while THIS
        // workshop's batch runs, so this can never clobber a manual edit in progress.
        .onChange(of: current?.caption) { _, newValue in
            if captioningHere { draft = newValue ?? "" }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Caption").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
            if !images.isEmpty {
                Text("Image \(index + 1) of \(images.count)")
                    .font(.fxMono(11)).foregroundStyle(Color.fxText3)
            }
            Spacer()
            navButton("chevron.left", "[", help: "Previous image (⌘[)") { go(to: index - 1) }
                .disabled(index <= 0)
            navButton("chevron.right", "]", help: "Next image (⌘])") { go(to: index + 1) }
                .disabled(index >= images.count - 1)
            Button { saveDraft(); onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(FxIconButtonStyle())
                .help("Close (saves the caption)")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func navButton(_ icon: String, _ key: KeyEquivalent, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(FxIconButtonStyle())
            .keyboardShortcut(key, modifiers: .command)
            .help(help)
    }

    // MARK: Content

    private var content: some View {
        HStack(alignment: .top, spacing: 16) {
            // Preview
            Rectangle().fill(Color.fxInset)
                .overlay {
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))

            // Caption editor + per-image actions
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Caption").fxLabel()
                    Spacer()
                    Text("\(draft.count) chars").font(.fxMono(10)).foregroundStyle(Color.fxText3)
                }
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Describe what this image shows…")
                            .font(.fx(12)).foregroundStyle(Color.fxText3.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.fx(12)).foregroundStyle(Color.fxText)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .focused($captionFocused)
                        // Locked while the VLM writes THIS workshop's captions (live fill would fight
                        // the caret). A batch in another workshop leaves manual typing available.
                        .disabled(captioningHere)
                }
                .frame(height: 150)
                .fxInsetField()

                HStack(spacing: 8) {
                    Button {
                        if let cur = current { saveDraft(); vm.captionOne(cur.id, in: workshopID) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text(captioningHere ? "Captioning…" : "Caption this image")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                    // The VLM itself is single-flight app-wide (any running batch blocks it), and it
                    // can't run at all while a training holds the engine — disable instead of erroring.
                    .disabled(vm.captioning || vm.importing || vm.isTrainingActive)
                    .help(vm.isTrainingActive
                          ? "The vision model can't run while a training is active — use Auto-caption in the workshop to queue a job instead."
                          : "Caption this image with the vision model")

                    Spacer()
                }

                Text("Type the description of the scene — environment, pose/angle, lighting. Leave the trigger word out; it's added automatically when you train.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { if let cur = current { vm.toggleReference(cur, in: workshopID) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: isReference ? "star.fill" : "star")
                    Text(isReference ? "Reference" : "Set as reference")
                }
            }
            .buttonStyle(FxGhostButtonStyle(height: 30, accentText: isReference))
            .help("The reference image is used to evaluate how a training turned out. It is not a training image by itself.")

            Button { revealInFinder() } label: {
                HStack(spacing: 6) { Image(systemName: "folder"); Text("Show in Finder") }
            }
            .buttonStyle(FxGhostButtonStyle(height: 30))

            Spacer()

            Button(role: .destructive) { removeCurrent() } label: {
                HStack(spacing: 6) { Image(systemName: "trash"); Text("Remove") }
            }
            .buttonStyle(FxGhostButtonStyle(height: 30))
            .help("Remove this image from the workshop")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Actions

    private func syncForCurrentImage() {
        // The index may be stale if images changed between opening the sheet and this run — clamp it.
        if !images.isEmpty, index < 0 || index >= images.count {
            index = min(max(0, index), images.count - 1)
        }
        draft = current?.caption ?? ""
        // The preview decode lives in the body's `.task(id: current?.id)` — NOT here — so each
        // navigation cancels the previous decode instead of racing it (wrong-image-under-caption).
    }

    private func saveDraft() {
        guard let cur = current else { return }
        // Only write if the user actually changed it (avoids stamping .manual over an AI/sidecar source).
        if draft != cur.caption {
            vm.setCaption(draft, for: cur.id, in: workshopID, source: .manual)
        }
    }

    private func go(to newIndex: Int) {
        guard !images.isEmpty else { return }
        saveDraft()
        index = min(max(0, newIndex), images.count - 1)
    }

    private func removeCurrent() {
        guard let cur = current else { return }
        let wasLast = images.count <= 1
        vm.removeImage(cur, from: workshopID)
        if wasLast { onClose(); return }
        // Land on a still-valid neighbour. removeImage persists asynchronously, so images.count is
        // still the pre-removal count (>=2) here; the new last index is count-2. max(0,...) is belt-and-braces.
        index = max(0, min(index, images.count - 2))
    }

    private func revealInFinder() {
        guard let cur = current, let url = workshop?.imageURL(cur) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
