import SwiftUI

struct CleanupDashboardView: View {
    @ObservedObject var store: CleanupStore

    @Environment(\.dismiss) private var dismiss
    @State private var reviewSuggestion: CleanupSuggestion?

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
            Divider()

            if store.analyzing && store.suggestions.isEmpty {
                analyzingState
            } else if store.suggestions.isEmpty {
                emptyState
            } else {
                opportunityGrid
            }

            Divider()
            dashboardFooter
        }
        .frame(width: 760, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Candidate identity and folder contents can change quickly. Re-check on
            // every presentation instead of making old cleanup results actionable.
            store.refresh()
        }
        .onDisappear {
            store.cancelAnalysis()
        }
        .sheet(item: $reviewSuggestion) { suggestion in
            CleanupReviewView(suggestion: suggestion, store: store)
        }
        .alert(item: $store.pendingAction) { action in
            confirmationAlert(action)
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup opportunities")
                    .font(.title3.weight(.semibold))

                if store.hasAnalyzed {
                    Text("About \(ByteFormatter.string(from: store.estimatedBytes)) worth reviewing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Read-only analysis of the internal disk")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if store.analyzing {
                ProgressView()
                    .controlSize(.small)
                    .help("Analyzing cleanup opportunities")
            }

            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.analyzing || store.executing)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(.bar)
    }

    private var opportunityGrid: some View {
        ScrollView {
            VStack(spacing: 12) {
                statusBanner

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(store.suggestions) { suggestion in
                        CleanupOpportunityCard(
                            suggestion: suggestion,
                            executing: store.executing || store.analyzing,
                            onReview: { reviewSuggestion = suggestion },
                            onDockerPrune: { store.requestDockerPrune(from: suggestion) },
                            onOpenDocker: store.openDockerDesktop,
                            onRemoveSimulators: {
                                store.requestDeleteUnavailableSimulators(from: suggestion)
                            },
                            onRemoveOutdatedRuntimes: {
                                store.requestDeleteOutdatedSimulatorRuntimes(from: suggestion)
                            },
                            onOpenTrash: store.openTrash
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let error = store.errorMessage {
            CleanupStatusBanner(text: error, systemImage: "exclamationmark.triangle.fill", color: .orange)
                .padding(.top, 8)
        } else if let notice = store.noticeMessage {
            CleanupStatusBanner(text: notice, systemImage: "checkmark.circle.fill", color: .green)
                .padding(.top, 8)
        } else if store.executing {
            CleanupStatusBanner(text: "Cleanup is running…", systemImage: "hourglass", color: .accentColor)
                .padding(.top, 8)
        }
    }

    private var analyzingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Measuring cleanup candidates…")
                .font(.headline)
            Text("This is a read-only pass. Nothing is selected or removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("cleanup-analyzing")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("No cleanup candidates found")
                .font(.headline)
            Text("Refresh after your next disk scan, or grant Files & Folders access if expected locations are missing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dashboardFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            Text("Estimates can differ from free space because of APFS clones and sparse files. Filesystem cleanup moves only your selected items to Trash; Trash is never emptied for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.bar)
    }

    private func confirmationAlert(_ action: CleanupPendingAction) -> Alert {
        Alert(
            title: Text(action.title),
            message: Text(action.message),
            primaryButton: .destructive(Text(action.confirmTitle)) {
                store.confirmPendingAction()
            },
            secondaryButton: .cancel {
                store.cancelPendingAction()
            }
        )
    }
}

private struct CleanupOpportunityCard: View {
    var suggestion: CleanupSuggestion
    var executing: Bool
    var onReview: () -> Void
    var onDockerPrune: () -> Void
    var onOpenDocker: () -> Void
    var onRemoveSimulators: () -> Void
    var onRemoveOutdatedRuntimes: () -> Void
    var onOpenTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.category.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(suggestion.category.color)
                    .frame(width: 32, height: 32)
                    .background(
                        suggestion.category.color.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(estimateLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(suggestion.estimatedBytes > 0 ? .primary : .secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                if suggestion.isPartial {
                    Label("Partial", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("Some locations were inaccessible; this estimate is partial")
                }
            }

            Text(suggestion.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            actionRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanup-card-\(suggestion.category.rawValue)")
    }

    @ViewBuilder
    private var actionRow: some View {
        switch suggestion.category {
        case .docker:
            HStack {
                Button("Open Docker Desktop", action: onOpenDocker)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Prune…", action: onDockerPrune)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(executing || suggestion.estimatedBytes == 0)
            }
        case .unavailableSimulators:
            HStack {
                Spacer()
                Button("Remove…", action: onRemoveSimulators)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(executing)
            }
        case .outdatedSimulatorRuntimes:
            HStack {
                Spacer()
                Button("Remove…", action: onRemoveOutdatedRuntimes)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(executing)
            }
        case .trash:
            HStack {
                Spacer()
                Button("Open Trash", action: onOpenTrash)
                    .buttonStyle(.bordered)
            }
        default:
            HStack {
                if suggestion.totalCandidateCount > 0 {
                    Text("\(suggestion.totalCandidateCount.formatted()) candidate\(suggestion.totalCandidateCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Review…", action: onReview)
                    .buttonStyle(.borderedProminent)
                    .disabled(executing || suggestion.candidates.isEmpty)
            }
        }
    }

    private var estimateLabel: String {
        guard suggestion.estimatedBytes > 0 else {
            return suggestion.isPartial ? "Estimate unavailable" : "No space found"
        }
        let size = ByteFormatter.string(from: suggestion.estimatedBytes)
        switch suggestion.estimateKind {
        case .eligibleAllocated:
            return "~\(size) in candidates"
        case .toolReportedReclaimable:
            return "\(size) reported reclaimable"
        case .currentlyInTrash:
            return "\(size) currently in Trash"
        }
    }
}

private struct CleanupReviewView: View {
    var suggestion: CleanupSuggestion
    @ObservedObject var store: CleanupStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPaths: Set<String> = []
    @State private var filter = ""

    private var displayedCandidates: [CleanupCandidate] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return suggestion.candidates }
        return suggestion.candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCandidates: [CleanupCandidate] {
        suggestion.candidates.filter { selectedPaths.contains($0.path) }
    }

    private var selectedBytes: Int64 {
        selectedCandidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()

            HStack {
                TextField("Filter candidates", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button(selectionButtonTitle) {
                    toggleDisplayedSelection()
                }
                .disabled(displayedCandidates.isEmpty || store.executing)
            }
            .padding(12)

            Divider()

            List(displayedCandidates) { candidate in
                CleanupCandidateRow(
                    candidate: candidate,
                    selected: binding(for: candidate),
                    onReveal: { store.reveal(candidate) }
                )
            }
            .listStyle(.inset)

            if suggestion.totalCandidateCount > suggestion.candidates.count {
                Text("Showing the largest \(suggestion.candidates.count.formatted()) of \(suggestion.totalCandidateCount.formatted()) candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            Divider()
            reviewFooter
        }
        .frame(width: 700, height: 560)
        .alert(item: $store.pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmTitle)) {
                    store.confirmPendingAction()
                },
                secondaryButton: .cancel {
                    store.cancelPendingAction()
                }
            )
        }
        .onChange(of: store.executing) { _, executing in
            if executing {
                dismiss()
            }
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.category.systemImage)
                .font(.title2)
                .foregroundStyle(suggestion.category.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.title3.weight(.semibold))
                Text("Nothing is selected by default. Review each path before cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.bar)
    }

    private var reviewFooter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedPaths.count.formatted()) selected")
                    .font(.callout.weight(.semibold))
                Text(ByteFormatter.string(from: selectedBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Text("Space is freed only after you empty Trash yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Move Selected to Trash…") {
                store.requestMoveToTrash(candidates: selectedCandidates, from: suggestion)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(selectedPaths.isEmpty || store.executing)
            .accessibilityIdentifier("cleanup-move-selected")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.bar)
    }

    private var selectionButtonTitle: String {
        let displayedPaths = Set(displayedCandidates.map(\.path))
        return !displayedPaths.isEmpty && displayedPaths.isSubset(of: selectedPaths)
            ? "Clear Shown"
            : "Select All Shown"
    }

    private func toggleDisplayedSelection() {
        let displayedPaths = Set(displayedCandidates.map(\.path))
        if displayedPaths.isSubset(of: selectedPaths) {
            selectedPaths.subtract(displayedPaths)
        } else {
            selectedPaths.formUnion(displayedPaths)
        }
    }

    private func binding(for candidate: CleanupCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(candidate.path) },
            set: { selected in
                if selected {
                    selectedPaths.insert(candidate.path)
                } else {
                    selectedPaths.remove(candidate.path)
                }
            }
        )
    }
}

private struct CleanupCandidateRow: View {
    var candidate: CleanupCandidate
    @Binding var selected: Bool
    var onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $selected) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(candidate.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let modifiedAt = candidate.modifiedAt {
                        Text("Last changed \(modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            Text(ByteFormatter.string(from: candidate.allocatedBytes))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(action: onReveal) {
                Image(systemName: "finder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(candidate.name) in Finder")
        }
        .frame(minHeight: 42)
    }
}

private struct CleanupStatusBanner: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private extension CleanupCategory {
    var systemImage: String {
        switch self {
        case .oldDownloads: return "arrow.down.circle"
        case .oldDiskImages: return "opticaldisc"
        case .developerArtifacts: return "hammer"
        case .xcodeDerivedData: return "wrench.and.screwdriver"
        case .docker: return "shippingbox"
        case .unavailableSimulators: return "iphone.slash"
        case .outdatedSimulatorRuntimes: return "shippingbox.and.arrow.backward"
        case .trash: return "trash"
        }
    }

    var color: Color {
        switch self {
        case .oldDownloads: return .blue
        case .oldDiskImages: return .purple
        case .developerArtifacts: return .orange
        case .xcodeDerivedData: return .indigo
        case .docker: return .cyan
        case .unavailableSimulators: return .pink
        case .outdatedSimulatorRuntimes: return .mint
        case .trash: return .secondary
        }
    }
}
