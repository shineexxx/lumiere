import Foundation
import WebKit

/// Современная страница VK подгружает список видео после открытия. Читаем её
/// в отдельной гостевой сессии WebKit, а файлы по-прежнему скачивает yt-dlp.
nonisolated struct VKPlaylist {
    let id: String
    let season: Int?

    init?(_ link: String) {
        guard let url = URL(string: link),
              let host = url.host()?.lowercased(),
              ["vkvideo.ru", "vk.ru", "vk.com"].contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
              url.scheme == "https" || url.scheme == "http",
              let match = url.path.wholeMatch(of: #/(?:\/video)?\/playlist\/(-?\d+_-?\d+)(?:\/season_(\d+))?\/?/#)
        else { return nil }
        id = String(match.1)
        season = match.2.flatMap { Int($0) }
        if match.2 != nil, season == nil { return nil }
    }

    @MainActor func probe() async throws -> DownloadManager.Probe {
        let path = "/playlist/\(id)" + (season.map { "/season_\($0)" } ?? "")
        let url = URL(string: "https://vkvideo.ru\(path)")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 850), configuration: configuration)
        webView.load(URLRequest(url: url))
        defer { webView.stopLoading() }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(45)
        var lastCount = 0
        var lastChange = clock.now

        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(400))
            guard let currentURL = webView.url,
                  currentURL.host() == "vkvideo.ru",
                  let current = Self(currentURL.absoluteString), current.id == id,
                  season == nil || current.season == season,
                  let page = (try? await webView.callAsyncJavaScript(Self.readPage, arguments: [:],
                                                                   in: nil, contentWorld: .defaultClient)) as? [String: Any]
            else { continue }

            let cards = page["cards"] as? [[String: String]] ?? []
            if cards.count != lastCount || page["loading"] as? Bool == true {
                lastCount = cards.count
                lastChange = clock.now
            }
            if page["empty"] as? Bool == true { break }

            guard !cards.isEmpty, clock.now - lastChange >= .seconds(2),
                  let title = page["title"] as? String, !title.isEmpty else { continue }

            // На странице сезона в боковой панели указано число роликов всех сезонов.
            if current.season == nil, let count = page["total"] as? Int, cards.count < count { continue }

            var seen = Set<String>()
            let videos = cards.compactMap { card -> (url: String, title: String)? in
                guard let path = card["path"],
                      let match = path.wholeMatch(of: #/\/video(-?\d+_\d+)/#),
                      seen.insert(String(match.1)).inserted else { return nil }
                return ("https://vkvideo.ru\(path)", card["title"] ?? "")
            }
            guard !videos.isEmpty else { break }
            return DownloadManager.Probe(title: title, itemCount: videos.count, isPlaylist: true,
                                         entries: videos.map(\.title), videoURLs: videos.map(\.url),
                                         season: current.season)
        }

        throw DownloadError.probeFailed(String(localized: "Не удалось получить список видео. Проверьте, что плейлист открыт и содержит доступные ролики."))
    }

    private static let readPage = #"""
        const cards = [...document.querySelectorAll('[data-testid="playlist-video-card"], [data-testid="playlist-video-card-owner"]')];
        const main = document.querySelector('[role="main"]');
        // VK запрашивает следующую порцию при прокрутке к концу списка.
        cards.at(-1)?.scrollIntoView({block: 'end'});
        if (cards.length) window.dispatchEvent(new Event('scroll'));
        const total = document.querySelector('[data-testid="playlist_side_block_videos_count"]')?.textContent;
        return {
            title: document.querySelector('[data-testid="video_playlist_side_block_title"]')?.textContent?.trim() || '',
            total: total ? Number(total.replace(/[^0-9]/g, '')) : null,
            loading: Boolean(main?.querySelector('[role="progressbar"]')),
            empty: !cards.length && /Доступ к\s+плейлисту ограничен|В плейлисте пока нет видео/.test(main?.innerText || ''),
            cards: cards.flatMap(card => {
                const links = [...card.querySelectorAll('a[href]')].filter(link =>
                    link.origin === location.origin && /^\/video-?\d+_\d+$/.test(link.pathname));
                const link = links.find(link => link.dataset.testid !== 'video_card_thumb') || links[0];
                return link ? [{path: link.pathname, title: link.textContent.trim()}] : [];
            })
        };
        """#
}
