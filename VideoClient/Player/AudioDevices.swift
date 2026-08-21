import Foundation
import CoreAudio

/// Список устройств вывода звука в системе.
///
/// VLCKit не даёт API выбора аудиоустройства, поэтому идентификатор передаётся
/// прямо в libVLC опцией `--auhal-audio-device` при создании плеера
/// (`auhal` — модуль вывода звука VLC на macOS). Сами устройства перечисляем
/// через CoreAudio: в песочнице это чтение доступно без дополнительных прав.
nonisolated enum AudioDevices {

    struct Device: Identifiable, Hashable {
        /// AudioDeviceID — именно его понимает опция auhal.
        var id: UInt32
        var name: String
        var uid: String?
        var isDefault: Bool
    }

    /// Устройство «как в системе» — значение по умолчанию в настройках.
    static let systemDefaultID: UInt32 = 0

    /// Все устройства, у которых есть выходные каналы.
    static func outputDevices() -> [Device] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs()
            .filter { hasOutputChannels($0) }
            .compactMap { id in
                guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
                return Device(id: id,
                              name: name,
                              uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                              isDefault: id == defaultID)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Имя устройства по идентификатору — для показа в настройках.
    static func name(for id: UInt32) -> String? {
        guard id != systemDefaultID else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    /// Существует ли ещё сохранённое устройство (наушники могли отключить).
    static func exists(_ id: UInt32) -> Bool {
        id == systemDefaultID || allDeviceIDs().contains(id)
    }

    // MARK: - CoreAudio

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }

    /// Устройство считаем «выходным», если у него есть хотя бы один выходной канал.
    private static func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // CoreAudio возвращает +1 ссылку, поэтому забираем её через Unmanaged.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() as String? else { return nil }
        return text.isEmpty ? nil : text
    }
}
