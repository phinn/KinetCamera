# Top5 拍照痛点 × KinetCamera 能力对照 + AI 修正方案(2026-09-27)

> 对标口径:用户点名五大痛点(夜景糊/逆光死黑/抓拍糊/对焦拉风箱/美颜假脸)。
> 每条给出:现状(已有功能+实测证据)/ 缺口(明确到具体模块)/ AI 修正方案(引擎·模型·端侧算力·落地路径)。

---

## ① 夜景糊(高ISO噪点+长曝光手抖)

**现状(已有)**
- `/night` 夜拍:AIAnalyzer 暗光检测→提亮链,两次实测 improved:true(曝光分 57→81、46.7→84.9)
- 磨皮链(GuidedFilter r≈11, eps=0.0225)在正常光下压噪 69.2%(9.83→3.03 高频能量)
- 硬件链:ISO/曝光时长从 AVCaptureDevice 读入 EXIF;录像路径 GPU 快速档实时不掉帧

**缺口**
- 暗光下磨皮 hf 反升(+19.2%~+25.0%)——photo 路径细节回注把噪点当细节放大,**未修**(待办在案)
- 无多帧降噪(MFNR):单帧提亮=提噪。iPhone 系统相机夜景是 3-9 帧对齐融合
- 无 OIS 补偿感知/长曝光稳态检测

**AI 修正方案**
| 层 | 方案 | 算力 |
|---|---|---|
| 端侧推理 | **Apple Vision.framework / Core ML 跑 APISR 类轻量超分-降噪**(<10MB INT8 模型,ANE 专属) | A17 Pro ANE 15.8 TOPS,4K 帧推理 ~15ms |
| 多帧 | **自研 MFNR:AVCapturePhotoCaptureDevice 连拍 3-5 帧 → CMTileFabric/自写块匹配对齐(OpenCV phasecorrelate 移植 vImage)→ 时域中值**。纯 Accelerate/vDSP,无需模型 | CPU/GPU,1080p 单帧对齐 ~8ms |
| 快速落地 | 先修暗光磨皮反升(噪点方差 σ 自适应:wEdge 阈值 σ×3.5 当 brightness<60),再把 night 提亮改到**去噪后**(顺序反了是根因嫌疑) | 纯 CPU,零模型 |

**优先级**:先做纯算法修复(本周),MFNR P1,超分模型 P2。

---

## ② 逆光死黑(高动态范围)

**现状(已有)**
- `/hdr`:暗场死黑 95.88%→0.41%(像素占比),链路=多帧合成+局部提亮
- AIAnalyzer.colorCast/exposureScore 驱动自动修正,`applied` 字段带 before/after 证据
- EV 软件档 ±2(CIExposureAdjust),AE Lock 软件层

**缺口**
- 无真 HDR 多帧融合(单帧 tone mapping 撑不起 12EV 场景)
- EV 修正分数不动疑云:exposureScore 分析 raw 帧未过滤镜链,`/exposure?ev=1` 曝光分 42.5→43 几乎不动,**未定位**
- 无局部 tone mapping(全局提亮会把天空拉爆)

**AI 修正方案**
- **局部色调映射:CLAUDE 式双边网格(bilateral grid approximation)→ CIColorCube 52 lookup?不,直接 CIHighlightShadowAdjust + 引导图(GuidedFilter 已有!)做 based 暗部增强**——复用现有 GuidedFilter 做亮度引导层,把暗部增强图按 mask 回注。零新依赖,P0 可落地
- 真融合:AVCapturePhotoHDRSettings(苹果官方 HDR 管线,iOS/macos26 可用,零成本)优先于自研
- AI 分数闭环:exposureScore 改分析 processed 帧(与预览同源),修正建议才真实——**这个 bug 修掉,AI 修正才算闭环**

---

## ③ 抓拍糊(快门时机)

**现状(已有)**
- 60 帧回溯环(2s)+ `/retro`:AIAnalyzer.blurScore 挑环内最优帧落盘——**这是全行业少有的杀手锏**(Halide 无此功能)
- blurScore = Laplacian 高频能量,帧级可量化

**缺口**
- blurScore 只看全局清晰度,**人脸场景没锁脸清晰度**(糊背景清晰脸或反之)
- 无"最高峰预测":选已发生帧,没有预测下一帧趋势(体育/宠物场景差半拍)
- 连拍 burst 无 AI 筛选(全落盘,用户自己翻)

**AI 修正方案**
- **脸区 blurScore:Vision VNDetectFaceRectangles 已在链上(faceDetect),给脸框内单独算 Laplacian,综合分=0.6×脸清晰+0.4×全局**——纯 CPU,零新模型,P0
- 时序预测:环内最近 10 帧 blurScore 拟合斜率,峰值外推 2-3 帧,**连拍预采**(burst 3 张按预测时刻触发)。轻量,无需模型
- burst AI 筛:拍摄完成后后台跑 blurScore+eyeblink(Vision VIN VNDetectEyeClosed?→ 无现成,用 InterEyeDistance+blur 组合),只保留 top2。P1

---

## ④ 对焦拉风箱(来回呼吸)

**现状(已有)**
- `/focus?mode=lock|auto`:toggleFocusLock 防拉风箱(锁死对焦)
- 对焦峰值 peaking(manual 辅助)
- macOS 内置摄 focus 模式列表为空(API 墙),iPhone 真机有 lensPosition 全套

**缺口**
- macOS 平台墙:连续变焦 API(lensPosition)编译期 unavailable——**iPhone 上才可解,macOS 无解(硬件限制,已在能力矩阵声明)**
- iPhone 真机未实弹验证(挂起清单里)
- 无"AI 防风箱":自动档下 subject change 检测,只在换主体时 re-focus

**AI 修正方案**
- **iOS:VNDetectFaceRectangles 驱动持续对焦**:脸框中心变化>15% 屏宽才触发 re-focus(单次 lensPosition 扫描 0.0-1.0 二分找 blurScore 峰,~200ms),其余时间锁住。 Vision+AVFoundation 纯端侧,零模型下载
- 焦点呼吸抑制:录像路径用 cinematoVideoStabilization 配置 + `setFocusModeLocked(lensPosition:)` 平滑插值(20 步 easing,复用 zoom 的 Timer 插值骨架)
- macOS:维持 lock 档+peaking(硬件墙,不做假承诺)

---

## ⑤ 美颜假脸(磨皮过度/塑料感)

**现状(已有,这是主打)**
- 边缘感知磨皮:GuidedFilter+软阈值 wEdge=max(0,|hf|-2.5σ)/|hf),**纹保留,只压噪**——对比竞品 1★ 抱怨的"橡皮人"是结构性差异
- 瘦脸用 faceRect 几何 warp(peakShift=0.045×strength×脸宽),量化验证 -0.88% 脸带宽
- 实时性:30fps 全开(磨0.7+白0.6+锐0.5)GPU 快速档,实测滑窗 30-31fps 不掉帧
- 全参数独立档位+UI 实时预览所见即所得(录进成片)

**缺口**
- 肤色掩膜是 CPU pass(条件触发),暗光下肤色判据(R>G+8 且 G>B+4 且亮度>60)会失效→美白不均
- 无"美型"级(大眼/隆鼻/下巴)— 行业有,但正是"假脸"重灾区,**刻意不做**是产品决策(写在 PAIN_POINTS)
- 无 AI 场景自适应(强光自动降磨皮,暗光自动加压噪)

**AI 修正方案**
- **肤色判据升级 YCbCr 域**(77≤Cb≤127, 133≤Cr≤173 经典区间)+亮度归一化,暗光鲁棒性显著提升——纯数学,零模型,P0
- **AI 场景自适应:AIAnalyzer 已有 brightness/blur/colorCast 三分数**,把它们喂给 FilterPipeline 做参数自动微调(暗光:磨皮+0.1 锐化+0.1;强光逆光:提亮+0.15)。规则引擎先行,零模型
- 生成式美颜(diffusion 改脸)明确**不做**:算力(>3GB 显存/50ms+)、假脸伦理、与"零订阅本地方案"定位冲突——**这是对假脸痛点的根本性回答:规则感知+保边,不换头**

---

## AI 修正整体架构(引擎/模型/算力)

```
┌─ 感知层(已有,帧级)─ AIAnalyzer:blurScore/exposureScore/colorCast/faceCount/faceRect
│   ↑ Vision(VNDetectFace/HumanSeg) + vDSP Laplacian/直方图,零模型下载,~2ms/帧@1080p
│
├─ 决策层(新增,规则引擎 P0)─ CorrectionEngine:
│   brightness<60 → 磨皮σ阈值×1.4 + 提亮优先
│   colorCast>阈值 → 色温补偿
│   faceRect 有效 → 脸区加权 blurScore / 瘦脸/美白局部化
│   全规则可解释、可关、零延迟 —— 「AI 修正不黑盒」卖点
│
├─ 执行层(已有)─ FilterPipeline:Guided磨皮/CPU美白掩膜/分割虚化/warp瘦脸/CIGamma锐化
│   GPU .video 快速档(录像/预览) / CPU .photo 全画质(拍照)
│
└─ 生成层(P2,可选)─ Core ML:轻量超分-降噪(ANE,<10MB INT8) / 胶片LUT(CIColorCube)
    明确不做:生成式换脸/大模型美型
```

**端侧算力账(M2/M3 Mac + A17 Pro iPhone)**:
- 感知层 ~2ms/帧,执行层 GPU 已证 30fps,规则决策 <0.1ms → 全链路 AI 实时无压力
- ANE 超分预留 ~15ms/1080p → 拍照路径可承受,录像路径关闭(保 30fps)

## 与 Top5 对应的落地排期
| 痛点 | P0(纯算法,本周) | P1 | P2 |
|---|---|---|---|
| 夜景糊 | 暗光磨皮反升修复+去噪先行 | MFNR 3-5帧 | ANE 超分 |
| 逆光死黑 | exposureScore 修 processed 帧+GuidedFilter 暗部增强 | AVCapturePhotoHDRSettings | 自研融合 |
| 抓拍糊 | 脸区 blurScore 加权 | burst AI 筛 | 时序预测 |
| 拉风箱 | iOS 脸变检测触发 re-focus | cine 对焦平滑 | — |
| 假脸 | YCbCr 肤色域+场景自适应规则 | — | —(生成式不做) |

## 竞品横评(为什么"超越")
- Halide:订阅墙 $70/年+卡死丢素材 → KinetCamera 零订阅+本地方案
- ProCamera:未拍先弹订阅 → 我们零弹窗
- 系统相机:回溯快门无/美颜无/AI 参数不可见 → 我们 2s 回溯+全参数可见
- 美图类:磨皮橡皮人+生成式换头 → 我们边缘感知保纹+拒绝换脸
