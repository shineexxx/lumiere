import SwiftUI

/// Раздел «Загрузки»: ссылка на VK Видео или Rutube — и файл едет прямо в библиотеку.
struct DownloadsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @Environment(DownloadManager.self) private var downloads

    @State private var link = ""
    @State private var probe: DownloadManager.Probe?
    @State private var isProbing = false
    @State private var probeError: String?

    @State private var kind: Kind = .movie
    @State private var showName = ""
    @State private var season = 1
    @State private var startEpisode = 1
    @State private var rootID: UUID?

    private enum Kind: String, CaseIterable, Identifiable {
        case movie, series
        var id: String { rawValue }
        var title: String { self == .movie ? "Фильм" : "Сериал" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let message = ExternalTools.missingToolsMessage {
                    toolsWarning(message)
                } else {
                    linkForm
                }
                if !downloads.jobs.isEmpty { jobList }
            }
            .padding(26)
        }
        .scrollContentBackground(.hidden)
        .background { Rectangle().fill(.background).ignoresSafeArea() }
        .onAppear { if rootID == nil { rootID = store.roots.first?.id } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Загрузки").font(.system(size: 26, weight: .bold))
            Text("Вставьте ссылку на видео или плейлист с VK Видео или Rutube — файлы лягут в папку библиотеки с правильными именами.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolsWarning(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Нужны внешние утилиты", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Скопировать команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string)
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .frame(maxWidth: 700, alignment: .leading)
    }

    // MARK: - Форма

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://vkvideo.ru/… или https://rutube.ru/…", text: $link)
                    .textFieldStyle(.plain)
                    .onSubmit { runProbe() }
                if isProbing { ProgressView().controlSize(.small) }
                Button("Проверить") { runProbe() }
                    .buttonStyle(.glass)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))

            if let source = VideoSource.detect(link) {
                Label("Источник: \(source.title)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let probeError {
                Label(probeError, systemImage: "xmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let probe { probeResult(probe) }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    @ViewBuilder
    private func probeResult(_ probe: DownloadManager.Probe) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: probe.isPlaylist ? "list.and.film" : "film")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(probe.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if probe.isPlaylist {
                        Text("Плейлист · \(Plural.format(probe.itemCount, "видео", "видео", "видео"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Что это", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if kind == .series {
                HStack(spacing: 12) {
                    TextField("Название сериала", text: $showName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Stepper("Сезон \(season)", value: $season, in: 1...50)
                        .frame(width: 130)
                    Stepper("С серии \(startEpisode)", value: $startEpisode, in: 1...200)
                        .frame(width: 150)
                }
                Text({
                    let name = FileRenamer.sanitize(showName.isEmpty ? probe.title : showName)
                    let code = "S\(String(format: "%02d", season))E\(String(format: "%02d", startEpisode))"
                    return "Разложим так: «\(name) / Сезон \(season) / \(name) - \(code).mp4» — понятно и в Finder, без приложения."
                }())
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.roots.isEmpty {
                Label("Сначала добавьте папку библиотеки (⌘O) — туда и будем качать",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Picker("Куда сохранить", selection: $rootID) {
                    ForEach(store.roots) { root in
                        Text((root.displayPath as NSString).lastPathComponent).tag(Optional(root.id))
                    }
                }
                .frame(width: 380)
            }

            Button {
                startDownload(probe)
            } label: {
                Label(probe.isPlaylist ? "Скачать всё" : "Скачать",
                      systemImage: "arrow.down.circle.fill")
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(store.roots.isEmpty || (kind == .series && showName.isEmpty && probe.title.isEmpty))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: - Список загрузок

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Очередь").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("Очистить завершённые") { downloads.clearFinished() }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(downloads.jobs) { job in
                DownloadRow(job: job) { downloads.cancel(job.id) }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    // MARK: - Действия

    private func runProbe() {
        let url = link.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        isProbing = true
        probeError = nil
        probe = nil
        Task {
            do {
                let result = try await DownloadManager.probe(url: url)
                probe = result
                applyParsedTitle(result)
            } catch {
                probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isProbing = false
        }
    }

    /// Заголовок ролика обычно уже содержит всё нужное: название, год, сезон и серию.
    /// Прогоняем его через тот же парсер, что разбирает имена файлов, и заполняем форму —
    /// пользователю остаётся только проверить, а не вводить заново.
    private func applyParsedTitle(_ probe: DownloadManager.Probe) {
        let parsed = FilenameParser.parse(fileName: probe.title)

        if parsed.isEpisode {
            // В заголовке явно указаны сезон и серия.
            kind = .series
            showName = parsed.title
            season = parsed.season ?? 1
            startEpisode = parsed.episode ?? 1
        } else if probe.isPlaylist {
            // Плейлист почти всегда означает сезон сериала целиком.
            kind = .series
            if showName.isEmpty { showName = parsed.title }
        } else {
            kind = .movie
        }
    }

    private func startDownload(_ probe: DownloadManager.Probe) {
        guard let rootID, let root = store.root(id: rootID) else { return }
        let destination = URL(fileURLWithPath: root.displayPath)

        let naming: DownloadManager.Naming = switch kind {
        case .movie: .movie
        case .series: .series(show: showName.isEmpty ? probe.title : showName,
                              season: season,
                              startEpisode: startEpisode)
        }

        downloads.enqueue(url: link.trimmingCharacters(in: .whitespaces),
                          naming: naming,
                          destination: destination,
                          title: probe.title,
                          itemCount: probe.itemCount)
        link = ""
        self.probe = nil
    }
}

/// Строка очереди загрузок.
struct DownloadRow: View {
    let job: DownloadManager.Job
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(job.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)

                if job.status.isActive {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 4)
                }
            }

            Spacer()

            if job.status.isActive {
                Button("Отменить", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var icon: String {
        switch job.status {
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        default: job.isPlaylist ? "list.and.film" : "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch job.status {
        case .finished: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}
