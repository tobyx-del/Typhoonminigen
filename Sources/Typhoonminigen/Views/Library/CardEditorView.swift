import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor sheet for a user's own Library card. Builds a full `SceneRecipe` — title, studio,
/// subject, chip set (over the same catalog as Generate, honoring single/multi + conflicts),
/// optional pinned tier/steps/aspect — with a live prompt preview. `onSave` receives the finished
/// recipe (its id is preserved from the draft, so editing updates in place).
struct CardEditorView: View {
    let draft: SceneRecipe
    let onSave: (SceneRecipe) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var studio: String
    @State private var subject: String
    @State private var note: String
    @State private var chips: Set<String>
    @State private var tier: ModelTier?
    @State private var pinSteps: Bool
    @State private var steps: Int
    @State private var aspect: AspectChoice
    @State private var previewImage: NSImage?
    // Preview edits are staged and only committed to disk on Save — so Cancel is a true no-op and an
    // aborted edit never destroys the card's existing preview.
    @State private var pendingPreviewURL: URL?
    @State private var pendingRemove = false
    @State private var studios = CustomStudioStore.shared   // observe so a new section appears
    @State private var showingNewSection = false
    @State private var newSectionName = ""
    // Sections created via the inline "New section" field this session — Cancel must undo them
    // (the store persists immediately so the picker can select them, but the sheet promises
    // staged edits: an aborted edit must not leave a stray empty section behind).
    @State private var createdSectionIDs: [String] = []
    // "Use last render" availability, resolved ONCE per sheet — the old inline
    // `.disabled(CustomRecipeStore.latestGalleryImageURL() == nil)` re-read and re-parsed the
    // whole gallery JSON on every body pass (i.e. every keystroke in any field).
    @State private var latestRenderURL: URL? = nil

    init(draft: SceneRecipe, onSave: @escaping (SceneRecipe) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _title   = State(initialValue: draft.title)
        _studio  = State(initialValue: draft.studio)
        _subject = State(initialValue: draft.subjectExample)
        _note    = State(initialValue: draft.note)
        _chips   = State(initialValue: Set(draft.chipIDs))
        _tier    = State(initialValue: draft.tier)
        _pinSteps = State(initialValue: draft.steps != nil)
        _steps   = State(initialValue: draft.steps ?? 18)
        _aspect  = State(initialValue: AspectChoice(draft.aspectW, draft.aspectH))
        _previewImage = State(initialValue: NSImage(contentsOf: AppPaths.customRecipePreview(for: draft.id)))
    }

    private var isNew: Bool { !CustomRecipeStore.shared.items.contains { $0.id == draft.id } }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var previewPrompt: String {
        let suffix = PresetCatalog.suffix(for: chips, ignoringHidden: true)
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return suffix }
        return suffix.isEmpty ? s : "\(s), \(suffix)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New card" : "Edit card").font(.fx(15, weight: .bold)).foregroundStyle(Color.fxText)
                Spacer()
                Button { cancel() } label: { Image(systemName: "xmark").fxDialogIcon() }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Color.fxInset)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Title") {
                        TextField("e.g. Rainy neon alley", text: $title).textFieldStyle(.plain).fxInputBox()
                    }
                    field("Section") { sectionPicker }
                    field("Subject") {
                        TextEditor(text: $subject)
                            .font(.fx(12)).foregroundStyle(Color.fxText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 60, maxHeight: 90).fxInputBox()
                    }
                    field("Note (optional)") {
                        TextField("A short honesty/usage note shown on the card", text: $note)
                            .textFieldStyle(.plain).fxInputBox()
                    }
                    previewField
                    chipPicker
                    pinnedSettings
                    field("Prompt preview") {
                        Text(previewPrompt.isEmpty ? "Type a subject and pick chips…" : previewPrompt)
                            .font(.fx(11.5)).foregroundStyle(previewPrompt.isEmpty ? Color.fxText3 : Color.fxText2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fxInputBox()
                    }
                }
                .padding(18)
            }

            HStack {
                Spacer()
                Button { cancel() } label: { Text("Cancel") }.buttonStyle(FxGhostButtonStyle(height: 30))
                Button { commitAndSave() } label: { Text(isNew ? "Create card" : "Save") }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30, fullWidth: false))
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color.fxInset)
        }
        .frame(width: 560, height: 660)
        .background(Color.fxBg)
        .task { latestRenderURL = CustomRecipeStore.latestGalleryImageURL() }   // once per sheet, not per keystroke
    }

    // ── Section (built-in + custom studios + "New section") ─────────────────────
    @ViewBuilder private var sectionPicker: some View {
        if showingNewSection {
            HStack(spacing: 8) {
                TextField("New section name", text: $newSectionName).textFieldStyle(.plain).fxInputBox()
                Button {
                    let t = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        studio = studios.add(title: t)
                        createdSectionIDs.append(studio)   // remembered so Cancel can undo it
                    }
                    newSectionName = ""; showingNewSection = false
                } label: { Text("Add") }
                .buttonStyle(FxGhostButtonStyle(height: 30))
                .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { showingNewSection = false; newSectionName = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Color.fxText3)
                }.buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 8) {
                Picker("", selection: $studio) {
                    ForEach(PromptPresetLibrary.studios) { s in Text(s.title).tag(s.id) }
                    ForEach(studios.items) { s in Text(s.title).tag(s.id) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Color.fxAccent)
                Button { showingNewSection = true } label: {
                    HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10)); Text("New section") }
                }.buttonStyle(FxGhostButtonStyle(height: 30))
            }
        }
    }

    // ── Preview image ─────────────────────────────────────────────────────────
    private var previewField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Preview image (optional)")
            HStack(spacing: 12) {
                // Fill+crop like the Gallery / card, so what you see is what the card shows.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .overlay {
                        if let previewImage {
                            Image(nsImage: previewImage).resizable().scaledToFill()
                        } else {
                            Color.fxText3.opacity(0.10).overlay {
                                Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(Color.fxText3.opacity(0.5))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button { useLastRender() } label: { Text("Use last render") }
                            .buttonStyle(FxGhostButtonStyle(height: 26))
                            .disabled(latestRenderURL == nil)   // resolved once in .task, not re-parsed per body pass
                            .help("Use your most recent Gallery render as this card's picture.")
                        Button { chooseImage() } label: { Text("Choose file…") }
                            .buttonStyle(FxGhostButtonStyle(height: 26))
                            .help("Pick any image file.")
                    }
                    if previewImage != nil {
                        Button { removePreview() } label: {
                            Text("Remove").font(.fx(11)).foregroundStyle(Color.fxDanger)
                        }.buttonStyle(.plain)
                    }
                    Text("The picture is applied when you press Save (shrunk to a small ~320px thumbnail). On Generate, “Save as card” grabs the render on screen automatically.")
                        .font(.fx(9.5)).foregroundStyle(Color.fxText3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as preview"
        if panel.runModal() == .OK, let url = panel.url {
            pendingPreviewURL = url          // stage — written to disk only on Save
            pendingRemove = false
            previewImage = NSImage(contentsOf: url)
        }
    }

    /// Stage the most recent gallery render as the preview — reliable, no file dialog.
    private func useLastRender() {
        guard let url = latestRenderURL else { return }
        pendingPreviewURL = url
        pendingRemove = false
        previewImage = NSImage(contentsOf: url)
    }

    private func removePreview() {
        pendingPreviewURL = nil
        pendingRemove = true                 // stage — deleted from disk only on Save
        previewImage = nil
    }

    /// Commit any staged preview change to disk, then hand the recipe back.
    private func commitAndSave() {
        if let url = pendingPreviewURL {
            CustomRecipeStore.writePreview(fromFile: url, for: draft.id)
        } else if pendingRemove {
            CustomRecipeStore.removePreview(for: draft.id)
        }
        onSave(build())
    }

    // ── Chip picker ───────────────────────────────────────────────────────────
    private var chipPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Chips")
            ForEach(PromptPresetGroup.allCases) { group in
                ForEach(group.categories) { category in
                    let presets = PresetCatalog.presets(for: category)
                    if !presets.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.title.uppercased())
                                .font(.fx(9, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                            FxFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(presets) { p in chipToggle(p, category) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chipToggle(_ p: PromptPreset, _ category: PromptPresetCategory) -> some View {
        let on = chips.contains(p.id)
        return Button { toggle(p.id, category) } label: {
            Text(p.label)
                .font(.fx(11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.fxText : Color.fxText2)
                .fxChip(accent: on, padV: 4, padH: 9)
        }
        .buttonStyle(.plain)
        .help(p.phrase)
    }

    private func toggle(_ id: String, _ category: PromptPresetCategory) {
        if chips.contains(id) { chips.remove(id); return }
        if !category.allowsMultiple {
            // Subtract over the UNfiltered pool: a preserved-but-hidden sibling must be replaced
            // too, or a single-select category ends up carrying two chips at once.
            chips.subtract(fullPool(for: category).map(\.id))   // single-select: replace sibling
        }
        if let conf = PromptPresets.conflicts[id] { chips.subtract(conf) }   // drop physical contradictions
        chips.insert(id)
    }

    // ── Pinned settings ────────────────────────────────────────────────────────
    /// "pins seed N · quality X" — seed/quality ride through from the draft ("Save as card"
    /// captures them off the Generate form) with no editor controls, so surface WHAT is pinned;
    /// an invisible pin the user can't see or clear would be worse than none.
    private var pinnedInvisibles: String? {
        var parts: [String] = []
        if let s = draft.seed { parts.append("seed \(s)") }
        if let q = draft.quality { parts.append("quality \(q.label)") }
        return parts.isEmpty ? nil : "Also pins " + parts.joined(separator: " · ") + " (captured from the render this card was saved from)."
    }

    private var pinnedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Reproduce exactly (optional)")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.fx(9, weight: .semibold)).foregroundStyle(Color.fxText3)
                    Picker("", selection: $tier) {
                        Text("Auto").tag(ModelTier?.none)
                        Text("Klein 4B").tag(ModelTier?.some(.klein4B))
                        Text("Klein 9B").tag(ModelTier?.some(.klein9B))
                    }.labelsHidden().pickerStyle(.menu).tint(Color.fxAccent).frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect").font(.fx(9, weight: .semibold)).foregroundStyle(Color.fxText3)
                    Picker("", selection: $aspect) {
                        ForEach(AspectChoice.all, id: \.self) { a in Text(a.label).tag(a) }
                    }.labelsHidden().pickerStyle(.menu).tint(Color.fxAccent).frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $pinSteps) {
                        Text("Steps \(pinSteps ? "\(steps)" : "auto")").font(.fx(10)).foregroundStyle(Color.fxText2)
                    }.toggleStyle(.switch).tint(Color.fxAccent)
                    if pinSteps {
                        Stepper("", value: $steps, in: 1...50).labelsHidden()
                    }
                }
                Spacer()
            }
            .fxInputBox()
            if let pinned = pinnedInvisibles {
                Text(pinned).font(.fx(9.5)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Cancel — for a brand-new card, drop any preview jpg we wrote so it doesn't orphan on disk.
    /// Sections created via the inline "New section" field are undone too (only while still
    /// empty — cards can't be filed into them from this sheet, but never delete user content).
    private func cancel() {
        if isNew { CustomRecipeStore.removePreview(for: draft.id) }
        for id in createdSectionIDs where CustomRecipeStore.shared.recipes(in: id).isEmpty {
            studios.remove(id)
        }
        onCancel()
    }

    /// The UNfiltered chip pool for one category — built-ins INCLUDING globally-hidden ones,
    /// plus the user's custom chips. `build()` must resolve the card's existing chips against
    /// this pool: a card may legitimately carry a chip its author later hid in Generate
    /// (loadScene/enqueueScene deliberately apply it via `suffix(ignoringHidden:)`), and
    /// resolving against the hidden-filtered `PresetCatalog.presets` silently STRIPPED such
    /// chips from the card on every edit. The PICKER keeps using the filtered pool — hidden
    /// chips stay unofferable for NEW picks; only preservation ignores hiding.
    private func fullPool(for category: PromptPresetCategory) -> [PromptPreset] {
        PromptPresets.presets(for: category) + CustomPresetStore.shared.chips(for: category)
    }

    private func build() -> SceneRecipe {
        SceneRecipe(
            id: draft.id, studio: studio,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            subjectExample: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            // keep chips in a stable, catalog-defined order (matches how prompts assemble);
            // fullPool (not the hidden-filtered catalog) so preserved hidden chips survive a re-save
            chipIDs: PromptPresetCategory.appendOrder.flatMap { cat in
                fullPool(for: cat).map(\.id).filter { chips.contains($0) }
            },
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            badge: .green, featured: false,
            // seed/quality have no editor controls, but "Save as card" captures them off the
            // Generate form precisely so loading the card reproduces what was on screen —
            // hard-coding nil here silently un-pinned both on every save/edit.
            tier: tier, steps: pinSteps ? steps : nil, quality: draft.quality,
            aspectW: aspect.w, aspectH: aspect.h, seed: draft.seed)
    }

    // ── small helpers ────────────────────────────────────────────────────────
    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { fieldLabel(label); content() }
    }
    private func fieldLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.fx(9.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color.fxText3)
    }
}

/// A named aspect option for the editor (Auto = don't pin).
struct AspectChoice: Hashable {
    let w: Int?
    let h: Int?
    var label: String { (w == nil || h == nil) ? "Auto" : "\(w!):\(h!)" }
    init(_ w: Int?, _ h: Int?) {
        if let w, let h, w > 0, h > 0 { self.w = w; self.h = h } else { self.w = nil; self.h = nil }
    }
    // Must cover BOTH pin sources: the form's aspect chips (which include 4:3) and the
    // built-in recipes' pins (which include 4:5) — a card pinned to a ratio missing here
    // opens the Picker with an invalid selection and one menu touch loses the pin forever.
    static let all: [AspectChoice] = [
        AspectChoice(nil, nil), AspectChoice(1, 1), AspectChoice(4, 5), AspectChoice(4, 3),
        AspectChoice(3, 2), AspectChoice(16, 9), AspectChoice(9, 16), AspectChoice(2, 3),
        AspectChoice(3, 4),
    ]
}

private extension View {
    /// Consistent boxed input look for the editor.
    func fxInputBox() -> some View {
        self.padding(.vertical, 8).padding(.horizontal, 10)
            .background(Color.fxBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }
    func fxDialogIcon() -> some View {
        self.font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fxText3)
            .frame(width: 24, height: 24).background(Circle().fill(Color.fxHover))
    }
}
