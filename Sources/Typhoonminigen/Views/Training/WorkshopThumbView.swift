import SwiftUI
import AppKit

/// One image tile in the workshop gallery: a downsampled square thumbnail with a caption-state
/// dot, an optional "reference" ring/badge, and hover actions. Tapping opens the caption editor.
struct WorkshopThumbView: View {
    let ref: TrainingImageRef
    let url: URL
    let isReference: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var image: NSImage?
    @State private var hover = false

    private var captioned: Bool {
        ref.captionSource != .none && !ref.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Rectangle().fill(Color.fxInset)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18)).foregroundStyle(Color.fxText3.opacity(0.7))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Badges + border drawn AFTER the clip so they're never cropped.
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isReference ? Color.fxAccentLine : Color.fxBorder,
                                  lineWidth: isReference ? 1.6 : 1)
            )
            .overlay(alignment: .topLeading) { if isReference { referenceBadge } }
            .overlay(alignment: .bottomLeading) { captionDot }
            .overlay(alignment: .topTrailing) { if hover { deleteButton } }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { hover = $0 }
            .task(id: url) { image = await WorkshopDatasetService.thumbnail(at: url) }
            .help(captioned ? ref.caption : "No caption yet — click to write one, or use Auto-caption")
    }

    private var referenceBadge: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.fxOnAccent)
            .padding(4)
            .background(Color.fxAccent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(5)
            .help("Reference image (used to evaluate trainings)")
    }

    private var captionDot: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(captioned ? Color.fxOk : Color.clear)
                .overlay(Circle().strokeBorder(captioned ? Color.clear : Color.fxText3, lineWidth: 1))
                .frame(width: 7, height: 7)
            if captioned {
                Text(sourceTag).font(.fxMono(8)).foregroundStyle(Color.fxText2)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 5)
        .background(Color.black.opacity(0.45), in: Capsule())
        .padding(5)
    }

    private var sourceTag: String {
        switch ref.captionSource {
        case .auto:    return "AI"
        case .sidecar: return "TXT"
        case .manual:  return "✎"
        case .none:    return ""
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .help("Remove this image from the workshop")
    }
}
