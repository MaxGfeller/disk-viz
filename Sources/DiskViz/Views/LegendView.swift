import SwiftUI

struct LegendView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(FileCategoryColor.legend, id: \.label) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FileCategoryColor.legendColor(hue: item.hue, saturation: item.saturation))
                        .frame(width: 8, height: 8)

                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
    }
}
