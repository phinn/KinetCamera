# 痛点 Top5(09-26 晚定稿)

> 从 14 条全量痛点(PAIN_POINTS.md)按用户价值排序的前 5 条,每条标注解决状态与对应模块。

| # | 痛点 | 解决状态 | 对应模块 | 实测证据 |
|---|------|---------|---------|---------|
| 1 | **照片歪斜** —— 拍文档/地平线斜,后期还要转正裁一遍 | ✅ 已闭环 | AIAnalyzer(VNDetectHorizonRequest)+ FilterPipeline(CIStraightenFilter+内接裁切) | 6°倾斜图校正后二次检测 0.0°(ai_fix3_report.json) |
| 2 | **暗光拍照一片黑+噪点爆炸** | ✅ 已闭环 | AIAnalyzer 暗光判定(bias<-0.45)+ FilterPipeline 暗光增强档(EV+1.3+Gamma0.78+降噪+终末二次WB) | lum 68.3→99+,cast 全档收敛\|<9\| |
| 3 | **录完视频才发现没声音** —— 系统相机静音录完才傻眼 | ✅ 已闭环 | CameraManager.writeAudioSample(逐块PCM峰值)+ ContentView(speaker.slash告警)+ 落盘 audio.json 打标 | 全零音轨环境端到端:实时告警触发+{audioSilent:true,audioPeakDB:-200}(video_audio.json) |
| 4 | **自拍脸变形+肤色差** —— 广角畸变+暗黄+毛孔,发出去前要修图 | ✅ 已闭环(真人样张待拍) | FilterPipeline 三档(磨皮0.7压噪78.6%/美白0.6肤区+6去黄/瘦脸0.8下颌-5~-17px)+ radialDistortionCorrect 畸变校正 | beauty3_ab.png + 畸变残差98.34→19.13;本日录像美颜烧入实测 99.8% 像素差异(video_beauty_ab.png) |
| 5 | **广角自拍边缘拉伸/鼓出** | ✅ 已闭环 | AIAnalyzer fisheyeHint(人脸贴边+宽高比)+ FilterPipeline radialDistortionCorrect(CPU径向位移场) | 数学闭环:预桶形98.34→校正19.13(压回80.5%) |

## 全链路验证(合成输入源,09-26 晚)

**拍照链**:KinetSynthetic 合成源(确定性 30fps)→ 美颜三档(s0.7/w0.6/slim0.8)→ AI修正(自适应:提亮档/暗光增强档随输入切换)→ PNG+JSON 落盘
- 美颜关/开:88.3% 像素变化;AI修正 improved:true(双档证据 pipeline_full_ab.png + off/on JSON)

**录像链**:同源 → 录像美颜 GPU 快速档烧入 → h264 720p30+aac 成片(6.87s/206帧)
- 美颜关/开同帧位:99.8% 像素差异,高频 1.38→5.89(video_beauty_ab.png)
- 实时美颜预览:30fps 整(mainFrameCount 22502→22655/5s,美颜开启状态)

## 遗留(非本轮)

- 真人样张一次性补拍:坐镜头前后 1 组美颜 before/after(管线已验证,只差真脸输入)
- 真人样张一次性补拍:AI修正四档 A/B 同理
