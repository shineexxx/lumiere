import SwiftUI

/// Постер с рейтингом, полоской прогресса и меткой «просмотрено».
struct PosterCard: View {
    let entry: MediaEntry
    @Environment(LibraryStore.self) private var store
    @State private var hovering = false

    private var progress: Double { store.progressFraction(entry) }
    private var finished: Bool { store.isFinished(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                CachedImage(url: TMDB.imageURL(path: entry.posterPath, size: .poster))
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 14))

                if progress > 0.01 && !finished {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(.capsule)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .topTrailing) { badges }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(hovering ? 0.35 : 0.08), lineWidth: 1)
            }
            .overlay {
                if hovering {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.25))
                        Image(systemName: "play.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .padding(16)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
            .scaleEffect(hovering ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let year = entry.displayYear {
                        Text(String(year))
                    }
                    if entry.kind == .show {
                        Text("·")
                        // Показываем, сколько серий реально скачано из всех известных.
                        let have = entry.availableEpisodes.count
                        if have == entry.episodes.count {
                            Text(Plural.episodes(have))
                        } else {
                            Text("\(have) из \(entry.episodes.count)")
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .onHover { value in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = value }
        }
    }

    @ViewBuilder
    private var badges: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let rating = entry.rating, rating > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 8))
                    Text(String(format: "%.1f", rating)).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }
            if finished {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .padding(6)
                    .glassEffect(.regular.tint(.accentColor), in: .circle)
            }
            if entry.matchState != .confirmed && entry.matchState != .skipped {
                Image(systemName: "questionmark")
                    .font(.system(size: 10, weight: .bold))
                    .padding(6)
                    .glassEffect(.regular.tint(.orange), in: .circle)
                    .help("Метаданные не подтверждены")
            }
            if !entry.isAvailable {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 10, weight: .medium))
                    .padding(6)
                    .glassEffect(.regular, in: .circle)
                    .foregroundStyle(.secondary)
                    .help("Файлов нет на диске — карточка хранится как метаданные")
            }
            if entry.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.pink)
                    .padding(6)
                    .glassEffect(.regular, in: .circle)
            }
        }
        .padding(8)
    }
}
