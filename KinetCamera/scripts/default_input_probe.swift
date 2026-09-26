import CoreAudio
import Foundation

func getName(_ id: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.stride)
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let err = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name)
    return err == 0 ? (name as String) : "err\(err)"
}

var devID = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
print("default input deviceID:", devID, "err:", err, "name:", getName(devID))

// 输入流格式
var fmt = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var fmtAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreamFormat,
    mScope: kAudioObjectPropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)
let fmtErr = AudioObjectGetPropertyData(devID, &fmtAddr, 0, nil, &formatSize, &fmt)
print("stream format err:", fmtErr, "samplerate:", fmt.mSampleRate, "ch:", fmt.mChannelsPerFrame)

// 全部输入设备及其传输类型
var allSize = UInt32(0)
var allAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &allAddr, 0, nil, &allSize)
var ids = [AudioDeviceID](repeating: 0, count: Int(allSize) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &allAddr, 0, nil, &allSize, &ids)

var transAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyTransportType,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var inAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreams,
    mScope: kAudioObjectPropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)
print("--- 有输入流的设备:")
for id in ids {
    var sSize = UInt32(0)
    AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &sSize)
    if sSize > 0 {
        var tt: UInt32 = 0
        var ttSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transAddr, 0, nil, &ttSize, &tt)
        let trans = { () -> String in
            switch tt {
            case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
            case kAudioDeviceTransportTypeVirtual: return "Virtual"
            case kAudioDeviceTransportTypeUSB: return "USB"
            case kAudioDeviceTransportTypeBluetooth: return "BT"
            default: return "type\(tt)"
            }
        }()
        print("  dev\(id) [\(trans)] \(getName(id)) streams:\(sSize / UInt32(MemoryLayout<AudioStreamID>.size))")
    }
}
