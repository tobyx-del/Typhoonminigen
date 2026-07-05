import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// File-side helpers for a Workshop's image dataset: copying imported images into the
/// workshop's own folder (so the source can move/delete freely afterwards), picking up
/// sibling `.txt` captions on import, and producing downsampled thumbnails / VLM inputs
/// without ever holding the full-resolution bitmaps. Pure file + ImageIO work — no engine
/// or SwiftUI types — so it stays decoupled like `DescribeService`.
enum WorkshopDatasetService {

    /// Extensions accepted on import. macOS' ImageIO decodes all of these, and the engine's
    /// own training loader reads the same set — so HEIC phone shots import directly
    /// (they're transcoded to RGB at encode time), not just the PNG/JPEG/WEBP the reference app allows.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff"]

    // MARK: - Import

    /// One image staged for import: the source file plus the caption read from a sibling `.txt`.
    struct Staged: Sendable {
        let sourceURL: URL
        let caption: String
        let captionSource: CaptionSource
    }

    /// Copy `urls` (files and/or folders) into `workshop.imagesDir`, returning the new
    /// `TrainingImageRef`s to append. Folders are expanded to their immediate image children.
    /// A sibling `<name>.txt` next to an image is read in as that image's caption (kohya/diffusers
    /// convention). Destination STEMS are made unique against the refs + what's already on disk +
    /// this batch, so re-importing, two same-named source files, or a same-stem pair (`photo.jpg` /
    /// `photo.png` — they'd share one caption sidecar at freeze time) never collide.
    /// Non-decodable files are skipped.
    ///
    /// Runs file IO + a cheap decodability probe — call it OFF the main actor.
    static func importImages(urls: [URL], into workshop: Workshop) throws -> [TrainingImageRef] {
        let fm = FileManager.default
        try fm.createDirectory(at: workshop.imagesDir, withIntermediateDirectories: true)

        // Expand folders → image files; keep plain image files as-is.
        var sources: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? []
                sources.append(contentsOf: children)
            } else {
                sources.append(url)
            }
        }
        // Stable order so captions line up with what the user saw in Finder.
        sources.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // STEMS already taken — persisted refs ∪ whatever is physically in the images folder.
        // Stems (basename without extension), NOT full filenames: freezeDataset writes each
        // caption as a `<stem>.txt` sidecar, so `photo.jpg` + `photo.png` coexisting would freeze
        // ONE `photo.txt` — the second write clobbers the first and both images silently train on
        // the same caption. No two dataset files may ever share a stem.
        // The on-disk union matters too: `uniqueName` used to consult only persisted refs, so a
        // FAILED batch (refs rolled back, its detached file cleanup still pending) and its
        // immediate retry minted IDENTICAL names — either the copy threw on the still-present
        // file, or worse, the late cleanup deleted the retry's fresh copies. Probing the
        // filesystem covers both interleavings: files still present → the retry mints new names;
        // files already cleaned → the old names are genuinely free (that cleanup never re-fires).
        var takenStems = Set(workshop.images.map { ($0.fileName as NSString).deletingPathExtension.lowercased() })
        let onDisk = (try? fm.contentsOfDirectory(at: workshop.imagesDir, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? []
        for file in onDisk { takenStems.insert(file.deletingPathExtension().lastPathComponent.lowercased()) }
        var refs: [TrainingImageRef] = []

        for src in sources where imageExtensions.contains(src.pathExtension.lowercased()) {
            guard isDecodableImage(src) else { continue }
            let destName = uniqueName(for: src.lastPathComponent, takenStems: takenStems)
            let dest = workshop.imagesDir.appendingPathComponent(destName)
            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                AppLog.error("Workshop import: couldn't copy \(src.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            takenStems.insert((destName as NSString).deletingPathExtension.lowercased())

            // Sibling caption — store the BARE description; the trigger word is prepended by the
            // engine at train time, never baked into the stored caption.
            let sidecar = src.deletingPathExtension().appendingPathExtension("txt")
            let captionText = (try? String(contentsOf: sidecar, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let captionText, !captionText.isEmpty {
                refs.append(TrainingImageRef(fileName: destName, caption: captionText, captionSource: .sidecar))
            } else {
                refs.append(TrainingImageRef(fileName: destName))
            }
        }
        return refs
    }

    /// `IMG.jpg` → `IMG.jpg`, or `IMG-1.jpg`, `IMG-2.jpg`… if the STEM is taken. Uniqueness is on
    /// the stem, not the full filename, so `photo.jpg` can never join a workshop that already has
    /// `photo.png` — they'd share one `photo.txt` caption sidecar in the frozen dataset and one
    /// image would silently train on the other's caption. Case-insensitive to match the
    /// (case-insensitive) macOS filesystem default and our lowercased `takenStems` set.
    private static func uniqueName(for fileName: String, takenStems: Set<String>) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var stem = base
        var n = 1
        while takenStems.contains(stem.lowercased()) {
            stem = "\(base)-\(n)"
            n += 1
        }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Cheap "is this really an image" probe — reads the file's image source header without
    /// decoding the full bitmap.
    private static func isDecodableImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }

    // MARK: - Delete

    /// Remove one image file from a workshop's folder (best-effort; the ref is dropped by the caller).
    static func removeImageFile(named fileName: String, in workshop: Workshop) {
        try? FileManager.default.removeItem(at: workshop.imagesDir.appendingPathComponent(fileName))
    }

    // MARK: - Thumbnails (grid)

    /// Downsampled thumbnail for the gallery grid — decodes to ~`maxPixel` px (tiny memory), not the
    /// full multi-megapixel original. `nonisolated async` so the decode runs OFF the main actor, and
    /// the FRESH `NSImage` it returns transfers cleanly back to a `@State` (a disconnected region).
    /// Awaited per-cell from `.task(id:)`; the cell holds the result for its lifetime, so re-decoding
    /// only happens when a cell scrolls back into view — cheap at this scale, no cache needed.
    nonisolated static func thumbnail(at url: URL, maxPixel: Int = 280) async -> NSImage? {
        guard let cg = downsample(url: url, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - VLM input

    /// Downsampled CGImage fed to the captioning VLM — 1024 px is ample (the model downsamples to
    /// its own patch grid anyway) and caps the memory of captioning a whole gallery at once.
    nonisolated static func decodeForCaption(at url: URL, maxPixel: Int = 1024) -> CGImage? {
        downsample(url: url, maxPixel: maxPixel)
    }

    /// Orientation-corrected downsample via ImageIO (the same idiom as the gallery thumbnailer).
    private nonisolated static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
