#!/usr/bin/env python3
"""Vision 框架离线 OCR(pyobjc 版,替代 tesseract)
用法: python3 kb_ocr.py <image...>
"""
import sys
from Vision import VNRecognizeTextRequest, VNImageRequestHandler
from Foundation import NSURL

for path in sys.argv[1:]:
    url = NSURL.fileURLWithPath_(path)
    req = VNRecognizeTextRequest.alloc().init()
    req.setRecognitionLanguages_(["zh-Hans", "zh-Hant", "ja-JP", "en-US"])
    req.setRecognitionLevel_(0)  # 0 = accurate
    req.setUsesLanguageCorrection_(False)
    handler = VNImageRequestHandler.alloc().initWithURL_options_(url, None)
    ok = handler.performRequests_error_([req], None)[0]
    if not ok:
        print(f"[{path}] OCR failed", file=sys.stderr)
        continue
    print(f"--- {path} ---")
    for obs in (req.results() or []):
        print(obs.topCandidates_(1)[0].string())
