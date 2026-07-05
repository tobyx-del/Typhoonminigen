import SwiftUI

struct HelpView: View {
    var onShowTutorial: () -> Void = {}
    var onShowWhatsNew: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionTitle(text: "Help")
                    Spacer()
                    Text("quick reference").font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }

                Text("Typhoonminigen renders images with FLUX.2 Klein entirely on this Mac — and every control explains itself: hover anything for a tooltip.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 14)

                HStack(spacing: 10) {
                    Button {
                        onShowTutorial()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 12))
                            Text("Show the welcome tour again")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("Re-watch the welcome tour. Finishing it applies the update-check choice on its last page; skipping changes nothing.")

                    Button {
                        onShowWhatsNew()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "wand.and.sparkles").font(.system(size: 12))
                            Text("What's new in \(AppVersion.current)")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("The changes in this version — the same window that appears once after every update.")
                }

                HelpSection(title: "GETTING STARTED") {
                    HelpRow("Klein 4B vs 9B",
                            "4B is the smaller tier — less disk and RAM; 9B renders finer detail but costs more of both. Install either (or both) in Models.")
                    HelpRow("Downloading",
                            "The Models tab handles every download; each component — transformer, text encoder, VAE — is its own row and downloads separately, so start the ones you need and they run one after another. Downloads RESUME where they stopped if interrupted (even after quitting). When a model you need isn't on disk, the canvas lists exactly which parts are missing and how many GB to fetch.")
                    HelpRow("HF token",
                            "Only the gated Klein 9B needs a Hugging Face token — it's stored in the macOS Keychain and sent only to huggingface.co to authenticate the gated download (never to anyone else). 4B downloads without an account.")
                    HelpRow("First render",
                            "Loads the model into RAM first — expect about a minute before the first image; later renders skip it.")
                    HelpRow("Removing everything",
                            "Models live in your Library, and some weights are cached in the shared ~/.cache/huggingface — several GB that dragging the app to the Trash does NOT remove. To reclaim the space, use System → \u{201C}Remove all data\u{201D} BEFORE you delete the app: it wipes models and encoders, this app's entries in the shared HuggingFace cache (other tools' caches are untouched), your gallery, LoRAs, training data, presets, caches and logs.")
                }

                HelpSection(title: "GENERATE") {
                    HelpRow("Prompt",
                            "Plain natural language, any language — Klein renders best at 40–70 words.")
                    HelpRow("Presets & LOOKS",
                            "Chips that append curated style phrases to your prompt; toggle one off to remove its phrase.")
                    HelpRow("Aspect chips",
                            "Every ratio — including portrait 9:16 — targets ~1 megapixel, Klein's sweet spot. Render small, upscale after.")
                    HelpRow("Quality",
                            "Picks the quantization (sharpness vs RAM / disk / time): Klein 4B has Low / Medium / Better / Best, Klein 9B has Standard / Best. The transformer precision (8-bit qint8 → full bf16) is the real lever; the text-encoder bit-depth is the finer rung. On 9B a note explains when both rungs land on the same render — the engine loads whichever Qwen3-8B encoder is already on disk (it prefers 8-bit).")
                    HelpRow("Steps",
                            "How many denoise steps to run (1–50). Klein's sweet spot is 4 — it's step-distilled — so raise it only to chase extra detail, at the cost of time (no model reload). Always starts at 4 on launch.")
                    HelpRow("Seed",
                            "The same seed with the same settings reproduces an image exactly. Empty = a new random seed every render.")
                    HelpRow("Batch",
                            "The same prompt rendered N times — with a fixed seed the series runs seed, seed+1, …; with an empty Seed field every image gets a fresh random seed.")
                    HelpRow("Hide panels",
                            "The chevron next to the prompt collapses the size / presets / references panels for a cleaner view; the ⬇ button imports a recipe from any PNG. The two icons in the title bar fold away the left navigation and the right telemetry panel.")
                    HelpRow("Enhance prompt",
                            "Qwen3 rewrites the prompt with extra descriptive detail before rendering (text-only — ignored when references are attached). The prompt the model actually used is saved and shown in the gallery detail, so the rewrite is no longer a black box.")
                    HelpRow("Live preview",
                            "Decodes a preview during the render; turn on “Show every step” to watch all four steps (the first ones look noisy).")
                }

                HelpSection(title: "LIBRARY") {
                    HelpRow("Studios & scenes",
                            "Ready-made scene recipes grouped by studio — portrait, product, cinema, interiors, exteriors, food, cars and more. Every card's preview is a real render of that exact recipe, not an illustration.")
                    HelpRow("Load a scene",
                            "Tap a card to load its subject and style into Generate — edit the subject, then render or add to the queue. Cards also restore their pinned render settings (model, steps, quality, size); many pin the exact seed, so rendering unchanged reproduces the preview.")
                    HelpRow("Add to queue",
                            "The ⊕ on a card queues that scene directly; stack several and Run all from the Queue tab.")
                    HelpRow("Your own cards",
                            "\u{201C}New card\u{201D} opens an editor: subject, chips, a note, a cover image and optional pinned settings — filed under any section, or a new one you name. Even faster: \u{201C}Save as card\u{201D} on Generate snapshots the whole form — prompt, chips, model, steps, quality, size, seed — and takes the render on screen as the cover.")
                    HelpRow("Make it yours",
                            "The Edit button turns on delete controls: hide any built-in card or whole section — even Delete all. Nothing is destroyed; Restore all brings every built-in back. Your own cards (badged YOURS) can be edited any time, and deleting one is permanent.")
                    HelpRow("Honest limits",
                            "Each card carries a note on what the model can't nail, and a panel lists traps to avoid — legible text, logos and brands, real 3D or vector assets.")
                }

                HelpSection(title: "QUEUE") {
                    HelpRow("Add to queue",
                            "Builds a task from the current form without running it — line up many different prompts, then run them together.")
                    HelpRow("Run all",
                            "The Queue tab runs every task in order; finished images land in the Gallery.")
                    HelpRow("Duplicate",
                            "Copy a task with new random seeds (variants), the same seed, or sequential seeds — the fast way to make one prompt × N seeds.")
                    HelpRow("Reorder & stop",
                            "Move a task up / down — or jump it straight to the front with the ⤒ button — and remove any with ✕. Stop finishes the current image and keeps the rest queued — Run all resumes.")
                    HelpRow("Live progress",
                            "The running task shows its denoise step (“step X / N”) and an estimated time left; the sidebar Queue gets a live dot while a run is going.")
                }

                HelpSection(title: "REFERENCES (I2I)") {
                    HelpRow("Slots",
                            "Up to 4 reference images; the first one snaps the output size to match.")
                    HelpRow("No masks",
                            "The engine regenerates the whole scene guided by the references — there is no inpainting or partial edit.")
                    HelpRow("Describe with AI",
                            "A local vision model appends an editable description of the reference to the prompt.")
                    HelpRow("Flip to compare",
                            "Click a reference thumbnail on the result — on the canvas or in the gallery detail — to flip between your reference and the render in place, the honest way to check how close it came.")
                }

                HelpSection(title: "AI INSIGHTS") {
                    HelpRow("Where",
                            "After a render, an “AI insights” card appears under the Generate controls. It uses the same local Qwen3.5 vision model as Describe (~3 GB) — fully local, one job at a time, and disabled while a render or queue is running (Cancel stops it).")
                    HelpRow("Ask",
                            "Type any question about the current image — “what's the lighting?”, “is the text legible?” — and the model answers in place.")
                    HelpRow("Compare to reference",
                            "For image-to-image: scores how closely the result matches your first reference on scene and style (0–10), with a short reason for each.")
                }

                HelpSection(title: "LORA") {
                    HelpRow("Compatibility",
                            "Klein-architecture adapters only — 9B = dim 4096, 4B = dim 3072. FLUX.1 / Dev adapters won't load.")
                    HelpRow("Stacking",
                            "Add as many compatible adapters as you like, each with its own strength — their effects combine. A sweep button renders the same prompt at rising strengths so you can pick the best, and a pin saves an adapter's default strength.")
                    HelpRow("Toolbox",
                            "Bake a chosen strength into a copy, merge several same-tier adapters into one, keep an identity card per adapter, and import a LoRA straight from a Hugging Face URL — its compatibility is checked before the download.")
                    HelpRow("Trigger words",
                            "Saved per adapter and appended to the prompt automatically while the LoRA is active. Write [trigger] anywhere in a prompt to drop the word exactly there instead. Each adapter also has a button to copy its trigger word and one to reveal its file in Finder.")
                    HelpRow("Switching",
                            "Changing the adapter set or a strength reloads clean model weights first — instant when cached, up to ~1 min from a cold disk.")
                }

                HelpSection(title: "TRAINING (LoRA)") {
                    HelpRow("Workshops",
                            "A workshop holds one concept: 10–50 photos of your subject, a single trigger word and a description. Sidecar .txt captions import automatically; Auto-caption writes the rest with the local vision model. Captions are stored WITHOUT the trigger — the engine adds it at train time (a lint offers to strip it if it sneaks into a caption).")
                    HelpRow("Captions",
                            "Auto-caption batches run through the training queue, and every caption saves the moment it's written — a cancel or quit keeps what's done. The instruction the vision model follows is editable per workshop (with presets per concept type), and bulk find & replace or append/prepend fixes a whole dataset at once.")
                    HelpRow("Trainings",
                            "\u{201C}New training\u{201D} freezes the workshop's images and captions into an immutable run — tier, steps, resolution, rank. Its live monitor opens by itself: loss curve, checkpoint markers, Pause / Checkpoint / Stop (a graceful Stop saves a checkpoint first and shows its progress).")
                    HelpRow("Memory honesty",
                            "Klein 4B trains on a 32 GB Mac (peaks ~22 GB at 512px — pick 512 for the documented 1–3 h). Klein 9B training peaks ~34 GB and would freeze a 32 GB machine, so the app refuses to create it here — train 9B on a 48 GB+ Mac, or rent a GPU box and import the result.")
                    HelpRow("Queue",
                            "While one training runs, others offer \u{201C}Add to queue\u{201D} — they start automatically one after another (still one at a time, memory-safe). Generation cooperates: Run all pressed during a training arms the render queue to fire the moment the trainer is idle.")
                    HelpRow("Checkpoints & publish",
                            "A finished training shows a compare matrix — one column per validation prompt, one row per checkpoint, with the engine's no-LoRA baseline pinned on top (if a checkpoint looks like that row, it hasn't learned your subject). Publish the best one into the LoRA library with its trigger set — the final step isn't always the best (it can overfit).")
                    HelpRow("Extend",
                            "A finished training can continue (+250 / +500 / +1000 steps) from its last checkpoint with optimizer momentum intact — the fix for \u{201C}looks undertrained\u{201D}. The total rounds up to the checkpoint grid.")
                    HelpRow("Trained elsewhere",
                            "LoRAs trained on a rented GPU (ai-toolkit / kohya) import via the LoRA tab — drop the .safetensors; the trigger and base-model tags are read from its metadata when present, and published LoRAs carry the same tags back out.")
                    HelpRow("More tools",
                            "Clone a finished training as a draft to A/B one setting, reuse saved validation-prompt sets, keep only the last N checkpoints (previews always stay), mirror-augment the dataset at forge time, and export a model card with any published adapter.")
                }

                HelpSection(title: "GALLERY & RECIPES") {
                    HelpRow("PNG recipe",
                            "Every generated PNG embeds its recipe — prompt, seed, size, model, LoRA. References aren't embedded; Remix reloads them from their original files while those still exist on disk.")
                    HelpRow("Remix",
                            "Loads an image's recipe back into the Generate form.")
                    HelpRow("Iterations",
                            "When you've rendered the same prompt several times (different seeds), the detail view labels each one “iteration N / M” so the variants are easy to tell apart.")
                    HelpRow("Enhanced prompt",
                            "If “Enhance prompt” was on, the detail view shows the rewritten prompt the model actually used, beneath your original.")
                    HelpRow("Drop / Import",
                            "Drop any Typhoonminigen PNG onto the canvas, or use the ⬇ button by the prompt, to restore its recipe — even for an image you deleted.")
                    HelpRow("Select",
                            "“Select” in the Gallery toolbar turns on multi-select — Shift-click a range, then delete or export them all at once. Multi-select also offers ×2 / ×4 upscale, which runs as queue tasks.")
                    HelpRow("Search & filter",
                            "Search the gallery by prompt, LoRA name or exact seed, and filter by model, adapter or quality — the count updates live, and Select and ‹ › navigation follow the filtered view. Each LoRA also shows how many renders used it.")
                    HelpRow("Zoom",
                            "Scroll the wheel over a result to zoom in; double-click to reset.")
                    HelpRow("Drag out",
                            "Drag images from the canvas, gallery, or detail view — into Finder, a chat, an editor…")
                    HelpRow("JPEG",
                            "Re-saving a PNG as JPEG strips the recipe — keep the PNG if you want Remix later.")
                    HelpRow("Delete",
                            "Removal is immediate and permanent — there is no Trash.")
                }

                HelpSection(title: "UPSCALE") {
                    HelpRow("Real-ESRGAN",
                            "×2 or ×4 upscaling saves a new PNG next to the original — the original is untouched.")
                }

                HelpSection(title: "SYSTEM & PRIVACY") {
                    HelpRow("Local only",
                            "Generation runs on this Mac — images and prompts never leave it.")
                    HelpRow("Network",
                            "Used only to download models (Hugging Face), the upscaler (GitHub) and — if enabled — an update check (api.github.com), at most once an hour.")
                    HelpRow("Repair Library",
                            "System → Repair Library re-syncs the gallery with the Images folder: recipe-bearing PNGs you moved in by hand are re-adopted with full metadata, dead records are pruned, and unreadable strays go to a Quarantine folder — files are never deleted.")
                    HelpRow("Unload",
                            "Frees the RAM the model holds; it stays on disk and reloads on the next render.")
                    HelpRow("Clear caches",
                            "Removes rebuildable thumbnails — full-size images stay.")
                    HelpRow("Logs",
                            "Kept in a local file (plus one rotated backup) you can clear from System.")
                    HelpRow("Health chip",
                            "After long marathons a red ⚠ chip can appear in the status bar when swap use or free disk reach risky levels — its tooltip shows the numbers and the fix (finish the current run, then restart the app). It disappears once both recover.")
                }

                HelpSection(title: "SHORTCUTS") {
                    HelpKeyRow("⌘⏎", "Generate — or add to the queue while a run is busy.")
                    HelpKeyRow("Esc", "Stop — the current frame finishes and is kept; pending tasks stay queued (Run all resumes).")
                }

                HelpSection(title: "ABOUT & SUPPORT") {
                    HelpLinkRow("Project", "github.com/abgitdev/Typhoonminigen",
                                url: "https://github.com/abgitdev/Typhoonminigen")
                    HelpLinkRow("Support", "ko-fi.com/abgitdev",
                                url: "https://ko-fi.com/abgitdev")
                    HelpRow("License", "Free and open source under the MIT license. Made by abgitdev.")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                .padding(.bottom, 2)
            content
        }
        .padding(.top, 22)
    }
}

private struct HelpRow: View {
    let term: String
    let detail: String

    init(_ term: String, _ detail: String) {
        self.term = term
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(term)
                .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.fx(12)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

private struct HelpKeyRow: View {
    let keys: String
    let detail: String

    init(_ keys: String, _ detail: String) {
        self.keys = keys
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(keys)
                .font(.fxMono(12)).foregroundStyle(Color.fxText)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.fx(12)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

/// Same left/right layout as HelpRow, but the right side is a clickable link
/// (amber, underlines on hover) that opens `url` in the browser.
private struct HelpLinkRow: View {
    let term: String
    let linkText: String
    let url: String
    @Environment(\.openURL) private var openURL
    @State private var hover = false

    init(_ term: String, _ linkText: String, url: String) {
        self.term = term
        self.linkText = linkText
        self.url = url
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(term)
                .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                .frame(width: 130, alignment: .leading)
            Button {
                if let u = URL(string: url) { openURL(u) }
            } label: {
                Text(linkText)
                    .font(.fx(12)).foregroundStyle(Color.fxAccent)
                    .underline(hover)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}
