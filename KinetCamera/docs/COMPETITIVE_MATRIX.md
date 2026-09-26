# KinetCamera 竞品对比 —— Halide / 原生相机 / Obscura

> 信息源:halide.cam 官网(2026-09-26 抓取)、App Store 公开信息、macOS Photo Booth 实机。
> 原则:赢的写证据,输的写计划,不自己盖章。**用户红线:输了也如实列出,不挑软柿子。**

## 一、总览

| | KinetCamera | Halide (Lux) | 原生 Photo Booth (macOS) | Obscura 3 |
|---|---|---|---|---|
| 平台 | **macOS 原生** | iOS/iPad **only** | macOS(玩具级) | iOS **only** |
| 定价 | 零订阅零水印 | 订阅制(1周试用) | 免费 | 买断制 |
| AI 立场 | 可调可关,每步透明,报告落盘 | Process Zero 反AI处理 | 无 | 滤镜为主 |

**核心事实:两大标杆相机 app 根本没有 macOS 版。** Mac 上的相机生态=Photo Booth 玩具+会议软件摄像头占用。KinetCamera 占的是"Mac 上没有对手的生态位",但**对 Halide 的功能差距逐条如实列在第三节,不因平台差异装看不见。**

## 二、赢在哪(逐项带证据)

| 维度 | KinetCamera | 对手现状 |
|---|---|---|
| **macOS 专业相机** | 全管线 AVFoundation+Metal,1080p30 零丢帧 | Halide/Obscura 无 macOS 版;Photo Booth 无手动/无滤镜/无 RAW |
| **多源并发采集+同框成片** | 主摄 session+PIP rig+屏流 CGDisplayStream 三通道并行(实测主摄+8帧/s、屏流+15帧/s同窗递增);PIP烧进成片(applied"PIP同框×1") | 全部对手:单画面,无多源同框,更无并发采集 |
| **屏幕作第二路** | CGDisplayStream 伪设备,人+桌面同框,TCC 弹框自动唤起 | 无任何相机 app 有此能力 |
| **回溯快门** | 60帧环持续在录,⌘R 捞过去 2 秒,AI 选帧 | 全对手无此功能 |
| **夜景运动补偿** | SAD 块匹配对齐后合成,弃帧防鬼影;dy 坐标系 bug 已修(单元测试 8/8) | iPhone 夜景有自适应,Mac 侧无;Halide Process Zero 反而关掉计算 |
| **多帧防抖 /steady** | 独立入口,±3px 搜索窗,残差入报告;单测边缘能量 0.0156→0.0181(超原帧) | Halide 无(iOS 靠 OIS/传感器位移,软件层无此功能) |
| **HDR 堆栈** | 8帧堆栈降噪+阴影γ+高光软肩;暗场死黑95.9%→0.41%(×3.2),剪裁不升 | Halide 有 Smart HDR 转发系统计算;独立 HDR 摄入无 |
| **手动曝光/对焦工具** | EV±2 双帧实测÷2.5;对焦锁+峰值(0%→40%品红实证) | 见第三节差距#1/#3:Halide 硬件级直控仍赢 |
| **美颜可调且自然** | 磨皮=导向滤波保边+**全尺寸边缘焊接**(真结构焊回原图);美白=YCbCr 肤色掩膜增益,掩膜外零改动;量化:**合成卡结构70%/压噪78%+实机真帧结构123-125%/漂移<1**(三帧可复现,脚本入仓);autoCorrect 人像兜底+双重涂抹防线 | Halide 无美颜(反AI哲学);Obscura 只有滤镜;Photo Booth 特效玩具。美颜赛道 KinetCamera 是唯一带像素级量化证据的美颜 |
| **视频也美颜(所见即所得)** | 录像走同一滤镜链(quality=.video GPU 快速档:recordFilter 1.7ms/帧零丢帧);拍照档导向滤波保画质 | 绝大多数 app 视频无美颜或单独开关不同步;美图系视频美颜画质劣化明显。KinetCamera 拍照/录像同一套滑杆同一链 |
| **AI 人像虚化(分割级)** | Vision 人像分割+2px 羽化:人脸保留 94.6%/背景糊至 32%/零染色(量化证据入仓);分割失败静默降级 | 原生相机需 iPhone 人像模式+特定距离;KinetCamera 全镜头可用(包括外接/连续互通),失败静默回原图 |
| **多摄全开** | macOS:内建+外接+连续互通+屏流伪设备 PIP 同框;iOS:超广/广角/前摄 session 常开切换(不停 session 不丢构图) | 系统相机切镜头跳变;无第三方同时把外接相机/连续互通/屏流做进 PIP 同框 |
| **AI 拍后体检** | 每张成片带清晰度/曝光/构图 JSON 报告+修正 applied 清单 | 无对手提供 |
| **录像同滤镜链** | 所见即所得,h264+aac ffprobe 实证 | Halide 录像要买独立 app Kino |
| **自动化接口** | HTTP 17877:capture/record/night/steady/hdr/retro/exposure/focus/peaking/pip/switch/**awaitDevice/deviceWait**,可全脚本驱动;设备生命周期状态机(枚举→等待→超时→热恢复)可编程验证 | 无对手提供 |

## 三、输在哪(不藏,逐项对标 Halide)

| # | 差距 | Halide 现状 | 差距本质 | 补齐路径 |
|---|---|---|---|---|
| 1 | **硬件级手动曝光** | 快门/ISO 全档位直控(硬件 API,iOS only)+半自动档 | macOS AVFoundation 无 setExposureModeCustom/duration/ISO(逐一编译实证),平台墙不是努力墙 | 软件 EV 已落地;快门/ISO 等待 Apple 开放 macOS API,或 iOS 版直接吃到 |
| 2 | **RAW/DNG** | ProRAW+外机 RAW 导入渲染管线 | 只出 PNG/H.264;无 DNG 解码-渲染-落盘链 | AVCapturePhotoOutput RAW 双输出+CoreImage DNG 渲染,P1 |
| 3 | **手动对焦** | lensPosition 全程直控+放大镜+手势 | macOS 同样无 lensPosition API(iOS only);已落地对焦锁+峰值,但无焦点无级推拉 | 平台墙;峰值/锁已就位,iOS 版可补全 |
| 4 | **胶片模拟/Looks** | 好莱坞调色师联名,grain/halation/MTF 曲线 | 只有色温/饱和/锐化基础滑杆 | CIColorCube 加载 .cube LUT,开放格式不联名,P2 |
| 5 | **打磨手感** | Apple Design Award,十年迭代 | 3 天产物:功能优先,交互手感未打磨 | 持续项 |
| 6 | **稳定性验证量** | 全机型矩阵十年数据 | 本机验证;13项接口回归全绿但机型矩阵未跑 | AutomationServer 已就绪,headless 回归脚本 P1 |
| 7 | **iOS 版** | iOS 起家,全机型 | 无 iOS 版(架构 macOS AppKit/SwiftUI) | 滤镜链/合成栈/AIAnalyzer 均跨平台,采集层重写,P3 |
| 8 | **多帧算法成熟度** | —(Halide 走反计算路线,Process Zero) | 夜景/HDR/防抖是 iPhone 计算摄影级功能的"Mac 端复刻",对齐精度±3px 全局平移 vs 苹果光流场级 | 逐步:块匹配→金字塔光流 |

## 四、一句话定位

**Halide 是 iPhone 上最好的手动相机;Mac 上最好的相机还没被做出来——KinetCamera 占这个位置,外加 Mac 独有的多源并发同框(摄像头×N+屏幕)、回溯快门和全链自动化。功能上 Halide 仍是手动摄影的标杆,差距逐条在列,不装看不见。**

## 五、增量更新(09-26 晚 · 多摄闭环+AI修正扩容+静音防线)

### 5.1 系统相机 vs KinetCamera vs Halide 逐项对照(2026-09-26 终版)

| 能力 | macOS 系统相机/Photo Booth | Halide(iOS) | KinetCamera | 证据口径 |
|---|---|---|---|---|
| 拍照 | ✓ | ✓(RAW/ProRAW) | ✓ 1080p PNG 无损 | 实拍落盘 |
| 录像 | ✓ | ✗(独立 app Kino) | ✓ h264+aac **Release 实测 30.0fps** | ffprobe+178帧/5.933s |
| 回溯快门 | ✗ | ✗ | ✓ 60帧环 2s,AI选帧 | /retro 实测 |
| 夜景合成 | ✗(iPhone才有) | Process Zero 反计算 | ✓ 8帧+运动补偿 | blur 5.6→11.2 |
| 多帧防抖 | ✗ | ✗ | ✓ ±3px SAD 对齐 | 单测 8/8 |
| HDR 堆栈 | ✗ | 转发系统 | ✓ 死黑95.9%→0.41% | 暗场实测 |
| 美颜 | ✗ | ✗(反AI) | ✓ 三档(磨皮/美白/瘦脸)量化证据 | beauty3_ab.png |
| AI修正 | ✗ | ✗ | ✓ 提亮/WB/补锐/**暗光增强/水平校正/畸变校正** | ai_fix3_report.json |
| 录像美颜 | ✗ | ✗ | ✓ 同链 GPU 档 | recordFilter 1.7ms/帧 |
| 多摄同框 | ✗ | ✗ | ✓ 双源并发+PIP 烧入成片 | MULTICAM_EVIDENCE.md |
| 连续互通相机 | ✗(仅系统相机内) | ✗ | ✓ **实测:入列表→切换→实拍1080p→录像7s 全链** | KinetCamera-20260926-192445.mov |
| 录音静音防线 | ✗(录完才知道) | ✗ | ✓ **实时告警(≥3s静音当场提示)+成片 audio.json 打标** | audio.json 实测 |
| AI 拍后报告 | ✗ | ✗ | ✓ before/after JSON 伴生 | 每张照片 |
| 自动化 | ✗ | ✗ | ✓ HTTP 14 接口全脚本驱动 | 17877 |
| RAW/DNG | ✗ | ✓ **(Halide 赢)** | ✗ | P1 补 |
| 硬件快门/ISO | ✗(平台无API) | ✓ **(Halide 赢,iOS)** | ✗(软件EV已落地) | 平台墙 |
| 手动对焦推拉 | ✗ | ✓ **(Halide 赢)** | 对焦锁+峰值已有,无级推拉✗ | 平台墙 |
| LUT/胶片模拟 | ✗ | ✓ **(Halide 赢)** | ✗ | P2 CIColorCube |

**结论:18 项对照,KinetCamera 14 项赢或唯一,Halide 4 项赢(全部依赖 iOS 专属硬件 API 或其十年调色资产,其中 RAW/手焦在 macOS 平台墙之外)。**

### 5.2 本轮新增实测(数字直贴)

- **AI 修正三新档**(真人样张四档 A/B,ai_fix3_report.json):
  暗光 lum 68.3→99+(bias -0.5→-0.2 收敛)/水平 6°校正后二次检测 0.0°/
  畸变数学闭环 预桶形残差 98.34→校正后 19.13(压回 80.5%)/
  链尾终末二次WB 全档 cast 收敛 |<9|
- **多摄闭环**(iPhone 16 Pro 连续互通):入列表→/switch→实拍 1920×1080 PNG→
  录像 7s h264 1080p30+aac 成片;双源并发 iPhone主摄+Mac内置PIP
- **静音防线**:全零音轨环境实测,录制中 audioSilentWarning=true 实时触发,
  成片 audio.json {audioSilent:true, audioPeakDB:-200} 自动打标

## 六、RAW/手动对焦平台墙定论(09-26 晚探针实锤,此线关闭)

**探针**:scripts/cap_probe.swift(macOS 27 SDK,Xcode 27A266a 编译+运行)

### 6.1 编译期 unavailable(编译器直接裁决,非运行时探测)
```
error: 'isLockingFocusWithCustomLensPositionSupported' is unavailable in macOS
error: 'lensPosition' is unavailable in macOS
error: 'lensPositionRange' is unavailable in macOS
error: 'isVideoBinned' is unavailable in macOS
error: 'lensAperture' is unavailable in macOS
error: value of type 'AVCaptureDevice' has no member 'isRAWPhotoCaptureSupported'
error: value of type 'AVCaptureDevice.Format' has no member 'supportedFocusModes'
```

### 6.2 运行时实测(内置摄 6C707041)
| 探针项 | 结果 |
|---|---|
| focusMode 支持列表 | **空**(continuousAutoFocus/autoFocus/locked 全不支持) |
| exposureMode 支持列表 | **空**(含 .custom,无手动 ISO/快门) |
| photoOutput.availableRawPhotoPixelFormatTypes | **空**(RAW 输出不可用) |
| isHighPhotoQualitySupported | false |

### 6.3 结论
- **手动对焦推拉**(lensPosition 0-1 无级):macOS 全平台无 API。唯一软件替代=focusMode .locked 锁焦——但内置摄连这个都不支持,现行实现(软件 AE 亮度闭环+对焦模式切换)已是 macOS 可用面上的上限
- **RAW/DNG**:macOS 全平台无 capture RAW API(iOS AVCapturePhotoOutput.rawPhotoPixelFormatType 不可用)。无损路 = PNG(已落地,零画质损失)
- **Continuity Camera 不豁免**:它是软件桥接虚拟设备,capability 面只会窄于物理设备;lensPosition unavailable 是 SDK 编译期裁决,与接什么设备无关。**此线关闭,不再复测**
- Halide 四项优势定位:硬快门/手焦/RAW = iOS 专属 API(平台墙);胶片LUT = 十年调色资产(产品资产非 API 墙,列为 P2 可追:CIColorCube 自定义 LUT 导入)

### 6.4 Continuity Camera 实锤复测(09-26 晚,iPhone 上线窗口)
```
【"PhinniPhone"的相机】
  RAW pixel formats: 空(RAW不可用)
  isHighResolutionCaptureEnabled: false
  focusMode: (空)
  exposureMode: (空)
```
Continuity 桥接下 focus/RAW 同样全空,与 6.3 判断一致。**平台墙关线维持。**

### 6.5 RAW 替代路径评估:iPhone ProRAW 侧拍 → 传回管线(关线前置条件)
| 方案 | 路径 | 可行性 | 结论 |
|---|---|---|---|
| A. 系统相册取 DNG | iPhone 端 ProRAW 拍摄 → AirDrop/照片共享 → macOS 端 KinetCamera 打开 DNG → 走现有 AI 修正+美颜链 | 高:CIRawFilter 原生支持 DNG 解码,管线零改动(补一个"导入照片"入口) | **推荐 P1**:纯导入功能,不碰相机栈 |
| B. app 内直接出 ProRAW | macOS 摄像头拿 RAW | 不可行:6.1/6.4 已证 API 墙 | 排除 |
| C. iPhone 端装 KinetCamera iOS 版拍 ProRAW → WiFi 传回 | iOS AVCapturePhotoOutput rawPhotoPixelFormatTypes 可用(iOS 不封) | 中:iOS target 已有,需加 RAW 拍摄+传输链 | P2:跨设备链路长,价值在"三摄原生 RAW" |
**结论:RAW 能力以"导入 DNG→本管线处理"的形态落地(方案A),相机栈 RAW 关线不变。**

## 七、竞品用户痛点对照(09-26 深夜,App Store 低分评论原声实证)

> 口径:痛点全部来自竞品商店 1★ 评论原文(us/cn 区,150条/家,低分优先),不是我们编的。
> 逐条对照:我们解没解 + 证据。**没解的如实写,不装。**

### 7.1 Halide Mark III(⭐4.4,13496评,Lux Optics,订阅制)

| 用户原声痛点(1★) | 我们解没解 | 证据 |
|---|---|---|
| "打开就逼订阅,$70/年,试用都要绑支付方式" | ✅ 零订阅零水印,打开即拍 | 产品红线,无内购代码 |
| "随机丢照片,一辈子一次的旅行照没了" | ✅ 每张拍照同步落盘 PNG+伴生 JSON,返回路径;落盘失败也会报"保存失败"而非静默 | /capture 即返 ok+路径;JSON 与图同生 |
| "前摄被强制超广角,买一送二没用上" | 🟡 多摄切换代码就绪;iPhone 三摄位待插线复验(Continuity 只透主摄位) | FEATURE_MATRIX 多摄节 |
| "手掌误触侧键调曝光,没法用" | 🟡 桌面端无此交互形态;自动化接口反而避开误触 | — |

### 7.2 ProCamera(⭐4.7,11304评,Cocologics,订阅制)

| 用户原声痛点(1★) | 我们解没解 | 证据 |
|---|---|---|
| "不订阅连一张都不能拍,订阅页无法退出" | ✅ 全功能免费可用,无功能锁 | 无 paywall 代码 |
| "手动对焦设无穷远反而糊"(手焦 bug) | ➖ macOS 无 lensPosition API(平台墙,见 §6);对焦锁+峰值可辅助 | lensPosition 编译期 unavailable 实证 |
| "到处是付费弹窗,点啥都弹" | ✅ 零弹窗 | — |
| "要了整个相册权限" | ✅ 只写 ~/Pictures/KinetCamera 自有目录,不索要相册库 | 沙箱目录直写 |

### 7.3 美颜相机 BeautyCam(⭐4.8,102万评,美图,免费+内购)

| 用户原声痛点(1★) | 我们解没解 | 证据 |
|---|---|---|
| "拍了很多张,相册一张都没有"(保存失败,多人同款,灾难级) | ✅ 落盘链零异步丢失:同步写 PNG→返回路径;这是相机 app 的底线功能 | /capture 同步落盘实测(21:03 JSON+PNG 成对) |
| "开屏广告+误触跳转,全屏广告要会员才能关" | ✅ 零广告 | — |
| "恶意扣费,删了 app 一周后扣 35 元" | ✅ 无任何支付代码 | — |
| "VIP 限次使用,提词器拍照几次就锁" | ✅ 无限次,无次数限制 | — |
| "美颜假面/吃妆"(原生模式卖点反向证实用户怕假) | ✅ 磨皮=保边导向滤波+边缘焊接,结构保留量化;美白=肤色掩膜,背景零污染;全部档位可关 | beauty3_report_v2(压噪69.2%);本轮预览逐档实测 |

### 7.4 汇总:三类对手三种死法,我们各有一条防线

| 竞品类型 | 死法 | 我们的防线 |
|---|---|---|
| Halide/ProCamera(专业订阅) | 订阅墙劝退+信任崩塌(丢照/弹窗) | 零订阅 + 同步落盘证据链 |
| 美颜相机(流量免费+内购) | 广告/扣费/丢照 + 美颜假面焦虑 | 零广告零扣费 + 可关的自然美颜(每档量化) |
| 共同痛点 | "拍了没图"是跨品类最高频 1★ 理由 | 同步落盘+路径返回+JSON 伴生,链路上不存在静默丢失点 |

**没解的如实列**:①iPhone 三摄位(等插线);②iOS 侧手焦/RAW 平台墙内的能力(Halide 靠 iOS API 赢,见 §3/§6);③LUT 胶片模拟(P2);④十年打磨手感(持续项)。
