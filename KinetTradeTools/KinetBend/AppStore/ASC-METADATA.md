# KinetBend ASC 提审包(v1.0.0 build 1)

> App Store Connect 元数据四语齐套 + 截图规范 + 提审 checklist
> 截图源:`AppStore/Shots/`(20 张,1320×2868 6.9",Display P3 内嵌,由 `scripts/shots_pipeline.py` 产出)
> IPA:`/tmp/KinetBend-export/KinetBend.ipa`(get-task-allow=false,codesign verify OK,Team M92UKS6NA2)

## 一、App 信息

| 项 | 值 |
|---|---|
| Bundle ID | com.kinetai.kinetbend |
| SKU | KINETBEND001 |
| 主语言 | en-US |
| 主分类 | Utilities |
| 副分类 | Reference |
| 价格 | $6.99(档位7) |
| 内购 | 无 |
| 年龄分级 | 4+(无任何不良内容) |
| 设备 | iPhone only(TARGETED_DEVICE_FAMILY=1,不交 iPad 截图) |
| 版权 | © 2026 JUNJIE SHEN |
| 隐私 | 不收集任何数据(Privacy Nutrition Label 全选 No) |
| 加密 | export compliance:只用了标准加密(HTTPS)→ 选 "standard encryption" 豁免声明 |

## 二、各语言元数据(30 字符/子标题,100 字符内关键词,4000 字描述)

### en-US
- **Name**(30): `KinetBend: Bender Calculator`
- **Subtitle**(30): `5 bends, pro marks, 1/16"`
- **Keywords**(100): `conduit,bender,electrician,bend,offset,saddle,stub up,kick,90,emt,rmc,imc,trade,math,calculator`
- **Promo text**(170): `All five essential conduit bends with exact mark distances — 1/16" fractions, mm switch, works offline on the job site.`
- **Description**:
```
KinetBend is the conduit bending calculator electricians keep on the job site. Five essential bends, exact mark distances, and a dark high-contrast UI you can read under a work light.

ALL FIVE BENDS
• 90° Stub-Up — take-up deduction, mark-to-arrow and end marks
• Offset — Benfield multipliers for 10/22.5/30/45/60° plus ANY angle with exact 1/sinθ math
• 3-Point Saddle — center mark + side marks, 22.5/45/22.5 sequence
• 4-Point Saddle — rise spacing = obstacle width, side marks auto-computed
• Kick — kick height and angle to mark distance

BUILT FOR REAL WORK
• 30 conduit specs: EMT, RMC, IMC from 1/2" to 4" (NEC Table 2 minimum radii built in)
• Shrink values follow the Benfield tables
• Every distance shown as 1/16" fractions, decimal inches, or millimeters
• Diagram on every result: the mark locations drawn right on the conduit run
• 100% offline. No account, no network, no data collection.

DARK JOBSITE THEME
High-contrast surfaces, large touch targets — designed to work with gloves on and sun on the screen.

Whether you're running EMT in a commercial ceiling or rigid steel into a panel, KinetBend gets the marks right the first time.
```
- **What's New**: `Initial release.`

### zh-Hans(简体中文)
- **Name**: `KinetBend 电工弯管计算器`
- **Subtitle**: `五种弯型 精确标记 1/16英寸`
- **Keywords**: `弯管,电工,线管,导管,90度直弯,Z形弯,马鞍弯,踢弯,电气,桥架,EMT,钢管,弯管器,标记,计算`
- **Promo text**: `五种必备弯型全计算:任意角度 1/sinθ 精确系数、1/16 英寸分数、毫米切换、工地暗色模式,全程离线。`
- **Description**:
```
KinetBend 是电工留在工地上的弯管计算器。五种必备弯型、精确的下料标记,配合强光下依然清晰的暗色高对比界面。

五种弯型全覆盖
• 90° 直弯(Stub-Up)— 自动扣减弯管器 take-up,标出箭头位与终点位
• Z 形弯 — 10/22.5/30/45/60° 标准系数,更支持任意角度的精确 1/sinθ 计算
• 三点马鞍弯 — 中心标 + 两侧标,22.5/45/22.5 标准顺序
• 四点马鞍弯 — 中心间距=障碍物宽度,两侧标自动算出
• 踢弯 — 由踢弯高度与角度直接给出下料距离

为真实工地而生
• 内置 30 种管规:EMT/RMC/IMC,1/2 英寸到 4 英寸(含 NEC 规范最小弯曲半径)
• 收缩量按 Benfield 表逐角度计算
• 每个距离同时给出 1/16 英寸分数、小数英寸、毫米三种读法
• 每个结果都附图示:标记位置直接画在管线上
• 100% 离线。无账号、无网络、零数据收集。

工地暗色主题
高对比、大按钮,戴手套、顶着太阳也能操作。

无论是天花上跑 EMT,还是接盘柜进钢管,KinetBend 让你一次下料到位。
```

### zh-Hant(繁体中文)
- **Name**: `KinetBend 電工彎管計算器`
- **Subtitle**: `五種彎型 精確標記 1/16英吋`
- **Keywords**: `彎管,電工,線管,導管,90度直彎,Z形彎,馬鞍彎,踢彎,電氣,EMT,鋼管,彎管器,標記,計算,水電`
- **Promo text**: `五種必備彎型全計算:任意角度 1/sinθ 精確係數、1/16 英吋分數、公釐切換、工地暗色模式,全程離線。`
- **Description**: (与简中同结构,繁化:線管/彎管器/公釐/盤櫃 等词系已按台灣電工用語)
```
KinetBend 是電工留在工地上的彎管計算器。五種必備彎型、精確的下料標記,配合強光下依然清晰的暗色高對比介面。

五種彎型全覆蓋
• 90° 直彎(Stub-Up)— 自動扣減彎管器 take-up,標出箭頭位與終點位
• Z 形彎 — 10/22.5/30/45/60° 標準係數,更支援任意角度的精確 1/sinθ 計算
• 三點馬鞍彎 — 中心標 + 兩側標,22.5/45/22.5 標準順序
• 四點馬鞍彎 — 中心間距=障礙物寬度,兩側標自動算出
• 踢彎 — 由踢彎高度與角度直接給出下料距離

為真實工地而生
• 內建 30 種管規:EMT/RMC/IMC,1/2 英吋到 4 英吋(含 NEC 規範最小彎曲半徑)
• 收縮量按 Benfield 表逐角度計算
• 每個距離同時給出 1/16 英吋分數、小數英吋、公釐三種讀法
• 每個結果都附圖示:標記位置直接畫在管線上
• 100% 離線。無帳號、無網路、零資料收集。

工地暗色主題
高對比、大按鈕,戴手套、頂著太陽也能操作。

無論是天花上跑 EMT,還是接盤櫃進鋼管,KinetBend 讓你一次下料到位。
```

### ja(日本語)
- **Name**: `KinetBend 配管曲げ計算`
- **Subtitle**: `5つの曲げ 精確マーク 1/16"`
- **Keywords**: `配管,曲げ,ベンダー,電工,電気,オフセット,サドル,スタブアップ,キック,EMT,鋼管,マーク,計算,工事,角形`
- **Promo text**: `現場で使う5つの基本曲げを完全計算。任意角の1/sinθ係数、1/16インチ分数、ミリ表示切替、完全オフライン動作。`
- **Description**:
```
KinetBendは、電気工事士が現場に置いておける配管曲げ計算アプリです。5つの基本曲げ、精確なマーク位置、作業灯の下でも見やすいダークで高コントラストなUI。

5つの曲げをすべてカバー
• 90°スタブアップ — ベンダーのテイクアップ控除を自動計算、矢印位置と終点をマーク
• オフセット — 10/22.5/30/45/60°の標準倍率に加え、任意角度を1/sinθで精確計算
• 3点サドル — 中心マーク+両側マーク、22.5/45/22.5の順序
• 4点サドル — 中心間=障害物幅、両側マークを自動計算
• キック — 高さと角度からマーク距離を直接算出

現場のために作られた設計
• 30規格を内蔵:EMT/RMC/IMC、1/2〜4インチ(NEC Table 2の最小曲げ半径込み)
• シュリンクはBenfield表に従い角度ごとに計算
• すべての距離を1/16インチ分数・小数インチ・ミリの3表記で表示
• 結果には図解付き:マーク位置を配管に直接描画
• 100%オフライン。アカウント不要、通信なし、データ収集ゼロ。

現場向けダークテーマ
高コントラスト、大きなタップ対象 — 手袋をしたまま、太陽の下でも操作できます。

天井配線のEMTでも、分電盤への鋼管でも、KinetBendが一発でマークを出します。
```

## 三、截图(已产出,直接上传)

- 位置:`AppStore/Shots/`
- 规格:1320×2868(6.9" iPhone 16 Pro Max/17 Pro Max 档,ASC 自动缩放兼容全部 iPhone)
- 色彩:Display P3 ICC 已内嵌(`sips -g space` 校验为 `P3`)
- 命名:`{1..5}-{mode}-{lang}.png`,每语言 5 张按序上传
- 提示:ASC 每语言槽位放同顺序 5 张(stubup → offset → saddle3 → saddle4 → kick)

## 四、提审 checklist(一次过)

- [x] App Icon 1024 无 alpha(Assets single-size,构建已验证 CFBundleIcons)
- [x] CFBundleDisplayName = KinetBend(Info.plist,非仅 CFBundleName)
- [x] 四语 lproj 全打进包(en/zh-Hans/zh-Hant/ja,已 ls 验证)
- [x] get-task-allow=false(app-store-connect 导出后 codesign 验证)
- [x] codesign --verify --strict 通过
- [x] TARGETED_DEVICE_FAMILY=1(iPhone only,免 iPad 截图)
- [x] 无占位文案(全部五页有真实数据;StoreKit 不涉及,无 IAP 死文案问题)
- [x] Privacy Policy URL: https://phinn.github.io/KinetAppPortal/kinetbend-privacy.html (已上线 200,四语切换)
- [x] Support URL: https://phinn.github.io/KinetAppPortal/kinetbend-support.html (已上线 200,含 FAQ + 联系邮箱)
- [ ] ASC 后台:App Privacy 全 No;Export compliance 选 standard encryption 豁免
- [ ] 提审备注(Review Notes):en 写一句 "A conduit bending calculator. No account needed. All features available offline."(工具类零数据,基本秒审)

## 五、复查记录(2026-09-12)

1. **shrink 建模修正**:shrink 是角度函数(Benfield: 22.5°=3/16, 30°=1/4, 45°=3/8,任意角 tan(θ/2)),与管径无关。已从 benddata.json 30 项里删除 shrinkPerInch 字段,收编进 `BendAngle.shrinkPerInch(angleDegrees:)`,verify_benddata.py 增加禁止字段门禁。
2. **UI 冒烟**:XCUITest 8 例全绿(五计算器黄金值 + 三语断言),截图矩阵 20 张(5 模式 × 4 语)。
3. **导出链路**:archive → app-store-connect export → IPA 内 get-task-allow=false 全验证。
