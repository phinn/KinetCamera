import CoreAudio
import Foundation

var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
let count = Int(size) / MemoryLayout<AudioDeviceID>.size
var devices = [AudioDeviceID](repeating: 0, count: count)
status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)

func getString(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: CFString? = "x" as CFString
    let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
        var sz = UInt32(MemoryLayout<CFString?>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, ptr)
    }
    guard status == noErr, let s = name else { return "?" }
    return s as String
}

for dev in devices {
    let name = getString(dev, kAudioObjectPropertyName)
    // 输入流数
    var ia = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var isz: UInt32 = 0
    AudioObjectGetPropertyDataSize(dev, &ia, 0, nil, &isz)
    let inStreams = Int(isz) / MemoryLayout<UInt32>.size
    print("dev \(dev): \(name) inStreams=\(inStreams)")
    if name.contains("MacBook Air麦克风") {
        // 输入静音
        var ma = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var mute: UInt32 = 99, msz = UInt32(MemoryLayout<UInt32>.size)
        let r1 = AudioObjectGetPropertyData(dev, &ma, 0, nil, &msz, &mute)
        // 输入音量
        var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = -1, vsz = UInt32(MemoryLayout<Float32>.size)
        let r2 = AudioObjectGetPropertyData(dev, &va, 0, nil, &vsz, &vol)
        // 运行中?
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var run: UInt32 = 99, rsz = UInt32(MemoryLayout<UInt32>.size)
        let r3 = AudioObjectGetPropertyData(dev, &ra, 0, nil, &rsz, &run)
        print("  mute=\(mute)(r=\(r1)) vol=\(vol)(r=\(r2)) isRunning=\(run)(r=\(r3))")
        // data source
        var da = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var ds: UInt32 = 0, dsz = UInt32(MemoryLayout<UInt32>.size)
        let r4 = AudioObjectGetPropertyData(dev, &da, 0, nil, &dsz, &ds)
        let dsStr = String(bytes: [UInt8(ds >> 24), UInt8((ds >> 16) & 0xFF), UInt8((ds >> 8) & 0xFF), UInt8(ds & 0xFF)], encoding: .ascii) ?? "?"
        print("  dataSource=\(dsStr)(r=\(r4))")
    }
}
