import SwiftUI

/// Myna's memory, in one place. Two faces of the same thing:
/// — Conversations: everything Myna scribed, newest first (Omi's main feed).
/// — Facts: the durable things Myna distilled about you (Omi's "second brain").
/// A single quiet segmented switch, so the dock stays simple.
struct MemoryHubView: View {
    enum Face: String, CaseIterable, Identifiable {
        case conversations = "Conversations"
        case facts = "Facts"
        var id: String { rawValue }
    }

    @State private var face: Face = .conversations

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $face) {
                ForEach(Face.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)

            switch face {
            case .conversations: NotesListView()
            case .facts: MemoriesView()
            }
        }
    }
}
