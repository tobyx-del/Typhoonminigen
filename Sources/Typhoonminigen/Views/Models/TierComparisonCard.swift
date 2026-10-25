import SwiftUI

/// 4B figures derive from original measurements. The 9B Int4 path is new
/// and has not been benchmarked on a 16 GB Mac: never show BF16 timings as its results.
struct TierComparisonCard: View {
    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let k4: String
        let k9: String
    }

    private static let rows: [Row] = [
        Row(label: "Disk (transformer + encoder)", k4: "~4 + 4 GB", k9: "~5 + 4.3 GB"),
        Row(label: "RAM while generating", k4: "~6 GB · brief ~12 GB spike", k9: "not measured (Int4)"),
        Row(label: "Comfortable on", k4: "16 GB Macs", k9: "16 GB (experimental)"),
        Row(label: "HuggingFace token", k4: "not needed", k9: "not for Int4"),
        Row(label: "License", k4: "Apache 2.0", k9: "FLUX Non-Commercial"),
        Row(label: "LoRA adapters", k4: "dim 3072 only", k9: "dim 4096 only"),
        Row(label: "References (I2I)", k4: "up to 4", k9: "up to 4"),   // GenerateViewModel.maxReferences
        Row(label: "Speed / quality", k4: "~1 min per 1024² image", k9: "awaiting M1 Pro test"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHICH MODEL?")
                .font(.fx(11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Color.fxText3)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("")
                    Text("Klein 4B").font(.fxMono(11.5)).foregroundStyle(Color.fxAccent)
                    Text("Klein 9B").font(.fxMono(11.5)).foregroundStyle(Color.fxAccent)
                }
                ForEach(Self.rows) { row in
                    GridRow {
                        Text(row.label).font(.fx(11.5)).foregroundStyle(Color.fxText3)
                        Text(row.k4).font(.fxMono(11)).foregroundStyle(Color.fxText2)
                        Text(row.k9).font(.fxMono(11)).foregroundStyle(Color.fxText2)
                    }
                }
            }
            Text("LoRA adapters are NOT interchangeable between tiers — a 9B adapter won't load on 4B and vice versa.")
                .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)   // match the screen's text measure
        .fxCard()
    }
}
