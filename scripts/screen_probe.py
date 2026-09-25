#!/usr/bin/env python3
"""屏幕捕捉探针:CGDisplayStream 抓1帧存PNG。验本机屏流链路+TCC授权状态。"""
import Quartz, CoreVideo, sys
from Quartz import CGMainDisplayID, CGDisplayStreamCreate, CGDisplayStreamStart, CGDisplayStreamStop
import Quartz.CoreGraphics as CG
import objc

# 用 ScreenCaptureManager 式简单路径:CGDisplayStream + IOSurface
import Foundation
done = [False]
result = {"ok": False, "err": ""}

WIDTH, HEIGHT = 960, 540

def callback(*args):
    # (stream, frameStatus, frameSurface, updateRef)
    if done[0]:
        return
    surface = args[2]
    if surface is None:
        return
    try:
        from Quartz import CIImage, CIContext
        ci = CIImage.imageWithIOSurface_(surface)
        ctx = CIContext.context()
        cg = ctx.createCGImage_fromCIImage_(ci)
        dest = Quartz.CGImageDestinationCreateWithURL(
            Foundation.NSURL.fileURLWithPath_("/tmp/screen_probe.png"), "public.png", 1, None)
        Quartz.CGImageDestinationAddImage(dest, cg, None)
        Quartz.CGImageDestinationFinalize(dest)
        result["ok"] = True
        result["size"] = (cg.getWidth(), cg.getHeight())
    except Exception as e:
        result["err"] = str(e)
    done[0] = True

stream = Quartz.CGDisplayStreamCreateWithDispatchQueue(
    CGMainDisplayID(), WIDTH, HEIGHT,
    CoreVideo.kCVPixelFormatType_32BGRA,
    {Quartz.kCGDisplayStreamMinimumFrameTime: 1.0/15.0},
    Foundation.NSOperationQueue.new(), callback)

if stream is None:
    print("STREAM_CREATE_FAILED")
    sys.exit(1)

Quartz.CGDisplayStreamStart(stream)
import time
t0 = time.time()
runloop_ok = True
while not done[0] and time.time() - t0 < 6:
    time.sleep(0.2)
Quartz.CGDisplayStreamStop(stream)

if result["ok"]:
    print(f"FRAME_OK {result['size'][0]}x{result['size'][1]} -> /tmp/screen_probe.png")
else:
    print(f"NO_FRAME_IN_6S err={result['err']} (典型原因:无屏幕录制TCC授权)")
