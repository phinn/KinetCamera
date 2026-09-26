# KinetCamera 竞品对比 —— Halide / 原生相机 / Obscura

> 信息源:halide.cam 官网(2026-09-26 抓取)、App Store 公开信息、macOS Photo Booth 实机。
> 原则:赢的写证据,输的写计划,不自己盖章。

## 一、总览

| | KinetCamera | Halide (Lux) | 原生 Photo Booth (macOS) | Obscura 3 |
|---|---|---|---|---|
| 平台 | **macOS 原生** | iOS/iPad **only** | macOS(玩具级) | iOS **only** |
| 定价 | 零订阅零水印 | 订阅制(1周试用) | 免费 | 买断制 |
| AI 立场 | 可调可关,每步透明 | Process Zero 反AI处理 | 无 | 滤镜为主 |

**核心事实:两大标杆相机 app 根本没有 macOS 版。** Mac 上的相机生态=Photo Booth 玩具+各会议软件的摄像头占用。KinetCamera 不是"在 Mac 上打 Halide",是**占一个没有对手的生态位**。

## 二、赢在哪(逐项带证据)

| 维度 | KinetCamera | 对手现状 |
|---|---|---|
| **macOS 专业相机** | 全管线 AVFoundation+Metal,1080p30 零丢帧 | Halide/Obscura 无 macOS 版;Photo Booth 无手动/无滤镜/无 RAW |
| **多摄同框 PIP** | 每设备独立 session+output rig,≤3 路,毫秒切换;实测 iPhone 连续互通 1080p 主摄切换 + 双路同框成片 | 全部对手:单画面,无多源同框 |
| **屏幕作第二路** | CGDisplayStream 伪设备,人+桌面同框,实测活帧递增(89→272帧/5s),TCC 弹框自动唤起 | 无任何相机 app 有此能力(屏幕录制权限门槛劝退) |
| **回溯快门** | 60帧环持续在录,⌘R 捞过去 2 秒,AI 清晰度+曝光选帧,实测落盘 | 全对手无此功能("精彩瞬间拍完才想到"无解) |
| **夜景运动补偿** | SAD 块匹配对齐后再合成,弃帧防鬼影,blur 5.6→11.2 | iPhone 夜景有自适应,Mac 侧无;Halide Process Zero 反而关掉计算 |
| **美颜可调且自然** | 7 段实时滑杆,抬黑位美白保纹理,A/B 实测 Δ+34.2% | Halide 哲学=零 AI 不做美颜;Obscura 只有滤镜;Photo Booth 特效玩具 |
| **AI 拍后体检** | 每张成片带清晰度/曝光/人脸构图 JSON 报告 | 无对手提供 |
| **录像同滤镜链** | 所见即所得,h264+aac 实证(ffprobe) | Halide 录像要买独立 app Kino;Obscura 视频弱 |
| **隐私** | Local-first,无网络上传,自动化接口仅 localhost | Halide 无跟踪(同级);其余看厂商 |
| **自动化接口** | HTTP 17877:拍照/录像/夜景/PIP/切换,可脚本驱动 | 无对手提供(无 headless 能力) |

## 三、输在哪(不藏)

| # | 差距 | 对手水平 | 差距本质 |
|---|---|---|---|
| 1 | **全手动曝光** | Halide:快门/ISO/白平衡全档位+半自动 | 只有 AE 锁+曝光补偿,无快门/ISO/WB 直控 |
| 2 | **RAW/DNG** | Halide:ProRAW+外机 RAW 导入渲染 | 只出 PNG/H.264,无 DNG 管线 |
| 3 | **对焦辅助** | Halide:对焦峰值、放大镜、手势对焦 | 自动对焦+点按对焦,无手动对焦工具 |
| 4 | **打磨手感** | Halide:Apple Design Award,十年迭代,自定义字体/表盘交互 | 3 天产物:布局功能优先,手感未打磨 |
| 5 | **稳定性验证量** | Halide:全机型矩阵 | 本机验证通过,机型矩阵未跑 |
| 6 | **iOS 版** | 双竞品 iOS 起家 | 无 iOS 版(架构是 macOS AppKit/SwiftUI) |
| 7 | **胶片模拟/Looks** | Halide:好莱坞调色师联名,grain/halation/MTF | 只有基础色温/饱和滑杆 |

## 四、补齐计划(按投入产出排序)

| 优先级 | 项目 | 落地路径(具体 API) | 预估 |
|---|---|---|---|
| P0 | 全手动曝光 | `AVCaptureDevice`手动曝光:`setExposureModeCustom(duration:iso:)`、`whiteBalanceModeLocked(with:)`;UI 三滑杆+当前值读数 | 1 天,纯已有管线加参数 |
| P0 | 对焦辅助 | 手动对焦`setFocusModeLocked(lensPosition:)`+对焦峰值(CIRenderView 已有 Metal 链,拉luma边缘叠加伪色) | 1-2 天 |
| P1 | RAW/DNG | `AVCapturePhotoOutput`开`RAW-kCVPixelFormat*`双输出,DNG 落盘;夜景/回溯快门直接吃到 RAW 级细节,同时解掉"涂抹"痛点 | 2-3 天 |
| P1 | 机型矩阵 | 已有 AutomationServer,补 headless 回归脚本跑全 USB 摄像头清单 | 脚本 1 天 |
| P2 | 胶片模拟 | 3D LUT(CIColorCube)加载 .cube 文件,用户可自导;不做联名,做开放格式 | 2 天 |
| P3 | iOS 版 | 滤镜链/回溯快门/AIAnalyzer 均可跨平台,iOS 用 AVCaptureSession 重写采集层 | 独立项,另排 |
| — | 打磨手感 | 持续项,不承诺日期 | — |

## 五、一句话定位

**Halide 是 iPhone 上最好的相机,Mac 上最好的相机还没被做出来——KinetCamera 占的就是这个位置,外加 Mac 独有的多源同框(摄像头×N+屏幕)和自动化能力。**
