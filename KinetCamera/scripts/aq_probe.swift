// 层9:AudioQueue 直采(完全绕 AVFoundation),判别数据零的层位
import AudioToolbox
import Foundation

final class Box {}

var peak: Float = 0
var frames = 0

func inputCallback(_ userData: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef, _ startTime: UnsafePointer<AudioTimeStamp>, _ numPackets: UInt32, _ packetDesc: UnsafePointer<AudioStreamPacketDescription>?) {
    frames += 1
    let n = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
    let p = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
    for i in 0..<n {
        let v = abs(p[i])
        if v > peak { peak = v }
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}

@main struct Main {
    static func main() {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var queue: AudioQueueRef?
        let box = Box()
        let userPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque())
        let cb: AudioQueueInputCallback = { ud, q, buf, ts, np, pd in
            inputCallback(ud, q, buf, ts, np, pd)
        }
        AudioQueueNewInput(&format, cb, userPtr, nil, nil, 0, &queue)
        var buffers: [AudioQueueBufferRef] = []
        for _ in 0..<3 {
            var b: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue!, 4800 * 4, &b)
            AudioQueueEnqueueBuffer(queue!, b!, 0, nil)
            buffers.append(b!)
        }
        AudioQueueStart(queue!, nil)
        Thread.sleep(forTimeInterval: 3.0)
        let db = 20 * log10(max(peak, 1e-10))
        print("frames=\(frames) peak=\(String(format: "%.4f", peak)) \(String(format: "%.1f", db))dB")
        AudioQueueStop(queue!, true)
        exit(0)
    }
}
