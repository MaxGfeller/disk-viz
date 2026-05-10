import SwiftUI

struct BreadcrumbView: View {
    var path: [DiskNode]
    var onNavigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(path.enumerated()), id: \.element.path) { index, node in
                if index > 0 {
                    Text(">")
                        .foregroundStyle(.white.opacity(0.20))
                        .font(.system(size: 12))
                }

                if index < path.count - 1 {
                    Button(node.name) {
                        onNavigate(index)
                    }
                    .buttonStyle(BreadcrumbButtonStyle())
                } else {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
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
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 0.49, green: 0.78, blue: 0.89).opacity(configuration.isPressed ? 0.45 : 0.75))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Color(red: 0.49, green: 0.78, blue: 0.89)
                    .opacity(configuration.isPressed ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: 3)
            )
    }
}
