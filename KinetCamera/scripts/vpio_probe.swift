import AudioUnit
import Foundation

// 层10:VoiceProcessingIO 单元直采(Apple 语音处理管线,与 AQ/HAL/AVF 不同路)
// 判别:VPIO 也全零 → 数据在 ExclaveDSP(语音处理硬件单元)就被吞,走重启/硬件诊断;
//       VPIO 出数 → 标准采集路径坏,VPIO 是可用的绕行修复路径(app 录像音轨直接换 VPIO)。
// 结构:output bus 0 挂 render 回调 → 回调内 AudioUnitRender 从 input bus 1 拉数据。

final class Holder {
    var peak: Float = 0
    var frames = 0
    var renderErr: OSStatus = 0
}

var gAU: AudioComponentInstance?
var gHolder: Holder?
var gScratch: UnsafeMutableRawPointer?

func renderCb(refCon: UnsafeMutableRawPointer,
              actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              timestamp: UnsafePointer<AudioTimeStamp>,
              busNumber: UInt32,
              frameCount: UInt32,
              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let h = gHolder else { return noErr }
    var af = actionFlags.pointee
    guard let au = gAU else { return noErr }
    // VPIO input render:自备 mono Float32 AudioBufferList(ioData 在 input bus 上不可复用)
    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(frameCount) * 4,
        mData: gScratch))
    defer { gScratch = nil }
    let err = AudioUnitRender(au, &af, timestamp, 1, frameCount, &abl)
    if err != 0 {
        h.renderErr = err
        return noErr
    }
    if let mData = abl.mBuffers.mData {
        let floats = mData.bindMemory(to: Float.self, capacity: Int(frameCount))
        for i in 0..<Int(frameCount) {
            let v = abs(floats[i])
            if v > h.peak { h.peak = v }
        }
        h.frames += Int(frameCount)
    }
    return noErr
}

func run() {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_VoiceProcessingIO,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    guard let found = AudioComponentFindNext(nil, &desc) else { print("no VPIO component"); exit(1) }
    var auOpt: AudioComponentInstance?
    let newErr = AudioComponentInstanceNew(found, &auOpt)
    guard let au = auOpt else { print("instance new err \(newErr)"); exit(1) }

    var enable: UInt32 = 1
    var disable: UInt32 = 1
    let pSize = UInt32(MemoryLayout<UInt32>.size)
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, pSize)
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, pSize)

    let holder = Holder()
    gAU = au
    gScratch = UnsafeMutableRawPointer.allocate(byteCount: 48000 * 8, alignment: 16)
    gHolder = holder
    let retained = Unmanaged.passRetained(holder)
    var cbStruct = AURenderCallbackStruct(
        inputProc: renderCb,
        inputProcRefCon: UnsafeMutableRawPointer(retained.toOpaque()))
    let cbErr = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    let initErr = AudioUnitInitialize(au)
    let startErr = AudioOutputUnitStart(au)
    print("cb/init/start errs: \(cbErr)/\(initErr)/\(startErr)")
    print("VPIO 采集中 5 秒(请说话/敲桌子)...")
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    let db = holder.peak > 0 ? 20 * log10(holder.peak) : -200
    print("frames=\(holder.frames) peak=\(String(format: "%.4f", holder.peak)) dB=\(String(format: "%.1f", db)) renderErr=\(holder.renderErr)")
    AudioOutputUnitStop(au)
}

@main
struct VpioProbe {
    static func main() { run() }
}
