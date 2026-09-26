import CoreAudio
import AudioToolbox
import Foundation

final class Box {}

var peak: Float = 0
var frames = 0

func inputCallback(_ ud: UnsafeMutableRawPointer?, _ q: AudioQueueRef, _ buf: AudioQueueBufferRef, _ ts: UnsafePointer<AudioTimeStamp>, _ np: UInt32, _ pd: UnsafePointer<AudioStreamPacketDescription>?) {
    frames += 1
    let n = Int(buf.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
    let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
    for i in 0..<n where abs(p[i]) > peak { peak = abs(p[i]) }
    AudioQueueEnqueueBuffer(q, buf, 0, nil)
}

@main struct Main {
    static func main() {
        // 找物理麦 device id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)

        var micID: AudioDeviceID = 0
        for dev in devices {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: CFString? = nil
            let st = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
                var sz = UInt32(MemoryLayout<CFString?>.size)
                return AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &sz, ptr)
            }
            if st == noErr, let n = name, (n as String).contains("MacBook Air麦克风") { micID = dev; break }
        }
        guard micID != 0 else { print("no mic"); exit(1) }

        // 枚举全部 data source
        var dsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSources, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var dsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(micID, &dsAddr, 0, nil, &dsSize) == noErr else { print("no ds size"); exit(1) }
        let dsCount = Int(dsSize) / MemoryLayout<UInt32>.size
        var sources = [UInt32](repeating: 0, count: dsCount)
        AudioObjectGetPropertyData(micID, &dsAddr, 0, nil, &dsSize, &sources)
        print("data sources:", sources.map { String(bytes: [UInt8($0>>24), UInt8(($0>>16)&0xFF), UInt8(($0>>8)&0xFF), UInt8($0&0xFF)], encoding: .ascii) ?? "?" }.joined(separator: ","))

        let sourcesCopy = sources
        for src in sourcesCopy {
            // 切 data source
            var setAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var v = src
            let r = AudioObjectSetPropertyData(micID, &setAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
            let tag = String(bytes: [UInt8(src>>24), UInt8((src>>16)&0xFF), UInt8((src>>8)&0xFF), UInt8(src&0xFF)], encoding: .ascii) ?? "?"
            print("switch to \(tag) r=\(r)")
            Thread.sleep(forTimeInterval: 0.4)

            // AudioQueue 采 2 秒
            peak = 0; frames = 0
            var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var queue: AudioQueueRef?
            let box = Box()
            let ud = UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque())
            let cb: AudioQueueInputCallback = { u, q, b, t, n, d in inputCallback(u, q, b, t, n, d) }
            AudioQueueNewInput(&format, cb, ud, nil, nil, 0, &queue)
            var buffers: [AudioQueueBufferRef] = []
            for _ in 0..<3 {
                var bb: AudioQueueBufferRef?
                AudioQueueAllocateBuffer(queue!, 9600 * 4, &bb)
                AudioQueueEnqueueBuffer(queue!, bb!, 0, nil)
                buffers.append(bb!)
            }
            AudioQueueStart(queue!, nil)
            Thread.sleep(forTimeInterval: 2.0)
            AudioQueueStop(queue!, true)
            AudioQueueDispose(queue!, true)
            let db = 20 * log10(max(peak, 1e-10))
            print("  [\(tag)] frames=\(frames) peak=\(String(format: "%.4f", peak)) \(String(format: "%.1f", db))dB")
        }
        exit(0)
    }
}
