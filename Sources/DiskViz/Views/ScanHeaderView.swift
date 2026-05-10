import SwiftUI

struct ScanHeaderView: View {
    @ObservedObject var store: DiskUsageStore

    var body: some View {
        HStack(spacing: 12) {
            Text("disk-viz")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
                .textCase(.uppercase)
                .lineLimit(1)

            HStack(spacing: 6) {
                TextField("Enter absolute path...", text: $store.scanPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                    .frame(width: 320)
                    .disabled(store.scanning)
                    .onSubmit {
                        store.scan()
                    }

                Button("Browse...") {
                    store.chooseDirectoryAndScan()
                }
                .disabled(store.scanning)

                Button(store.scanning ? "Scanning..." : "Scan") {
                    store.scan()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(store.scanning || store.scanPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Spacer(minLength: 8)

            LegendView()
        }
        .buttonStyle(HeaderButtonStyle())
        .padding(.leading, 82)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(
            Color(red: 0.09, green: 0.13, blue: 0.24)
                .opacity(0.88)
                .background(.thinMaterial)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(configuration.isPressed ? 0.06 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 0.49, green: 0.78, blue: 0.89).opacity(configuration.isPressed ? 0.70 : 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(red: 0.49, green: 0.78, blue: 0.89).opacity(configuration.isPressed ? 0.12 : 0.20), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(red: 0.49, green: 0.78, blue: 0.89).opacity(0.30), lineWidth: 1)
            }
    }
}
