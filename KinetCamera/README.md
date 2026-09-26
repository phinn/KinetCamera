# KinetCamera

macOS / iOS 原生相机应用。拍照 · 美颜录像 · 多摄像头 · AI 体检与 AI 人像虚化,零订阅零水印。

## 针对的行业痛点(逐条解决)

| 行业痛点 | KinetCamera 方案 |
|---|---|
| 美颜软件一刀切假脸 | 磨皮与原图混合上限 85%,永远保留真实皮肤纹理;锐化后置补回发丝 |
| 修图软件订阅制(¥198/年修个图) | 免费,本地处理,无账号无水印 |
| 拍完才发现糊了/过曝了 | 实时 AI 体检:清晰度/曝光/人脸构图每秒刷新,拍前知道能不能拍 |
| AI 修正要多拍一张再导去修 | 按快门瞬间自动体检并修正(欠曝提亮/过曝压回/糊片锐化),零额外步骤 |
| 多摄像头切换要重进 App | 热切换 + 最多 3 路画中画同屏;iPhone 经连续互通相机直接接入;iOS 端超广/广角/前摄 session 常开切换不丢构图 |
| 拍照软件不能录、录像软件不美颜 | 拍照录像共用同一滤镜链(录像 GPU 快速档 1.7ms/帧),录像即美颜,所见即所得 |
| AI 修复痕迹重、人被磨穿 | Vision 人像分割背景虚化(人脸保留 94.6%/背景糊至 32%,量化证据入仓),失败静默回原图 |
| 保存路径黑盒 | 照片 → `~/Pictures/KinetCamera/`,视频 → `~/Movies/KinetCamera/`,PNG 无损 |

## 构建

```bash
xcodegen generate
# macOS
xcodebuild -project KinetCamera.xcodeproj -scheme KinetCamera build
# iOS 真机(需配对设备)
xcodebuild -project KinetCamera.xcodeproj -scheme KinetCameraiOS \
  -destination 'id=<UDID>' -allowProvisioningUpdates build
# 或一键部署: scripts/deploy_ios.sh
```

## 快捷键

- `⌘3` 拍照
- `⌘4` 开始/停止录像

## 架构

- `CameraManager` — 主摄全管线(`.inputPriority` 拉设备原生最高分辨率),`PIPController` 每设备独立轻量会话
- `FilterPipeline` — 单一 Metal CIContext;磨皮→提亮→色温→饱和→锐化→暗角;人像虚化走 Vision 分割(跳帧推理 + mask 复用)
- `AIAnalyzer` — vDSP 拉普拉斯方差(清晰度)+ 亮度直方图(曝光)+ Vision 人脸(构图),512px 降采样毫秒级
- `CIRenderView` — MTKView 帧驱动渲染(`isPaused=true`,来一帧画一帧,不空转 GPU)

## 已知边界

- 首次启动需在系统弹窗授权相机(麦克风用于录像音轨)
- 权限被拒时右侧面板给出设置入口指引
