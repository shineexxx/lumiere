import SwiftUI

/// Поиск по всему каталогу TMDB — строка в правом верхнем углу.
/// Библиотеку он не фильтрует: для неё своя строка внутри раздела.
struct GlobalSearchView: View {
    let query: String
    let onSelect: (MediaEntry) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator

    @State private var results: [MatchCandidate] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var preview: MatchCandidate?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let searchError {
                    errorState(searchError)
                } else if results.isEmpty && !isSearching {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(results) { candidate in
                            DiscoverCard(candidate: candidate,
                                         onSelect: onSelect,
                                         onPreview: { preview = $0 })
                        }
                    }
                }
            }
            .padding(26)
        }
        .scrollContentBackground(.hidden)
        .background { Rectangle().fill(.background).ignoresSafeArea() }
        // Каждая правка строки перезапускает задачу, предыдущая отменяется на паузе —
        // так на каждый набранный символ не улетает по запросу.
        .task(id: query) { await run() }
        .sheet(item: $preview) { candidate in
            PreviewSheet(candidate: candidate, onOpenInLibrary: onSelect)
                .environment(store)
                .environment(coordinator)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Поиск по TMDB").font(.system(size: 26, weight: .bold))
                if isSearching { ProgressView().controlSize(.small) }
            }
            Text(results.isEmpty
                 ? "Ищем везде — и то, чего нет у вас на диске."
                 : "«\(query)» · \(Plural.format(results.count, "результат", "результата", "результатов"))")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Ничего не нашлось").font(.title3.weight(.medium))
            Text("Попробуйте другое написание или оригинальное название.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Поиск не удался").font(.title3.weight(.medium))
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        guard await coordinator.client.hasKey else {
            searchError = "Не задан API-ключ TMDB. Откройте Настройки (⌘,) и добавьте ключ."
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await coordinator.searchEverything(query: text)
            guard !Task.isCancelled else { return }
            results = found
            searchError = nil
        } catch {
            guard !Task.isCancelled else { return }
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
