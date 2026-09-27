# 竞品对标差距清单(09-27,用户钦定:Halide / 原生相机 / 美图)

对标基线:KinetCamera @336ab68(软件链 18 痛点 16 闭环)。仅列**真差距**,已达标项不凑数。

## 用户点名四大痛点现状

| 痛点 | 现状 | 判定 |
|---|---|---|
| 快门延迟 | 帧流快门:回包 23ms(模拟器),零"按下调焦再拍"延迟;帧环常驻 | ✅ 达标(真机数字待 v3 补) |
| 糊片 | /steady 多帧对齐 + 暗光 MFNR 3 帧 + 锐度选帧(候选16取8) | ✅ 达标 |
| 变焦跳变 | 24 帧 easeOutCubic 缓动 + 硬件 clamp;**缺多摄位无缝接力** | 🟡 单摄内达标 |
| 暗光噪点 | 暗光档(EV+Gamma+降噪+二次WB)+ 夜拍 8 帧堆栈 | ✅ 达标(裸眼对照待真机) |

## 真差距(按"超越所有拍照软件"目标排序)

### A. 架构级(拍照画质天花板)
| # | 差距 | 竞品参照 | 落地方案 | 优先级 |
|---|---|---|---|---|
| A1 | **拍照分辨率被预览流钳制**(videoDataOutput 1080p/4K30;Halide/原生走 AVCapturePhotoOutput 全画幅 12MP/48MP ProRAW) | Halide 48MP、原生 24MP | 双通道:保留帧流快门(美颜/回溯/连拍),新增 `photoOutput.capturePhoto` 全画幅直拍档(iOS 真机才有意义),EXIF/P3 链复用 | **P0(真机插线后第一件事)** |
| A2 | **无 ProRAW/DNG**(Halide 核心卖点;单帧 8bit 信息上限锁死 HDR/降噪天花板) | Halide ProRAW 48MP | iOS 侧 `AVCapturePhotoOutput.maxPhotoQualityMode = .raw`,DNG 导入既有 RAW 方案 A | P1 |
| A3 | **无 Live Photo**(原生标配;动态记忆场景刚需) | 原生 | 低优先:配对视频轨 3s 前后录制,双轨 writer 已有基建 | P2 |

### B. 控制级(专业手感)
| # | 差距 | 竞品参照 | 落地方案 | 优先级 |
|---|---|---|---|---|
| B1 | **iOS 手动曝光缺位**(macOS 平台墙已实证;iOS 有 `setExposureModeCustom(duration:iso:)` 未实现) | Halide 全手动 | iOS 分支补 duration/ISO 双滑杆 + AutomationServer /exposure?iso=&dur=;真机出实测 | **P0** |
| B2 | **iOS 手动对焦缺位**(`setFocusModeLocked(lensPosition:)` iOS-only 未接) | Halide 对焦滑杆/放大镜 | iOS 分支 lensPosition 0-1 滑杆;峰值对焦已有(FilterPipeline 品红伪色 ✓) | **P0** |
| B3 | **变焦三摄位接力不平滑**(1x↔0.5x↔5x 切摄位时画面跳切;Halide/原生做 seamless ramp) | 原生相机的无缝变焦 | 切摄位时先 zoomFactor 软件裁切过渡到位再换设备 + 帧间交叉淡化(帧环已有素材) | P1 |
| B4 | **无网格/水平仪**(原生标配;拍文档/地平线用户习惯依赖) | 原生 3x3 网格 | CIRenderView 叠加层:3x3 网格 + VNDetectHorizonRequest 实时水平线(歪斜检测已有,复用) | P1(纯 UI 半天) |

### C. 场景级(大众吸引力)
| # | 差距 | 竞品参照 | 落地方案 | 优先级 |
|---|---|---|---|---|
| C1 | **无闪光灯控制**(暗房场景直接废;iOS torchMode/flashMode 未接) | 全部竞品 | iOS: flashMode auto/on/off 传 AVCapturePhotoOutput;预览态 torchMode | P0(真机) |
| C2 | **人像景深无光斑形状/强度档**(美图/原生的景深可调 f 值) | 美图 f1.4-f16 档 | 虚化 radius 已有,补光斑形状(CIDiscBlur→六边形核)+强度档 UI | P2 |
| C3 | **美颜无"素颜校准"**(美图的肤色分区比我们细:面部区域/颈部色差处理) | 美图一键素颜 | 肤色掩膜已有,补 Vision 人脸多区域(脸颊/额头/T区)分区强度 | P2 |

## 判定:已达标不再追的
- 滤镜链质感(磨皮保边 94%/美白零背景污染)——超美图无痕档
- 多摄切换 0.03s(超原生体感)
- 回溯快门/连拍零丢帧(原生 Live 式回看我们没有,但"拍完选最好一张"体验等价)
- EXIF/P3 跨设备色彩一致(Halide 也要装插件才有同等 ICC 控制)
- 录像 PTS 守卫/长录零丢帧(原生 4K60 长录会发热掉帧,我们 dropped=0)

## 行动序(真机插线后)
1. `bash scripts/iphone_acceptance_v3.sh device` 出 7 项实测数字(30 分钟)
2. P0 三连:iOS 手动曝光 + 手动对焦 + 闪光灯(同一次 commit,真机编译验证)
3. P0:A1 全画幅 photoOutput 档(架构改动,单开分支)
4. P1:网格水平仪(纯 UI,可先落)+ 变焦接力
5. P1:A2 ProRAW(依赖 A1 photoOutput 基建)
