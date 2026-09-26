# 真多轨录像 + EXIF 回填(2026-09-26 22:57 实测闭环)

> 用户两条硬指令:①别拿"等真机"当挡箭牌,Mac 内置摄+屏流就是两路真实输入,双视频轨现在落地;②EXIF"挂着待办"不行,拍出来 CGImageSource 直接读到完整 EXIF。均已完成并实测。

## 一、真多轨录像(不再烧 PIP)

### 架构
- **同一 AVAssetWriter、两个视频 input**:主轨 1080p h264(主摄)+ 辅轨 960×540 h264(每路 PIP 设备一条,上限 3 路)
- **root clock = 主机单调钟(CFAbsoluteTime)**:起录时记 `recordStartHost`,辅轨帧到达即弃源 PTS(屏流/连续互通各有时钟,互不相干),PTS = `sessionStartPTS + (hostNow - recordStartHost)`。主轨帧同为主机钟轴实时写入 → 双轨天然同轴,这正是跨设备 root clock 对齐
- **删掉烧入**:`CameraViewModel.startRecording` 里 PIP 静帧快照烧入循环整段移除;拍照的 PIP 同框(processAndSave)保留(拍照是单帧交付,同框语义仍成立)
- **stop 收尾**:append 过帧的辅轨 markAsFinished;零帧辅轨直接丢弃引用(和音频轨同一坑:未 append 的 input markAsFinished 会让 finishWriting 永久挂起)

### 实测(内置摄 + 屏流伪设备两路真实输入)
成片 `~/Movies/KinetCamera/KinetCamera-20260926-225527.mov`,ffprobe:

```
stream index=0 video 1920x1080 avg_frame_rate=30/1        duration=7.833
stream index=1 audio 48kHz                                duration=7.819
stream index=2 video  960x540  avg_frame_rate≈14.8        duration=7.828   ← 屏流 15fps 上限,合理
```

- 双 v 流各自抽帧(AVAssetReader 逐轨,`scripts/extract_track_frame.swift`):主轨 @3s = 1920×1080 实拍画面;辅轨 @3s = 960×540 屏流内容(mean 415,黑帧修复后)
- **辅轨是实时流非静帧**:0.8s vs 6.5s 两帧平均像素差 2.22(内容显著变化)
- 时基:双轨 duration 一致(7.833/7.828),无 423861s 类异常
- **踩坑记录**:首版辅轨全黑 —— pool buffer 是空白内存,创建后直接 append 等于写黑帧。修复 = lock 后按行 memcpy 源像素(宽高/stride 各自适应),这就是"间接层必须拷贝内容"的铁证
- 证据:`docs/evidence/dual_track0_main_1080p.png`、`dual_track1_pip_960x540.png`
- 兼容性:QuickTime 取主轨播,Finder 预览正常;FCP/PR 可当多机位拆轨

## 二、EXIF 回填(CGImageSource 直读铁证)

### 实现
- 新增 `CameraManager.savePhoto(cg:exif:tiff:)`:JPEG q0.95(带完整 EXIF,主交付)+ 同时间戳无损 PNG(保底交付不变)
- `captureMetadata(device:)`:DateTimeOriginal/DateTimeDigitized/TIFF Software=KinetCamera 恒写;设备在场写 Make/Model/LensMake/LensModel;ISO/曝光时间/光圈/焦距 iOS 侧写真值(macOS 编译期 unavailable —— 平台墙,宁缺勿假),ExposureProgram=2(AE)/WhiteBalance=0(auto)双端写

### 实测(拍后 CGImageSource 直读)
```
PixelWidth: 1920  PixelHeight: 1080
-- EXIF --
  DateTimeOriginal: 2026:09:26 22:56:43
  DateTimeDigitized: 2026:09:26 22:56:43
  LensMake: Apple Inc.
  LensModel: MacBook Air的相机
  ExposureProgram: 2
  WhiteBalance: 0
-- TIFF --
  Make: Apple Inc.
  Model: MacBook Air的相机
  Software: KinetCamera
  DateTime: 2026:09:26 22:56:43
```
落盘三件套同时间戳:`xxx.json`(AI 报告)+ `xxx.png`(无损)+ `xxx.jpg`(EXIF)。

## 三、平台墙如实记
- Mac 侧 EXIF 无 ISO/快门/光圈:AVCaptureDevice 这些 API macOS unavailable,伪造静态值是自欺,字段留空到 iOS 真机补真值
- 辅轨帧率由源决定(屏流 15fps),不是 30fps 假插帧

## 复跑口径
- 双轨录:POST /pip?id=kinet.screen.0 → /record start → 8s → stop → ffprobe 上述 mov
- 轨道抽帧:`scripts/extract_track_frame.swift`(swiftc 编译,AVAssetReader 指定 track 逐帧)
- EXIF 读回:PyObjC CGImageSourceCopyPropertiesAtIndex(系统原生 ImageIO)
