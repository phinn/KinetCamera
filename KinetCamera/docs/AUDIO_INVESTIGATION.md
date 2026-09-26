# 麦克风 -91dB 全零流调查(2026-09-26,终版)

## 结论(定级:系统层,app 无修复点)

**数据在 HAL→coreaudiod→客户端搬运段被替换为全零,非 DSP/格式/app 层问题。**
等待一个变量:重启 Mac(怀疑 ExclaveDSP/Oray 虚拟驱动钩死 coreaudiod)。
重启后跑 `scripts/post_reboot_verify.sh` 第①步 aq_probe,peak 非零即闭环。

## 四层采集栈交叉取证(09-26 16:00-18:30 实测)

| 层 | 工具 | 结果 |
|---|---|---|
| L9 AudioQueue 直采 | `scripts/aq_probe.swift`(绕 AVF) | frames=32 peak=0.0000 **-200.0dB** |
| L8 HAL 直采 | `scripts/hal_probe.swift` | 采集在跑但数据全零 |
| L7 AVAudioEngine | `scripts/audio_probe.swift` | frames=282 peak=1e-10 **-200dB** |
| L6 ffmpeg avfoundation | `ffmpeg -f avfoundation` | mean **-91dB** max -91dB |
| coreaudiod 侧 | `log stream` | IO 正常 **145408 帧**(≈3s@48k),"stopping with error 0" |

## 已排除项(全部实测排除,不是猜)

- ❌ 硬件静音:HAL `mute=0(r=0) vol=1.0(r=0) isRunning=1`,dataSource=imic
- ❌ 输入源选择:内置麦/Oray 虚拟/Teams 虚拟 **三源 × 四栈** 全零
- ❌ 系统输入音量:设置面板 100%
- ❌ app 层格式/声道:录像音轨 aac 48k 正常写(全零 payload,是上游数据如此)
- ❌ AVF 会话配置:录音/拍照链路本身正常(视频 30fps 成片为证)
- ⚠️ sudo 拔 OrayVirtualAudioDevice.driver:`sudo -n` 失效(需密码),无法无人值守拔驱

## 复验步骤(重启后)

```bash
bash scripts/post_reboot_verify.sh   # 第①步即 aq_probe 声学闭环
# 单独跑:
xcrun swiftc -O -parse-as-library -o /tmp/aq_verify scripts/aq_probe.swift && /tmp/aq_verify
# peak=0.0xxx 非零 → 硬件层恢复,悬案闭环
# 仍全零 → 定级硬件/iBridge MIC 故障,走 Apple Store 硬件诊断
```

## 影响面

- 录像音轨:aac 轨正常写入(48k 单声道),payload 全零 → 成片有声轨无声音
- 其余功能(拍照/录像/美颜/AI 修正/多摄)零影响

## 关联修复(本轮 09-26)

- 录像音频 format:outputSettings 从硬编码 44.1k/2ch 改为运行时读
  `CMAudioFormatDescription`(内置麦实际 48k/1ch),消除 AVAssetWriter -16364 第二嫌疑人
- `post_reboot_verify.sh` aq_probe 编译参数补 `-parse-as-library`(main attribute 与顶层代码冲突)

## 追加取证(09-26 晚,用户定性"没声=bug"后深挖)

### 新增排除项

- ❌ TCC 授权:`AVCaptureDevice.authorizationStatus(for: .audio)` = **3 authorized**
- ❌ 默认设备错位:默认输入 = 内置麦 dev100(48k/1ch,格式查询正常)
- ❌ 设备枚举异常:全系统仅 3 个输入源(内置麦 BuiltIn / Teams / Oray 均 Virtual),无劫持

### VPIO 语音处理单元直采(scripts/vpio_probe.swift,层10)

```
VoiceProcessingIO 单元:cb/init/start 全 0,render 回调 5s 收 220148 帧
frames=220148 peak=0.0000 dB=-200.0 renderErr=0
```

**Apple 自家语音 DSP 单元也只拿到全零** → 数据在 ExclaveDSP(音频协处理器)/内核
音频驱动层就被替换为零,所有用户态采集栈(AQ/HAL/AVF/ffmpeg/VPIO)共享同一上游。

### 确认出声的两条路径(按优先级)

1. **重启 Mac**(用户态零操作):清 ExclaveDSP/Oray 驱动在 coreaudiod 的僵尸状态。
   重启后一键复验:`bash scripts/post_reboot_verify.sh`
2. **不重启,终端执行(root)**:重启音频守护进程
   ```bash
   sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
   # 可选:卸载可疑虚拟声卡驱动后重启守护
   # sudo kextunload -b com.oray....; sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
   ```
   然后复验:`xcrun swiftc -O -parse-as-library -o /tmp/vpio scripts/vpio_probe.swift
   -framework AudioUnit -framework CoreAudio -framework Foundation && /tmp/vpio`
   peak 非 0.0000 = 修复完成,录像立即有真声(录像链 aac 写入一直是好的,零是上游数据)。

### 两条都失败的定级

ExclaveDSP 音频协处理器固件级故障 → Apple Store 硬件诊断(app 无任何可修点,
四层+VPIO 五路取证已穷尽用户态所有手段)。
