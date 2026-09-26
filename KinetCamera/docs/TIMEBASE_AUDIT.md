# 录像时基 / 帧同步隐患全链路排查清单(2026-09-26)

> 背景:423861s(~4.9天)成片事故 = 录制中切换设备,新设备 PTS 时基与旧设备断崖。
> 本轮对**全部时间戳/时基/帧同步路径逐行排查**,决策面抽进 `DevicePolicy` 纯函数
> (`isPTSDiscontinuity` / `safeAudioPTS` / `shouldResetFrameRing`),并用单测钉死边界。
> 排查范围:CameraManager.swift 全部 CMTime 出入口 + 帧环 + 回溯快门 + PIP。

## 一、排查点位清单(逐行过)

| # | 点位 | 位置 | 隐患 | 状态 |
|---|------|------|------|------|
| 1 | 视频首帧 `startSession(atSourceTime:)` | writeVideoFrame | 只对首帧,本身无恙 | ✅ 已有 |
| 2 | **录制中 PTS 断崖检测** | writeVideoFrame | 前帧间隔 >0.5s / 倒跳 >0.2s = 断裂 → 重对齐 session | ✅ 守卫在,决策抽为 `isPTSDiscontinuity`+7 单测(423861.0 必须命中) |
| 3 | **音频 PTS 平移锚** | writeAudioSample | 麦克风走宿主时钟(开机秒数),视频 PTS 从 0 起 → 不平移则音轨几十万秒 | ✅ 已有,锚=首条音频 vs sessionStartPTS |
| 4 | **音频平移后负 PTS** | writeAudioSample | 平移后 <0 触发 AVAssetWriter -16364,writer cancelled 成片无 moov | ✅ 原 guard<0,升级 `safeAudioPTS`:负值/NaN/±Inf 全拦,单测钉死 |
| 5 | 音频 duration 无效值 | writeAudioSample | duration=0/timescale=0 的 buffer CreateCopyWithNewTiming 产出非法样本 | ✅ 已有兜底 1024/48000 |
| 6 | **帧环跨时基混环**(本轮新发现) | pushRing | 设备切换/合成源接管后,新源 PTS 时基不同;60 帧环里新旧两时基混存 → 夜拍/防抖运动补偿对齐把"换源"误判成"位移",合成鬼影 | 🔧 **本轮修复**:`shouldResetFrameRing` 断裂即清环重开,单测钉死双向断裂 |
| 7 | 回溯快门取帧时间戳 | recentFrames | 取 suffix(N) 保持时间正序,帧环已保证单时基(#6 修后) | ✅ #6 修复后自然成立 |
| 8 | 音频先行于视频(startSession 未对齐就写音频) | writeAudioSample | `guard sessionStartAligned` 挡住 | ✅ 已有 |
| 9 | 录制中设备切换 | switchDevice | `canSwitch(isRecording:)` 拒绝,写坏文件入口已封 | ✅ 已有 |
| 10 | 录制中变焦 | setZoom | `guard !isRecording` 拒绝,防跳帧 | ✅ 已有 |
| 11 | PIP 烧入 PTS | recordFilter | PIP 是快照静帧(CIImage),不带时序,无 PTS 语义 | ✅ 无风险 |
| 12 | 跨设备 PTS 桥接(PIP 子会话→合成) | FrameCompositor | lastVideoPTS 守卫已修(09-26 轮,7b41150) | ✅ 已有 |
| 13 | 断连设备 NSException | captureOutput | isConnected 预检已修(09-26 轮) | ✅ 已有 |
| 14 | writer.startSession 二次调用的 AVFoundation 未定义行为 | writeVideoFrame 断裂分支 | 理论上 session 只能 start 一次;实测(macOS 27 SDK+iPhone 17 Pro 模拟器 26 用例+真机 49.14s 复验)二次 startSession 生效为重对齐。**遗留观察项**:若未来 SDK 收紧为 no-op,需改为"分段录像(结束当前 writer+新时基开新 writer)" | ⚠️ 挂观察,不影响当前正确性 |
| 15 | `recordingSeconds` 用墙钟(Date)而非 PTS | startRecording | 墙钟不受时基断裂影响,故意为之(UI 倒计时) | ✅ 设计如此 |

## 二、本轮实改(接进真路径,非纸上谈兵)

1. **pushRing 跨时基清环**(#6):`DevicePolicy.shouldResetFrameRing` 接入,换源断裂直接清环。这是逐行排查发现的**真 bug**——修复前:内置摄录 2s → 切合成源(健康检查拉起),环里 30 帧 PTS≈10 万秒 + 30 帧 PTS≈0 混存,`recentFrames(8)` 取出的夜拍/防抖窗口横跨两时基,运动补偿 SAD 对齐直接废。
2. **writeAudioSample NaN/Inf 守卫**(#4):原 `if pts < 0 return` 挡不住 NaN(NaN<0 == false,会穿透 append 给 writer),`safeAudioPTS` 用 `isFinite && >=0` 双条件。
3. **writeVideoFrame 断裂判定**(#2):决策抽到 DevicePolicy,行为不变,可测。

## 三、单测锁死(KinetCameraTests/TimebasePolicyTests.swift + DeviceWaitStateTests.swift)

- 正常帧距(30/24fps/掉帧 0.3s)不误报;0.5 恰在阈值内;0.51/42/423861 必命中
- 倒跳:-0.033(帧重排)容忍;-0.21/-3600 必命中
- 音频:恰 0 合法;负/NaN/±Inf 全拒
- 帧环:首帧不重置;连续帧不重置;双向断裂重置
- 组合链:宿主时钟 102337.9 平移到视频轴 0.433 → 守卫放行;未建锚 → 拒
- 状态机四路径(macOS + iOS 模拟器 双端 26/26 绿,见测试输出)

## 四、验收口径

- `xcodebuild test`(macOS):**Executed 26 tests, with 0 failures**
- `xcodebuild test`(iPhone 17 Pro 模拟器):**Executed 26 tests, with 0 failures**
- 真机录像 49.14s 时基正常(本轮 22:0x 复验);iPhone 插线后仍需跑"录中切换"实弹复验(自动化路由已备,真机到位即测)
