# iOS 模拟器 E2E 验收(2026-09-27)

## 环境边界(如实标注)
- iPhone 17 Pro Sim(2CFFB0CA),iOS 26.x;模拟器**无摄像头/无麦克风硬件**,相机栈全空(devices=[], cameraAuthStatus=0)
- 本轮验的是:**无源态健壮性 + AutomationServer 协议正确性 + 状态机**,画面链路已在 Mac+iPhone 插线轮闭环(见 E2E_EVIDENCE_20260926)
- Debug-iphonesimulator 编译过;模拟器 UI 截图 docs/evidence/simulator_20260927/

## 抓到并修掉的 4 个真 Bug(全部由模拟器无源态暴露)
1. **reply() 吞 status 参数**:send() 硬编码 "HTTP/1.1 200 OK",所有 400/404/503 实际都回 200。
   客户端按 HTTP 状态码做错误处理的调用方全被误导。修:status 透传。
2. **/switch 死设备假成功**:`/switch?id=nope` 回 `{"ok":true,"active":"nope"}`,
   实际 DevicePolicy.canSwitch 已拒绝、什么都没切,还把假 id 写进 active 字段。
   修:先查 live 列表,死 id 回 404;ok 回包报切换后的实际主摄而非回显请求参数。
3. **/pip 死设备假成功**:同上,回 404 + requested 回显。
4. **/zoom /exposure 回显未 clamp 值**:`/zoom?f=99` 回 `zoom:99.0`(实际已 clamp 到 1.0)、
   `/exposure?ev=5` 回 5(实际 clamp ±2)。回包一律报收敛后实际值。

## 状态机验证(无源态)
- `/awaitDevice?id=x&timeout=1` → 立即回 waiting(设计如此,后台轮询),1s 后
  `/deviceWait` → `degraded:"设备 x 等待超时(1s),已降级;上线将自动恢复"` ✓
- 全路由无源轰炸(capture/record/retro/night/steady/hdr/focus/zoom/exposure/beauty/pip/frame/awaitDevice/switch):
  进程零崩溃,错路径全回正确错误码(503 no frame / 404 not found / 400 need id)✓
- beauty?s=-1 → clamp 0.0 ✓(参数 clamp 在 server 层做,回包=收敛值)

## 单测回归
- macOS 全套 26/26 passed(DevicePolicy 9 + DeviceWaitState 5 + TimebasePolicy 7 + Logic 5)
- macOS Release 同步编译过(修法跨平台无踩坏)

## 勘误记录
- launch 报 code=4 的根因:**bundle id 是 com.kinet.KinetCamera.iOS**(带 .iOS 后缀),
  `simctl launch com.kinet.KinetCamera` 必失败。真机部署脚本 deploy_ios.sh 用的是正确 id。
