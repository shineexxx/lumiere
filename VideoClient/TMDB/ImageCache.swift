import Foundation
import SwiftUI

/// Двухуровневый кэш постеров: память + диск в Caches.
/// AsyncImage каждый раз ходит в сеть при прокрутке — для сетки постеров это заметно.
actor ImageCache {

    static let shared = ImageCache()

    private let memory = NSCache<NSURL, NSImage>()
    private let directory: URL
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumiere/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        memory.countLimit = 400
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }

        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> { [directory] in
            let fileURL = directory.appendingPathComponent(Self.filename(for: url))
            if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
                return image
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            try? data.write(to: fileURL, options: .atomic)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func diskSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private nonisolated static func filename(for url: URL) -> String {
        let raw = url.absoluteString
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16) + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
    }
}

/// Картинка из кэша с плавным появлением и плейсхолдером.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let fetched = await ImageCache.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.25)) {
                image = fetched
                loaded = true
            }
        }
    }
}

extension CachedImage where Placeholder == PosterPlaceholder {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) { PosterPlaceholder() }
    }
}

struct PosterPlaceholder: View {
    var symbol: String = "film"
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}
