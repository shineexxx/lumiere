import SwiftUI

/// Подтверждение совпадений с TMDB: слева очередь карточек, справа варианты.
struct MatchSheet: View {
    @Environment(LibraryCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var manualQuery = ""
    @State private var isSearching = false
    @State private var overrideCandidates: [MatchCandidate]?

    private var current: LibraryCoordinator.PendingMatch? { coordinator.pending.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let current {
                content(for: current)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Всё подтверждено").font(.title3.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onChange(of: coordinator.pending.count) { _, count in
            manualQuery = current?.entry.parsedTitle ?? ""
            overrideCandidates = nil
            if count == 0 { dismiss() }
        }
        .onAppear { manualQuery = current?.entry.parsedTitle ?? "" }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Подтвердите совпадение").font(.headline)
                if let current {
                    Text("Файл: \(current.entry.parsedTitle)"
                         + (current.entry.parsedYear.map { " (\($0))" } ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if coordinator.pending.count > 1 {
                Text("Осталось: \(coordinator.pending.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private func content(for match: LibraryCoordinator.PendingMatch) -> some View {
        let candidates = overrideCandidates ?? match.candidates

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Искать в TMDB вручную", text: $manualQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { runManualSearch(kind: match.entry.kind) }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Text("TMDB ничего не нашёл").font(.title3.weight(.medium))
                    Text("Попробуйте ввести название вручную — например, оригинальное английское.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(candidates) { candidate in
                            CandidateRow(candidate: candidate,
                                         isBest: candidate.id == candidates.first?.id) {
                                Task { await coordinator.confirm(candidate: candidate, for: match.entry.id) }
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Пропустить все") { coordinator.skipAllPending() }
                .disabled(coordinator.pending.isEmpty)
            Spacer()
            if let current {
                Button("Без метаданных") { coordinator.skipMatch(for: current.entry.id) }
            }
            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func runManualSearch(kind: MediaKind?) {
        let query = manualQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        Task {
            overrideCandidates = await coordinator.search(query: query, kind: kind)
            isSearching = false
        }
    }
}

struct CandidateRow: View {
    let candidate: MatchCandidate
    let isBest: Bool
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedImage(url: TMDB.imageURL(path: candidate.posterPath, size: .posterSmall))
                .frame(width: 62, height: 93)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(candidate.title).font(.system(size: 14, weight: .semibold))
                    if let year = candidate.year {
                        Text(String(year)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if isBest {
                        Text("лучшее совпадение")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .glassEffect(.regular.tint(.accentColor), in: .capsule)
                    }
                }
                if let original = candidate.originalTitle, original != candidate.title {
                    Text(original).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if let overview = candidate.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 10) {
                    if let rating = candidate.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    }
                    Label(candidate.kind == .movie ? "Фильм" : "Сериал",
                          systemImage: candidate.kind == .movie ? "film" : "tv")
                    Text("совпадение \(Int(candidate.score * 100))%")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Это оно", action: onPick)
                .buttonStyle(.glassProminent)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPick)
    }
}
