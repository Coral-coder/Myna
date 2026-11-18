import SwiftUI

/// Memory: everything Myna keeps. What it knows about you, the conversations it
/// wrote up, your lists, and the suggestions waiting for a yes or no — one row
/// of words to move between them, each page below it.
struct MemoryHubView: View {
    enum Section: String, CaseIterable {
        case memories = "Memories"
        case notes = "Notes"
        case lists = "Lists"
        case music = "Music"
        case inbox = "Inbox"
    }

    @AppStorage("myna.memory.section") private var stored = Section.memories.rawValue

    private var section: Section { Section(rawValue: stored) ?? .memories }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        stored = item.rawValue
                    } label: {
                        Text(item.rawValue)
                            .font(MynaTheme.mono(11))
                            .tracking(0.8)
                            .textCase(.uppercase)
                            .foregroundStyle(section == item ? MynaTheme.ink : MynaTheme.faint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            Rectangle().fill(MynaTheme.hair).frame(height: 1)

            Group {
                switch section {
                case .memories: MemoriesView()
                case .notes: NotesListView()
                case .lists: ListsView()
                case .music: HeardMusicView()
                case .inbox: SuggestionsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
