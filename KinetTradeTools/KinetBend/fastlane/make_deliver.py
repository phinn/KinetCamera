#!/usr/bin/env python3
"""生成 fastlane deliver 工作区:metadata(四语)+ screenshots(四语)+ Fastfile
真源就是这些文件,ASC-METADATA.md 只是人读的快照。用法: python3 make_deliver.py
"""
import os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # KinetBend/
FL = os.path.join(ROOT, 'fastlane')
META = os.path.join(FL, 'metadata')
SHOTS = os.path.join(FL, 'screenshots')
SHOTS_SRC = os.path.join(ROOT, 'AppStore', 'Shots')

# ---------------- 四语元数据(与 ASC-METADATA.md 同源) ----------------
COPY = {
"en-US": {
  "name": "KinetBend — Conduit Bender",
  "subtitle": "5 bends, pro marks, 1/16\"",
  "keywords": "conduit,bender,electrician,bend,offset,saddle,stub up,kick,90,emt,rmc,imc,trade,math,calculator",
  "promotional_text": "All five essential conduit bends with exact mark distances — 1/16\" fractions, mm switch, works offline on the job site.",
  "release_notes": "Initial release.",
  "description": """KinetBend is the conduit bending calculator electricians keep on the job site. Five essential bends, exact mark distances, and a dark high-contrast UI you can read under a work light.

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

Whether you're running EMT in a commercial ceiling or rigid steel into a panel, KinetBend gets the marks right the first time.""",
},
"zh-Hans": {
  "name": "弯管计算器 KinetBend",
  "subtitle": "五种弯型 精确标记 1/16英寸",
  "keywords": "弯管,电工,线管,导管,90度直弯,Z形弯,马鞍弯,踢弯,电气,桥架,EMT,钢管,弯管器,标记,计算",
  "promotional_text": "五种必备弯型全计算:任意角度 1/sinθ 精确系数、1/16 英寸分数、毫米切换、工地暗色模式,全程离线。",
  "release_notes": "首发版本。",
  "description": """KinetBend 是电工留在工地上的弯管计算器。五种必备弯型、精确的下料标记,配合强光下依然清晰的暗色高对比界面。

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

无论是天花上跑 EMT,还是接盘柜进钢管,KinetBend 让你一次下料到位。""",
},
"zh-Hant": {
  "name": "彎管計算器 KinetBend",
  "subtitle": "五種彎型 精確標記 1/16英吋",
  "keywords": "彎管,電工,線管,導管,90度直彎,Z形彎,馬鞍彎,踢彎,電氣,EMT,鋼管,彎管器,標記,計算,水電",
  "promotional_text": "五種必備彎型全計算:任意角度 1/sinθ 精確係數、1/16 英吋分數、公釐切換、工地暗色模式,全程離線。",
  "release_notes": "首發版本。",
  "description": """KinetBend 是電工留在工地上的彎管計算器。五種必備彎型、精確的下料標記,配合強光下依然清晰的暗色高對比介面。

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

無論是天花上跑 EMT,還是接盤櫃進鋼管,KinetBend 讓你一次下料到位。""",
},
"ja": {
  "name": "配管曲げ計算 KinetBend",
  "subtitle": "5つの曲げ 精確マーク 1/16\"",
  "keywords": "配管,曲げ,ベンダー,電工,電気,オフセット,サドル,スタブアップ,キック,EMT,鋼管,マーク,計算,工事,角形",
  "promotional_text": "現場で使う5つの基本曲げを完全計算。任意角の1/sinθ係数、1/16インチ分数、ミリ表示切替、完全オフライン動作。",
  "release_notes": "初回リリース。",
  "description": """KinetBendは、電気工事士が現場に置いておける配管曲げ計算アプリです。5つの基本曲げ、精確なマーク位置、作業灯の下でも見やすいダークで高コントラストなUI。

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

天井配線のEMTでも、分電盤への鋼管でも、KinetBendが一発でマークを出します。""",
},
}

# 关键字数校验(ASC ≤100)
for loc, d in COPY.items():
    kw = d["keywords"]
    assert len(kw) <= 100, f"{loc} keywords {len(kw)} > 100"
    assert len(d["name"]) <= 30, f"{loc} name {len(d['name'])} > 30"
    assert len(d["subtitle"]) <= 30, f"{loc} subtitle {len(d['subtitle'])} > 30"
    assert len(d["promotional_text"]) <= 170, f"{loc} promo {len(d['promotional_text'])} > 170"

for loc, d in COPY.items():
    ld = os.path.join(META, loc)
    os.makedirs(ld, exist_ok=True)
    files = {
        "name.txt": d["name"], "subtitle.txt": d["subtitle"], "keywords.txt": d["keywords"],
        "promotional_text.txt": d["promotional_text"], "release_notes.txt": d["release_notes"],
        "description.txt": d["description"],
    }
    for fn, content in files.items():
        with open(os.path.join(ld, fn), "w", encoding="utf-8") as f:
            f.write(content + "\n")

# 全 locale 共享项
with open(os.path.join(META, "copyright.txt"), "w") as f:
    f.write("© 2026 JUNJIE SHEN\n")
with open(os.path.join(META, "primary_category.txt"), "w") as f:
    f.write("utilities\n")
with open(os.path.join(META, "secondary_category.txt"), "w") as f:
    f.write("reference\n")
with open(os.path.join(META, "privacy_url.txt"), "w") as f:
    f.write("https://phinn.github.io/KinetAppPortal/kinetbend-privacy.html\n")
with open(os.path.join(META, "support_url.txt"), "w") as f:
    f.write("https://phinn.github.io/KinetAppPortal/kinetbend-support.html\n")

# ---------------- 截图分语言拷贝 ----------------
LANGDIR = {"en-US": "en-US", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "ja": "ja"}
n = 0
for src, loc in LANGDIR.items():
    dst = os.path.join(SHOTS, loc)
    os.makedirs(dst, exist_ok=True)
for f in sorted(os.listdir(SHOTS_SRC)):
    if not f.endswith(".png"):
        continue
    # 命名两种:1-stubup-en-US.png / 1-stubup-zh-Hans.png → 取最后一个 '-' 之后的语言段
    tail = f[:-4].rsplit("-", 1)[1]          # "US" or "Hans" — 不够,直接匹配已知后缀
    if f.endswith("-en-US.png"): loc = "en-US"
    elif f.endswith("-zh-Hans.png"): loc = "zh-Hans"
    elif f.endswith("-zh-Hant.png"): loc = "zh-Hant"
    elif f.endswith("-ja.png"): loc = "ja"
    else:
        print(f"skip {f}")
        continue
    dst = os.path.join(SHOTS, LANGDIR[loc], f)
    shutil.copy2(os.path.join(SHOTS_SRC, f), dst)
    n += 1
print(f"metadata 4 locales + {n} screenshots staged")

# ---------------- Fastfile + Deliverfile ----------------
os.makedirs(FL, exist_ok=True)
with open(os.path.join(FL, "Fastfile"), "w") as f:
    f.write('''default_platform(:ios)

platform :ios do
  desc "Push metadata + screenshots + binary to App Store Connect"
  lane :release do
    deliver(
      api_key_path: "/tmp/asc_key.json",
      ipa: "/tmp/KinetBend-export/KinetBend.ipa",
      skip_binary_upload: false,
      skip_metadata: false,
      skip_screenshots: false,
      force: true,               # 跳过 HTML 报告人工确认,全自动
      run_precheck_before_submit: true,
      submit_for_review: false   # 元数据/截图/构建就位后,提交审核由 ASC 后台一键(或改 true)
    )
  end

  desc "Only metadata + screenshots (no binary)"
  lane :meta do
    deliver(
      api_key_path: "/tmp/asc_key.json",
      skip_binary_upload: true,
      force: true,
      submit_for_review: false
    )
  end
end
''')
with open(os.path.join(FL, "Deliverfile"), "w") as f:
    f.write('''app_identifier "com.kinetai.kinetbend"
username "phinn@outlook.com"
team_id "M92UKS6NA2"
app_review_information(
  first_name: "JUNJIE",
  last_name: "SHEN",
  email_address: "phinn@outlook.com"
)
submission_information({ add_id_info_uses_idfa: false })
''')
print("Fastfile + Deliverfile written")
