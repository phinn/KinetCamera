# 视频专项验收 2026-09-27(变焦/4K60/切镜/长录/前后台/交付底线)

> 承接 docs/SIM_E2E_20260927.md。本篇覆盖"用户会踩到的 5 类视频坑"逐一实测,
> 外加交付底线(EXIF/ICC)修复与验收脚本干跑。设备:iPhone 16 Pro 模拟器(UDID F3FDC20D),
> 合成源三摄位(synth.wide/uw/tele)。**真机数字待插线后由 iphone_acceptance_v2.sh 补齐**。

## 专项清单与结论

| # | 专项 | 方法 | 结果 | 判定 |
|---|------|------|------|------|
| 1 | 变焦档位收敛 | `/zoom?f=2` / `f=99` → /status | 2.0 / 8.0(formatMax 16 内 clamp 质量上限) | ✅ |
| 2 | 4K60 质量档 | RecordingQuality 枚举 + preset 映射单测 + /video?preset | 1080p30↔4K60 rawValue 稳定、fps/minWidth/preset 全对 | ✅(逻辑层;真机带宽实测待补) |
| 3 | 录制中切镜头 | 20s 录制内切 3 次摄位 | 成片 19.86s、PTS 豁免窗口生效、无 -16364 | ✅ |
| 4 | 10 分钟长录 | 600s 录制 + 每分钟采样 | 成片 600.70s、dropped=0 全程、fps 8-16 波动但无降档趋势、53.5MB | ✅ |
| 5 | 前后台切换 | resignActive 守卫 | 后台 writer 饿死 bug 已修:自动安全收尾 + backgroundInterruptedDuringRecord 标记 | ✅(headless 限制:模拟器无 resignActive,逻辑由守卫+单测覆盖) |
| 6 | EXIF Make/Model | 字节级检验 | 设备为 nil 兜底 "KinetCamera Virtual Camera",不再裸奔 | ✅ |
| 7 | ICC Display P3 | ICC header/mluc 解析 | JPEG 内嵌 Apple mntr/RGB v4 ICC,desc="Display P3"(UTF-16BE mluc) | ✅ |

## 长录趋势(600s,完整日志 docs/evidence/longrec_10min_trend.log)

```
t=1..10min fps=11/9/13/8/10/13/10/12/16/12 dropped=0(全程) rec=True(全程)
final: duration=600.7017s, 6089 包, 1280x720, 53.5MB
```

fps 波动(8-16)是模拟器软渲染 + 美颜链的合成源特性,真机 Metal 路径预期 30fps 稳定;
关键判据 **dropped=0、录制会话不断、时长零丢失** 全部成立。

## 录制中切镜(PTS 豁免窗口)

- 摄位 pattern 重建实测产生 0.53~1.5s 帧间隙,落在 isPTSDiscontinuity(>0.5s 前跳)判定带;
- 豁免窗口在切换后 N 帧内放行间隙,避免触发时基重对齐 → 成片 19.86s(切 3 次)无跳变无丢段;
- 单测:VideoSpecTests.testPTSDiscontinuityThresholds 覆盖 0.033/0.4/-0.3/0.6/1.512 五点。

## 交付底线修复(干跑第 1 轮抓到的产品缺陷)

1. **EXIF Make/Model**:设备为 nil(合成源/极端态)时此前完全缺失 → 现在 TIFF/Lens 四字段兜底
   "KinetCamera / KinetCamera Virtual Camera"。真机上仍写 device.manufacturer(Apple)。
2. **ICC Display P3**:JPEG 此前零 ICC → savePhoto 落盘前 rebindToP3()(CGContext 1:1 零重采样
   拷贝到 P3 色彩空间),ImageIO 自动嵌入源空间 ICC。字节级验证:APP2 ICC_PROFILE 段存在,
   header `appl/mntr/RGB/XYZ v4`,desc tag(mluc UTF-16BE)解出 "Display P3"。

## iphone_acceptance_v2.sh 干跑记录(4 轮,抓 5 bug 全修)

| 轮 | 抓到的问题 | 修法 |
|----|-----------|------|
| 1 | /aicorrect 等三个路由不存在(AI 修正实际随拍照链 autoAdapt 生效) | 第 6 步改判 autoAdapt + lastReport |
| 1 | $C/xxx GET 请求打 POST-only 路由 → 404 "not found" | CX() 统一 POST 入口 |
| 1 | 模拟器 find 只拉 .mov;marker 文件不存在时 -newer 全 false | jpg/mov/png 全拉 + marker 空数组兜底 |
| 2 | beauty 参数 `&` 在 $C 变量展开后未引用 → 后台化 | 完整 URL 双引号 |
| 3 | 合成源态 devices 空 → 切换步 "未匹配" 空转 | simulator 目标走 /synthLens |
| 4 | P3 描述符 ASCII 搜不到(mluc 是 UTF-16BE) | 双编码搜索;Make 判据按 target 分支 |

第 4 轮 8 步全绿:通道 OK → 合成源态识别 → 10s 帧率基线(processedFps 24-28/dropped 0)→
6 次摄位切换 0.03-0.08s → 美颜实拍 ok → AI 修正实拍(applied="提亮+0.8EV,AI去暖(17),二次白平衡(13)",
improved=true)→ 产物拉回(jpg×6+)→ EXIF/P3/对焦三项判定通过。

## 单测

VideoSpecTests.swift 新增 6 用例(质量档语义/映射/rawValue 契约/zoom clamp/PTS 阈值),
macOS 全量 **58 tests, 0 failures**;iOS scheme BUILD SUCCEEDED。

## 真机待补(脚本已就绪,插线即跑)

`bash scripts/iphone_acceptance_v2.sh device` —— iproxy 17878 隧道 + devicectl 装包/截图/拉产物,
8 步同上,判据切到真机口径(Make=Apple、MultiCam 三路真帧率、4K60 真带宽)。
