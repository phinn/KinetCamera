# 痛点 Top5(09-26 晚定稿)

> 从 14 条全量痛点(PAIN_POINTS.md)按用户价值排序的前 5 条,每条标注解决状态与对应模块。

| # | 痛点 | 解决状态 | 对应模块 | 实测证据 |
|---|------|---------|---------|---------|
| 1 | **照片歪斜** —— 拍文档/地平线斜,后期还要转正裁一遍 | ✅ 已闭环(09-26 深夜重写几何链) | AIAnalyzer(VNDetectHorizonRequest+中心旋转+CIToneCurve替代contrast) | 6.5°歪图→蓝线金标准 0.00° 转正,黑边0%,直方图黑峰零丢失(详见下节A/B) |
| 2 | **暗光拍照一片黑+噪点爆炸** | ✅ 已闭环 | AIAnalyzer 暗光判定(bias<-0.45)+ FilterPipeline 暗光增强档(EV+1.3+Gamma0.78+降噪+终末二次WB) | lum 68.3→99+,cast 全档收敛\|<9\| |
| 3 | **录完视频才发现没声音** —— 系统相机静音录完才傻眼 | ✅ 已闭环 | CameraManager.writeAudioSample(逐块PCM峰值)+ ContentView(speaker.slash告警)+ 落盘 audio.json 打标 | 全零音轨环境端到端:实时告警触发+{audioSilent:true,audioPeakDB:-200}(video_audio.json) |
| 4 | **自拍脸变形+肤色差** —— 广角畸变+暗黄+毛孔,发出去前要修图 | 🟡 两档新数据已闭环/瘦脸待真人样张 | FilterPipeline 磨皮(GF+软阈值回注)/美白(CPU肤色掩膜,双重美白bug已修)+radialDistortionCorrect | **现行有效**(09-26深夜二轮,当前HEAD重跑):磨皮0.7压噪69.2%(9.83→3.03)/美白0.6肤区R-B 73.9→67.6去黄+背景零污染(Δ-0.5,双重美白bug修复后)/畸变弯折11.3→7.0px(质心追踪,金标准6.0)。证据:beauty3_ab_v2.png+fisheye_ab_v2.png+beauty3_report_v2.json。旧数据(78.6%/+6.0/-5~-17px)已作废(样张丢失+管线变更)。瘦脸档需真人脸(Vision合成脸检不出)待补测 |
| 5 | **广角自拍边缘拉伸/鼓出** | ✅ 已闭环 | AIAnalyzer fisheyeHint(人脸贴边+宽高比)+ FilterPipeline radialDistortionCorrect(CPU径向位移场) | 数学闭环:预桶形98.34→校正19.13(压回80.5%) |

## 全链路验证(合成输入源,09-26 晚)

**拍照链**:KinetSynthetic 合成源(确定性 30fps)→ 美颜三档(s0.7/w0.6/slim0.8)→ AI修正(自适应:提亮档/暗光增强档随输入切换)→ PNG+JSON 落盘
- 美颜关/开:88.3% 像素变化;AI修正 improved:true(双档证据 pipeline_full_ab.png + off/on JSON)

**录像链**:同源 → 录像美颜 GPU 快速档烧入 → h264 720p30+aac 成片(6.87s/206帧)
- 美颜关/开同帧位:99.8% 像素差异,高频 1.38→5.89(video_beauty_ab.png)
- 实时美颜预览:30fps 整(mainFrameCount 22502→22655/5s,美颜开启状态)

## 歪斜矫正 A/B 实测(09-26 深夜,tilt6_*.png + report JSON)

- 输入:1280×960 棋盘+水平参照线图,PIL 顺时针转 6.5°(模拟拍歪)
- Vision 自然检测:tiltDetected=+6.50° → 自动触发水平校正(6°)
- **蓝线金标准**(线段几何测量,检测器无关):7.30° → 0.00° 精确转正
- 黑边(透明区渲染):0.00%;暗部灰度 40-90 区间保留 48.1%(黑峰零丢失)
- 直方图:黑峰(48-64)39.6%→47.7%(裁背景后占比升,形状不变);白峰被 -0.55EV 从 224-240 移至 192-208 —— 曝光修正主动移动,非色调漂移

### 本轮连根拔起的三个链上 bug(全修)
1. **CIStraightenFilter 旋转角不可靠**(macOS 27):level 图 inputAngle=+6° 实际转出 -11.4°(内部内接矩形适配干扰)→ 弃用,改绕中心 CGAffineTransform(蓝线金标准验证)
2. **CIColorControls contrast 线性域暗部碾压**:contrast=1.1 以线性 0.5 为枢轴,黑格灰度 62 → 纯黑 0(实测 39.6% 像素 clamp 到 0)→ 全部 4 处替换为 CIGammaAdjust 微调
3. **CIToneCurve macOS 27 全黑**(与 CITemperatureAndTint 同族回归):方案二试错实锤,一并弃用

## 实时 fps 验收(09-26 23:00,/status processedFps 滑动窗口)

- 美颜全开(磨皮0.7+美白0.6+锐化0.5):**31fps**(与关闭基线同),GPU video 快速档,美颜不降帧率
- 同帧前后对比图(docs/evidence/):beauty_verify_ab_20260926.png(磨皮+美白+锐化全档)、ai_correct_ab_20260926.png(AI修正4档)

## 09-26 23:00 同帧复验(实拍 1920x1080,与 app 同源管线)

| 档 | 指标 | 值 |
|---|------|-----|
| 磨皮0.7 | 高频能量 hf | 2.06 → **0.92(压噪55%)**,保边缘 |
| 美白0.6 | 肤区 R-B(去黄) | 29.5 → **25.7**,背景不污染 |
| 锐化0.5(全档补锐) | hf | 0.93 → **1.21(Δ+0.29)** |
| AI修正 | 亮度 lum | 86.4 → **113.7(+31.6%)**,applied=[提亮+0.8EV, AI去暖(14), AI美颜, 二次白平衡(10)],色偏 R-B 14.6→**2.1** |

## 遗留(非本轮)

- 真人样张一次性补拍:坐镜头前后 1 组美颜 before/after(管线已验证,只差真脸输入)
- 真人样张一次性补拍:AI修正四档 A/B 同理
