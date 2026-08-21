import SwiftUI

struct SidebarView: View {
    @Binding var filter: LibraryFilter
    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator

    var body: some View {
        List(selection: $filter) {
            Section("Библиотека") {
                ForEach([LibraryFilter.home, .continueWatching, .discover, .downloads], id: \.self) { item in
                    row(item)
                }
            }

            Section("Коллекция") {
                ForEach([LibraryFilter.all, .available, .movies, .shows], id: \.self) { item in
                    row(item)
                }
            }

            Section("Подборки") {
                ForEach([LibraryFilter.favorites, .finished, .needsMatch], id: \.self) { item in
                    row(item)
                }
            }

            if !store.roots.isEmpty {
                Section("Папки") {
                    ForEach(store.roots) { root in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((root.displayPath as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(root.displayPath)
                        .contextMenu {
                            Button("Показать в Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.displayPath)
                            }
                            Button("Убрать из библиотеки", role: .destructive) {
                                store.removeRoot(root)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !store.entries.isEmpty {
                HStack(spacing: 6) {
                    Text(Plural.items(store.entries.count))
                    Text("·")
                    Text(Plural.files(store.entries.reduce(0) { $0 + $1.allFiles.count }))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private func row(_ item: LibraryFilter) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge(for: item))
            .tag(item)
    }

    private func badge(for item: LibraryFilter) -> Int {
        switch item {
        case .home, .discover: 0
        case .downloads: 0
        case .available: store.entries.count(where: \.isAvailable)
        case .continueWatching: store.continueWatching.count
        case .all: store.entries.count
        case .movies: store.entries.count { $0.kind == .movie }
        case .shows: store.entries.count { $0.kind == .show }
        case .favorites: store.entries.count(where: \.isFavorite)
        case .finished: store.entries.count { store.isFinished($0) }
        case .needsMatch: store.entries.count { $0.matchState != .confirmed }
        }
    }
}
