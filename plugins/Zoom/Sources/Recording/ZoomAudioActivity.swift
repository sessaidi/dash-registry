import CoreAudio
import Foundation

/// Whether Zoom is using the microphone or the speakers right now, from Core Audio's per-process
/// state (macOS 14.2+). A meeting keeps both running whatever Zoom's windows look like (screen
/// sharing, the floating mini window, full screen, minimized), which window titles can't tell.
enum ZoomAudioActivity {
    /// True when any of `pids` has audio input or output running; nil when Core Audio can't say.
    static func isActive(pids: [pid_t]) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return nil }
        let wanted = Set(pids)
        for process in processes {
            guard let pid: pid_t = value(process, kAudioProcessPropertyPID), wanted.contains(pid) else { continue }
            let input: UInt32 = value(process, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = value(process, kAudioProcessPropertyIsRunningOutput) ?? 0
            if input != 0 || output != 0 { return true }
        }
        return false
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }
}
