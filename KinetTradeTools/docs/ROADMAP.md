# KinetTradeTools — 蓝领执业工具 App 系列规划

> 定位:像 QuickBend($6.99)、10bii($5.99–6.99)、MilGPS($12.99)那样,
> **一个职业一款付费 App**,纯端侧计算、零服务器成本、差评少退款低、可无限系列化。
> 对标 Flipline 出 Papa's 系列的滚雪球模式,但卖的是"执业刚需计算器"而非游戏。

---

## 0. 商业模型(一句话版)

| 维度 | 策略 |
|---|---|
| 收费 | iOS 直接买断 $5.99–9.99(随功能涨),Android 做包装后跟上 |
| 成本 | 近零:无后端、无 API 费、无审核灰色地带(计算器类天然 5.1.1 安全) |
| 复用 | 共享 `KitCore` 计算引擎 + UI 模板,第二款边际成本 ≈ 20% |
| 天花板 | 单职业受众小,但**职业数量 × 精准付费意愿**=长尾利润;系列品牌 > 单品爆款 |
| 护城河 | 工程规范数据(NEC/CDA/EN 标准)整理成人机交互,抄代码容易、抄规范数据难 |

**定价锚点**:QuickBend 6.99 / 10bii 5.99 / MilGPS 12.99 → 首品 $6.99,系列成熟后推 $9.99–12.99 的"Pro"档。

---

## 1. 市场切入选择

### 选品标准(硬性)
1. **英语市场有执业规范**——有 NEC / CDA / OSHA / AWS 这类"官方数字"可抄,数据壁垒自然形成;
2. **app 稀缺**:现有 app 界面停留在 2015 年,无 SwiftUI 重做;
3. **计算高频**:工地现场每天用,不装美观软件,只装解决问题的;
4. **回国套壳成本低**:换算成国内规范(GB/行标)数字即可,换皮不改架构。

### 候选职业矩阵(按"付费意愿 × 竞争度 × 复用度"打分)

| 职业 | 英语市场竞品 | 规范数据源 | 付费意愿 | 竞争 | 复用度 | 排序 |
|---|---|---|---|---|---|---|
| **电工(弯管)** | QuickBend 等 | NEC Ch.9 表 + Benfield/TECKWT 算法 | ★★★★★ | 中 | ★★★(几何/三角复用) | **P0 首发品** |
| 电工(线管填充/压降) | Southwire 等免费 | NEC Ch.9 Table 1/5/5A | ★★★★ | 中低 | ★★★★★ 与弯管同用户群 | P1 并入 KinetBend v2 |
| 焊工 | 少且烂 | AWS D1.1 / WPS 参数 | ★★★★ | 低 | ★★★ | P1 第二款 |
| 水管工(管径/坡度) | 少 | IPC/UPC | ★★★ | 低 | ★★★★ | P2 |
| 木工(楼梯/屋面) | 少 | IRC R311/R802 | ★★★ | 低 | ★★★★★(纯三角复用) | P2 |
| 暖通(Ductulator) | 老旧 | ACCA Manual D/J | ★★★★ | 低 | ★★ | P2 |
| 航空 | MilGPS $12.99 | FAA | ★★★★ | 高(MilGPS 垄断) | ★ | 不碰 |

### 首品:KinetBend(电工弯管)

选它不是因为最爱,是因为:
- QuickBend 证明了这个价位有真人付费(评价 4.8+,用户全是持证电工);
- 弯管是**考点+现场双重刚需**: apprentice 考试要背 offset/saddle 公式,老电工现场要快查;
- 几何内核(offset / saddle / kick / three-point saddle 全是三角函数)
  与后续木工楼梯、水管坡度**同一套数学底座**,KitCore 一次写完三处用;
- 中文市场对应做「电工速查:弯管+载流量+压降」国内版,GB 50054 / JB-T 弯管半径规范直接换数字。

---

## 2. 系列路线图

### Phase 0 — KitCore 共享层(1 周,与 KinetBend 开发并行)
- [ ] Swift Package `KitCore`:
  - `AngleMath`(三角/角度制切换 deg/rad + 分数英寸处理)
  - `BendMath`(offset/saddle/kick/3pt saddle/90° stub-up,含 NEC 最小弯半径表)
  - `UnitKit`(inch 分数↔小数↔mm,1/16" 精度,工地通用)
  - `PipeMath`(P1 水管工预留)/ `StairMath`(P2 木工预留)
  - 全部纯函数 + 精确到 1/16" 的分数取整规则
- [ ] 单元测试:每条公式对照 NEC Ch.9 表 + Benfield 手算样例,零容忍
- [ ] 跨 app 复用形式:local Swift Package,系列第 N 款直接 path 引用

### Phase 1 — KinetBend v1.0(2 周)
**目标:上架拿第一笔收入,验证"付费工具 app"模型。**

功能(对标 QuickBend 全集):
- [ ] **90° Stub-Up**:输入抬高高度+管径→弯位标记(mark distances)
  - 缩减系数(shrink):1/2"=5/16, 3/4"=3/8, 1"=7/16, 1¼"=9/16 …按 NEC 表
  - 支持可调弯管机半径( Benfield / Ideal / Greenlee 各牌差异)
  - 按管径选 shrink 系数与 min radius 表
- [ ] **Offset Bend**:角度 10/22.5/30/45/60,输入 offset 高度 → Mark1/Mark2 间距
  - 常数表:10°=6, 22.5°=2.6, 30°=2, 45°=1.414, 60°=1.155
  - 显示 shrink 量(现场少走回头路的核心价值)
  - 45° 弯角可调(非标角度任意输入)
  - 任意角度支持(不只 6 档标准角)
  - 输出:mark1/mark2 间距 + shrink + 总管长消耗
- [ ] **Saddle(3-point / 4-point)**:跨障碍物宽度+高度 → 中心标+两侧标
- [ ] **Kick(带角度单弯)**:kick 高度+角度 → 弯位标记
-五种弯型 × 支持的管径(EMT 1/2"–4"、RMC、IMC、PVC-coated)
- [ ] 单位切换 inch fraction / decimal / mm
- [ ] 暗色主题(工地强光/弱光两用)+ 大按钮(戴手套可点)
- [ ] 一屏结果 + 图示(SwiftUI Canvas 画弯管示意,标注 mark 位置)
- [ ] 免费 Pro 升级内购?否——**直接买断 $6.99**,学 QuickBend;以后加功能升价不加内购

技术:
- SwiftUI + iOS 16+,单 target;
- KitCore SPM 本地包(与 Phase 0 同一份);
- 本地化:en(源)+ zh-Hans(国内版素材,先不做完整 21 语,这个品类 en+zh 够了);
- 复用 KinetDriverStudy 的 xcodegen + Fastlane 管线,`fastlane deliver` 一条龙。

### Phase 2 — KinetBend v1.1(v1 上架后 2 周内)
- [ ] **Conduit Fill 计算器**(NEC Ch.9 Table 1/5/5A):线管填充率 40% 规则
- [ ] **Voltage Drop**:单相/三相,长度/负载/管材
- [ ] **Ampacity 表查询**(NEC 310.16,含温度/导体修正)
- [ ] 收录 NEC 数据表为本地 JSON(与 KinetDriverStudy 题库同模式,`Resources/nec/*.json`)
- [ ] 中文市场版「电工速查」:GB 50054 载流量表 + 国标弯管半径,同一代码库两个 product(或做 Country 参数,学 KinetDriverStudy `Country.supported` 模式)

### Phase 3 — KinetWeld(焊工,4 周)
- [ ] WPS 参数速查:电流/电压/送丝速度/角焊缝尺寸,按 AWS D1.1
- [ ] 焊材用量计算(角焊缝体积→焊条/焊丝重量→成本)
- [ ] 预热/层间温度查询(按母材牌号+厚度)
- [ ] fillet weld 强度验算
- [ ] 数据源:AWS D1.1 表 5.x/6.x + TWI 手册,JSON 化同上

### Phase 4 — 量产复用(每个 2 周)
按矩阵排序逐个复制:
- KinetPipe(水管工:管径/坡度/水锤)、KinetStair(木工:楼梯+屋面坡度)、KinetHVAC(风管计算尺)。
- 每款上架前跑同一份 checklist(KinetDriverStudy docs/RELEASE.md 已验证过的流程)。

---

## 3. 复用 KinetDriverStudy 已验证的基建

| 已验证资产 | 在本系列怎么用 |
|---|---|
| xcodegen + project.yml | 直接复制管线,改 bundle id/bnadle 版本 |
| folder reference 进 bundle(JSON 资源) | NEC/AWS 规范数据 JSON 同模式 |
| SQLite3 C API StudyStore | 不需要——本系列无用户数据,Keychain/UserDefaults 足够 |
| Fastlane deliver 上架管线 | 同一套 lanes,改 metadata |
| docs/RELEASE.md 上架 checklist | 每款复制一份改数字 |
| 「数据 JSON 化 + 校验脚本」模式 | `scripts/verify_nec.py` 校验 NEC 表完整性 |
| MAS pkg 签名常量(M92UKS6NA2) | 后续做 macOS 版直接用 |

---

## 4. 上架 checklist(每款必跑)

1. xcodegen generate → xcodebuild 编译零警告
2. 模拟器冒烟:每计算器功能过一遍(输入→结果→图示)
3. 截图:6.7" + 6.1" + iPad,暗色主题(与 QuickBend 的亮色区分度)
4. App Store Connect 建档:
   - 分类:Utilities / Reference;价格 Tier 4($6.99 可调)
   - 关键词:conduit bending, electrician, NEC, offset, saddle, stub-up, wire fill
   - 隐私:不收集任何数据(纯本地计算,PrivacyInfo 标 "No Data Collected")
5. 审核风险自查:计算器类无 5.1.1/2.1 风险;不要在截图文案提 "NEC®" 商标(写 "per NFPA 70 tables" 描述性引用)
6. 定价:首发 $6.99;积累 20+ 评价后涨 $9.99(学 MilGPS 的胆量)

---

## 5. 风险与对策

| 风险 | 对策 |
|---|---|
| QuickBend 评价基数大,新 app 排不过它 | 差异化:SwiftUI 图示 + 任意角度 + 暗色 + 中文市场版(QuickBend 全英文无中文) |
| NEC 规范 3 年一换(2023/2026) | JSON 数据层与代码分离,更新表=发数据版本,不动代码 |
| 销量长尾慢热 | 预期管理:这是"组合拳"生意,单款月 $200–800 就算及格,系列 5 款后月 $2k+ |
| 工地用户不写评价 | 不强求,靠精准关键词 natural search;品类搜索词竞争极低 |
| 商标风险 | 描述性引用规范("based on NFPA 70 tables"),logo/名称避开 NEC/QuickBend 字样 |

---

## 6. 时间线总览

```
W1-W2   KitCore SPM + 单测(弯管数学)
W3      KinetBend v1.0 五种弯型 + 图示
W4      上架流水线(截图/文案/ASC 建档)→ 提审
W5-W6   v1.1(Fill/VD/Ampacity)+ 中文市场版准备
W7+     KinetWeld 开工,系列滚雪球
```

**成功指标**:KinetBend 上架 30 天内 10+ 付费下载(验证模型);90 天系列 2 款在架、合计月收入 $500+。
