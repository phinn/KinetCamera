import Vision
import AppKit

// 用法: swift ocr.swift <image> — Vision 框架离线 OCR(无需 tesseract)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let req = VNRecognizeTextRequest()
req.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
let handler = VNImageRequestHandler(url: url)
try handler.perform([req])
for obs in (req.results ?? []) {
    print(obs.topCandidates(1)[0].string)
}
