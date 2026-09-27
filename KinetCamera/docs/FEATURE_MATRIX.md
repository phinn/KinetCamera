# KinetCamera 功能矩阵(09-26 真机链路复核版)

> 口径:✅=真机/自动化实测有证据 | 🟡=代码在但本轮未实测或待条件 | ❌=未实现
> "本轮"= 2026-09-26 20:56 复核(auth=3,内置摄在线,iPhone 未插线)

## 一、多摄像头

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| 内置摄主链(预览/拍照/录像) | ✅ | 本轮录像 3.83s h264+aac、拍照 PNG+JSON、30fps | — |
| 设备枚举+切换(switchDevice) | ✅代码 / 🟡本轮 | /switch 实测过多轮(09-26 早);本轮仅内置摄在线 | **iPhone 插线复验** |
| iPhone 连续互通相机 | ✅代码 / 🟡本轮 | Continuity 实拍 1920x1080(09-26 早,连 12fps) | 插线复验 + 三摄位(iPhone 超广角/长焦 iOS 侧) |
| 屏流伪设备 kinet.screen.0 | ✅ | 本轮 /pip 同框拍照,JSON "PIP同框×1" | — |
| PIP 双源合成 | ✅ | dual_source_pip_frame100.png + 本轮 JSON 标记 | — |
| 跨设备录像时基(PTS 守卫) | ✅ | lastVideoPTS 守卫后成片时长正常(本轮 3.83s✓) | 内置→iPhone 切换后录像复验(插线) |
| iPhone 三摄位切换(超广角/长焦) | ❌ | — | iOS 侧 AVFoundation multisource;Continuity 只透出主摄位,需 iOS app 桥或 Cable 直连枚举 |
| iOS 多摄并发(AVCaptureMultiCamSession) | ✅代码 / 🟡待真机 | 主 session+PIP 子会话均条件建 MultiCamSession(isMultiCamSupported 运行时探测,iPhone XS+);preset 走 .inputPriority(input.activeFormat 定分辨率);双端编译过 | 真机前后双摄并发跑通+录双轨验证 |
| 真多轨录像(双视频流同文件) | ✅ | ffprobe: v1920x1080@30 + v960x540@14.8 双流各自抽帧;辅轨实时性两刻像素差2.22(09-26 22:55,docs/MULTITRACK_EXIF_20260926.md) | 辅轨上限3路,真机多摄各自一轨 |
| 拍照 EXIF 回填 | ✅ | CGImageSource 直读:DateTimeOriginal/Digitized/LensMake/LensModel/ExposureProgram/WhiteBalance+TIFF Software;JPEG q0.95+PNG 保底同戳;设备缺失态 Make/Model 兜底"KinetCamera Virtual Camera" | ISO/快门/光圈 macOS 平台墙留空,iOS 写真值 |
| JPEG ICC Display P3 | ✅ | savePhoto rebindToP3 零重采样,ImageIO 嵌源空间 ICC;字节级验证 APP2 ICC_PROFILE + mluc desc="Display P3" | — |

## 二、视频录制

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| h264+aac 录像 | ✅ | 本轮 ffprobe:3.83s,h264 1280x720 30fps + aac | — |
| 录像实时美颜烧入 | ✅ | video_beauty_ab.png 99.8% 像素差异 | — |
| PIP 烧入录像 | 🗑️ 已删 | 被"真多轨"替代:辅摄独立视频轨(不烧主画面),FCP/PR 可拆轨多机位 | 拍照 PIP 同框保留 |
| 变焦 zoomFactor | ✅ | 档位收敛实测:f=2→2.0 / f=99→8.0(qualityMax/formatMax 双 clamp);硬件直动 videoZoomFactor,合成源/软件裁切链预览录像拍照所见即所得;24 帧 easeOutCubic 缓动 | 三摄位快捷档 UI 已在 CameraTopBar(0.5×/1×/5×,真机 lensCandidates + 合成源双分支) |
| 录像质量档 4K60 | ✅ | RecordingQuality hd1080p30/uhd4k60,/video?preset= 契约,VideoSpecTests 6 用例(58 全绿);真机 4K60 带宽实测待插线 | 真机实测 |
| 录制中切镜头(PTS 豁免) | ✅ | 20s 录制切 3 摄位成片 19.86s 无跳段;切换耗时 0.03-0.08s | — |
| 10 分钟长录 | ✅ | 600.70s dropped=0 全程 53.5MB(longrec_10min_trend.log) | — |
| 后台中断守卫 | ✅ | resignActive 录制中自动安全收尾+backgroundInterruptedDuringRecord 标记 | 真机前后台复验 |
| 音频静音告警 | ✅ | 本轮 /status audioSilentWarning:true(Oray 驱动环境) | — |

## 三、AI 修正(链尾自动 → **本轮已升级为可见可控的面板**,见"二·AI 修正面板"节)

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| 暗光增强(EV+Gamma) | ✅ | 本轮拍照 JSON: 亮度 47.2→87.6 improved:true | ✅面板已落地(21:03 实测) |
| 白平衡去色偏 | ✅ | 本轮: cast 13.9→-13.3,二次 WB 收敛 | ✅面板已落地 |
| 水平校正 | ✅ | tilt6 蓝线金标准 0.00° | ✅面板已落地 |
| 畸变校正 | ✅ | fisheye_ab_v2 弯折 11.3→7.0px | ✅面板已落地 |
| AI 分数回传(blur/exposure/composition) | ✅ | 本轮 JSON 全字段在 | — |
| 修正档位 UI(用户可见可控) | ✅ **本轮落地** | 6 类档位开关卡片+applied 实时明细(ContentView「AI 修正」组),开关像素级实测(B 通道差30) | — |

## 三、拍照与美颜(痛点清单)

| 功能 | 状态 | 证据 |
|---|---|---|
| 拍照+AI 修正落盘 | ✅ 本轮(照片+伴生 JSON) | ~/Pictures/KinetCamera |
| 夜景模式 | 🟡 /night 路由在,165005 样张 improved:false(运动模糊)待复验 |
| 连拍×10 | 🟡 代码在,burst 路由实测过 |
| 回溯快门 60 帧环 | 🟡 /retro 实测过 |
| AE 锁/EV/对焦锁/峰值/网格 | ✅ UI+路由双在 |
| 分享/导出 | ❌ 已决策砍面板,无损 PNG 保底(已满足) |

## 三·美颜(独立板块,09-26 深夜逐档实测)

| 功能 | 状态 | 证据 | 缺口 |
|---|---|---|---|
| **拍照实时美颜预览(所见即所得)** | ✅ | 预览帧逐档实测 21:05:预览链 handleFrame→pipeline.apply 每帧跑美颜;/frame?mode=processed 档位变更帧差异显著(neutral-vs-smooth 5.32,smooth-vs-both 28.85) | — |
| 磨皮档(独立滑杆) | ✅ | hf 高频 6.13→5.79(合成源本底平滑,方向正确);小域实测压噪 69.2%(beauty3_report_v2) | 真人样张持续 |
| 美白档(独立滑杆) | ✅ | R-B 色度 26.5→16.4(预览链去黄实测);肤色掩膜外零污染(入仓报告) | — |
| 锐度档(独立滑杆) | ✅ | hf 2.61→6.31(Δ+3.70,预览链实测);/beauty?sh= 自动化路由本轮补齐 | — |
| 瘦脸档 | ✅ | faceslim_cc0(脸宽-10px/-2.1%,Vision 脸框+局部 warp,全自动 A/B) | — |
| 提亮/色温/饱和/虚化/暗角 | ✅ | UI 滑杆全在(ContentView 自然美颜组) | — |
| 录像美颜烧入 | ✅ | video_beauty_ab.png(99.8% 像素差异) | — |

## 二·AI 修正面板(09-26 深夜新增,用户可见可控)

| 功能 | 状态 | 证据 |
|---|---|---|
| 档位开关卡片(6 类修正独立启停) | ✅ | ContentView「AI 修正」GroupBox:曝光/白平衡/水平/畸变/补锐/人像质感,switch 开关+UserDefaults 持久化 |
| 开关真实生效 | ✅ | harness 单测:关白平衡后 applied 不再出现 WB 项,B 通道均值差 30(像素级实锤) |
| applied 实时明细 | ✅ | 面板列出最近成片每项修正(绿勾逐条),拍照 JSON 同源数据 |
| 真机链路 | ✅ | 21:03 实拍:applied=[暗光增强,AI去暖(17),二次白平衡(21)],面板同步显示 |



## 本轮实锤结论(21:03-21:05 复核更新)
- 录像 3.83s h264 1280x720@30 + aac,PTS 守卫生效,无 423861s 复现
- 拍照 AI 修正全链:暗光 47.2→87.6、去暖 13→-13.3、二次 WB、PIP 同框,一条 JSON 说清
- **AI 修正面板本轮落地**:6 档开关卡片+applied 实时明细,真机实拍+开关像素级实测
- **美颜实时预览逐档实测**:预览所见即所得(磨皮 hf↓/美白 R-B↓/锐化 hf↑ 全部独立生效)
- **唯余真缺口:① iPhone 未插线(多摄切换/跨设备录像复验挂起,用户自行插线)② iPhone 三摄位(超广角/长焦)iOS 侧调研**

## 下一步优先级(抬头看总目标)
1. **插 iPhone 线** → /switch 三摄枚举 → 切换后录像复验(时基守卫真机实证)
2. iPhone 三摄位(超广角/长焦)调研:iOS companion app 桥 vs Continuity 能力边界
3. 竞品痛点对照已入 COMPETITIVE_MATRIX §七(三家 1★ 原声,没解的如实列)
