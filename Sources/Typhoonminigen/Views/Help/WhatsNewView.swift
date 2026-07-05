import SwiftUI

// ============================================================
//  "What's new" — one-time sheet after an update (the CALLER
//  decides when to show it and persists lastSeenWhatsNewVersion;
//  this view only renders releases and calls onClose).
// ============================================================

struct WhatsNewView: View {
    /// Releases strictly newer than this version are shown; when none qualify
    /// (re-opened from Help right after dismissing), the latest release shows.
    var since: String = "0"
    var onClose: () -> Void = {}

    private struct Highlight: Identifiable {
        let icon: String
        let term: String
        let detail: String
        var id: String { term }
    }

    private struct Release {
        let version: String
        let highlights: [Highlight]
    }

    // The 2.0 release entry, drafted ahead of the version bump. It self-enables: the
    // conditional below keeps it OUT of `releases` while AppVersion.current is still 1.0
    // (the drift assert requires releases.first == current), and includes it automatically
    // the moment the version becomes 2.0 — the bump stays a one-line AppVersion change.
    private static let v2 = Release(version: "2.0", highlights: [
        Highlight(icon: "graduationcap.fill", term: "LoRA Training Studio",
                  detail: "Train your own LoRA fully on this Mac: build a workshop from your photos (auto-captioned by the local vision model), watch the live loss curve, compare checkpoints against a no-LoRA baseline, and publish the best one straight into your library. Trainings queue and run one after another; a finished run can extend for more steps. Klein 4B trains on a 32 GB Mac — the app is honest when a run wouldn't fit."),
        Highlight(icon: "books.vertical.fill", term: "A rebuilt, editable Library",
                  detail: "247 hand-tuned scenes across 19 studios — every card's preview is a real render of that exact recipe, and cards restore their pinned settings (many down to the seed, reproducing the preview). The Library is now yours to shape: hide any built-in card or section (Restore all brings them back), build your own cards in an editor with your own sections, or \u{201C}Save as card\u{201D} straight from Generate — prompt, chips, settings and the on-screen render as the cover."),
        Highlight(icon: "text.bubble", term: "Captions that work for you",
                  detail: "Auto-caption jobs queue up with trainings and run unattended — every caption is saved the moment it's ready, so a cancel or quit keeps what's done. Tune the vision model's instruction per workshop with concept-type presets, and fix a whole dataset at once with find & replace (a live \u{201C}affects N of M\u{201D} preview) or append/prepend."),
        Highlight(icon: "arrow.triangle.branch", term: "Training workflow tools",
                  detail: "Clone any training as a draft for A/B experiments, save reusable validation prompt sets with per-prompt seeds, keep only the last N checkpoint weights (previews always stay), double a small dataset with mirror augmentation, and publish with an auto-generated model card you can export."),
        Highlight(icon: "wand.and.rays", term: "LoRA toolbox",
                  detail: "Bake your sweet-spot strength into a copy so 1.0 means exactly that, merge adapters into one file, give every adapter an identity card (description, default strength, provenance), and import straight from a Hugging Face URL \u{2014} compatibility is checked before the big download. A [trigger] placeholder drops the trigger word exactly where you want it in any prompt."),
        Highlight(icon: "slider.horizontal.3", term: "Full render control",
                  detail: "A real 1\u{2013}50 Steps slider, per-tier Quality (quantization) presets, seven aspect-ratio presets, up to 4 reference images, and unlimited LoRA stacking with per-adapter strength, saved defaults and a one-click strength sweep."),
        Highlight(icon: "arrow.down.circle", term: "Fast, resumable downloads",
                  detail: "Big files stream as six parallel chunks and survive cancel, quit or a crash — every segment resumes from its exact offset. Queue several downloads, and keep using the rest of the Models tab while one runs."),
        Highlight(icon: "sparkles", term: "AI insights",
                  detail: "After a render, ask the local vision model anything about the image, or score how closely it matches your reference (scene + style, 0\u{2013}10). With Enhance prompt on, the gallery shows the exact rewritten prompt the model actually saw."),
        Highlight(icon: "magnifyingglass", term: "Gallery search & filters",
                  detail: "Search by prompt, LoRA name or seed; filter by model, adapter or quality. Every LoRA counts its renders and jumps to them pre-filtered, and multi-select upscales run through the queue."),
        Highlight(icon: "arrow.left.arrow.right", term: "Reference \u{2194} result flip",
                  detail: "Click the reference thumbnail on a render — on the canvas or in the gallery — to flip between your reference and the result in place: the honest way to check identity."),
        Highlight(icon: "waveform.path.ecg", term: "Live telemetry everywhere",
                  detail: "The canvas and queue say what's happening before step 1 and show s/step during the render; every image records its speed and true peak memory. A red status-bar chip warns when swap or free disk run dangerously low."),
        Highlight(icon: "wrench.and.screwdriver", term: "Repair & clean removal",
                  detail: "System \u{2192} Repair Library re-adopts recipe-bearing PNGs and prunes dead records without ever deleting an image file. \u{201C}Remove all data\u{201D} now also clears your settings, the Keychain token and this app's entries in the shared HuggingFace cache — and reports anything it couldn't delete."),
    ])

    // Newest first. 1.0 is the public start — pre-release patch notes are intentionally
    // dropped. Going forward, add ONE entry per release describing only what's new to the user.
    private static let releases: [Release] = (AppVersion.current == "2.0" ? [v2] : []) + [
        Release(version: "1.0", highlights: [
            Highlight(icon: "bolt.fill", term: "Local image generation",
                      detail: "Typhoonminigen runs the FLUX.2 Klein model entirely on your Mac \u{2014} no cloud, no account, nothing leaves the machine. Write a prompt in any language and create images fully offline."),
            Highlight(icon: "cpu", term: "Two model sizes",
                      detail: "Klein 4B is light and fast; Klein 9B is the quality tier. The app suggests the right one for your Mac's memory, and you can switch any time."),
            Highlight(icon: "books.vertical", term: "A Library of ready-made scenes",
                      detail: "Pick a studio \u{2014} Cinema, Portrait, Product, Interiors, Food, Auto, Nature, Anime and more \u{2014} tap a scene, drop in your own subject and generate. Each card is honest about what the model can and can't do."),
            Highlight(icon: "photo.on.rectangle.angled", term: "References, LoRA & a recipe in every image",
                      detail: "Guide a render with up to three reference images, load your own LoRA adapters, and queue a whole batch. Every saved PNG carries its full recipe \u{2014} drop one back in to remix it."),
            Highlight(icon: "lock.shield", term: "Private by design",
                      detail: "Your prompts, images and settings stay on your Mac and are erasable at any time. The only time the app goes online is to download the model weights once."),
        ]),
    ]

    private var shownReleases: [Release] {
        // Drift guard: a version bump without a matching release entry would show stale notes
        // under the new version header. Fires in Debug builds only.
        assert(Self.releases.first?.version == AppVersion.current,
               "WhatsNewView.releases is missing an entry for \(AppVersion.current)")
        let newer = Self.releases.filter { UpdateService.isNewer(remote: $0.version, local: since) }
        if newer.isEmpty, let latest = Self.releases.first { return [latest] }
        return newer
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.fxAccent)
                .frame(height: 54)
                .padding(.top, 20)
            Text("What's new")
                .font(.fx(20, weight: .bold))
                .foregroundStyle(Color.fxText)
                .padding(.top, 10)
            Text("Typhoonminigen \(AppVersion.current)")
                .font(.fxMono(11.5))
                .foregroundStyle(Color.fxText3)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(shownReleases, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 11) {
                            Text("VERSION \(release.version)")
                                .font(.fx(11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Color.fxText3)
                            ForEach(release.highlights) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.fxAccent)
                                        .frame(width: 22)
                                    Text(item.term)
                                        .font(.fx(12.5, weight: .semibold))
                                        .foregroundStyle(Color.fxText)
                                        .frame(width: 150, alignment: .leading)
                                    Text(item.detail)
                                        .font(.fx(12.5))
                                        .foregroundStyle(Color.fxText2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Button("Got it") { onClose() }
                .buttonStyle(FxPrimaryButtonStyle(height: 30))
                .keyboardShortcut(.defaultAction)
                .help("Close — this window won't show again until the next update (Return)")
                .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 680)
        .frame(minHeight: 440)
        .background(Color.fxBg)
        .onExitCommand { onClose() }
    }
}
