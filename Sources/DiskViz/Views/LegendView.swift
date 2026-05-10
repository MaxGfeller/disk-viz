import SwiftUI

struct LegendView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(FileCategoryColor.legend, id: \.label) { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(FileCategoryColor.legendColor(hue: item.hue, saturation: item.saturation))
                        .frame(width: 7, height: 7)

                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
