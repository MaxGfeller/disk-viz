import SwiftUI

struct BreadcrumbView: View {
    var path: [DiskNode]
    var onNavigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(path.enumerated()), id: \.element.path) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 3)
                }

                if index < path.count - 1 {
                    Button(node.name) {
                        onNavigate(index)
                    }
                    .buttonStyle(BreadcrumbButtonStyle())
                } else {
                    Text(node.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .lineLimit(1)
    }
}

private struct BreadcrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(Color.accentColor.opacity(configuration.isPressed ? 0.55 : 0.90))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 4))
    }
}
