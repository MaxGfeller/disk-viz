import AppKit
import SwiftUI

struct NodeActionsMenu: View {
    var node: DiskNode
    @ObservedObject var store: DiskUsageStore
    @Binding var pendingTrash: DiskNode?

    private var supportsFileActions: Bool {
        !isSyntheticDiskNode(node)
    }

    private var manualDeletionRestriction: String? {
        FileActionPolicy.manualDeletionRestriction(for: node.path)
    }

    var body: some View {
        Text(node.name)
        Text(ByteFormatter.string(from: node.size))

        if supportsFileActions {
            Divider()

            Button("Reveal in Finder") {
                store.revealInFinder(node)
            }

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }

            Divider()

            if let manualDeletionRestriction {
                Label("Managed by macOS", systemImage: "checkmark.shield")
                Text(manualDeletionRestriction)
                    .font(.caption)
            } else {
                Button("Move to Trash…", role: .destructive) {
                    pendingTrash = node
                }
                .disabled(store.scanning)
            }
        }
    }
}

func isSyntheticDiskNode(_ node: DiskNode) -> Bool {
    node.path.hasSuffix("/__other__") || node.path.contains("__layout_other_")
}
