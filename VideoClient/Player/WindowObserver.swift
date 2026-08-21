import SwiftUI
import AppKit

/// Сообщает о реальном закрытии окна.
///
/// `onDisappear` для этого не годится: SwiftUI вызывает его и при перестроении
/// иерархии (например, когда плеер переключается с AVPlayer на VLC), из-за чего
/// воспроизведение обрывалось на ровном месте. Подписка на `willCloseNotification`
/// срабатывает только когда окно действительно закрывают.
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view, onClose: onClose)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onClose = onClose
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        func attach(to view: NSView, onClose: @escaping () -> Void) {
            self.onClose = onClose
            // Окно появляется у view не сразу — ждём следующий цикл.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onClose?()
                }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

/// Даёт доступ к окну и включает поддержку полноэкранного режима.
///
/// Окно плеера объявлено с `.hiddenTitleBar`, и без явной настройки
/// `collectionBehavior` система не пускает его в полный экран —
/// `toggleFullScreen` просто ничего не делает.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window == nil { DispatchQueue.main.async { configure(view.window) } }
    }

    private func configure(_ found: NSWindow?) {
        guard let found else { return }
        found.collectionBehavior.insert(.fullScreenPrimary)
        found.styleMask.insert(.resizable)
        window = found
    }
}

/// Полноэкранный режим для произвольного окна.
@MainActor
enum FullScreen {
    static func toggle(_ window: NSWindow?) {
        guard let window else { return }
        // Поведение могло не успеть примениться, если окно только что создано.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.styleMask.insert(.resizable)
        window.toggleFullScreen(nil)
    }

    static func isActive(_ window: NSWindow?) -> Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }
}
