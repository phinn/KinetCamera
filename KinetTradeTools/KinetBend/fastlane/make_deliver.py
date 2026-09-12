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

# ---------------- 四语审核备注(纯离线工具:无账号体系/无 IDFA/无网络) ----------------
REVIEW_NOTES = {
"en-US": """KinetBend is a fully offline conduit bending calculator for electricians.

FOR THE REVIEWER
• No account system, no sign-up, no login — the app is usable immediately after launch.
• Works 100% offline: the app makes no network connections at all.
• No IDFA / no advertising / no tracking / no analytics.
• No user-generated content, no chat, no external links.
• All bend data (30 conduit specs, Benfield multipliers) is bundled inside the app.
• The math is deterministic: same inputs always produce the same marks.

HOW TO TEST IN 30 SECONDS
1. Launch — the Stub-Up screen appears.
2. Pick a conduit size (default 1/2" EMT), enter a height, tap Calculate.
3. The mark distances and a diagram appear. Switch modes via the 5 tabs at the bottom.
4. Everything also works with the device in Airplane Mode.""",
"zh-Hans": """KinetBend 是一个完全离线的电工弯管计算器。

审核说明
• 无账号体系、无注册、无登录——启动即用。
• 100% 离线运行:应用完全不发起任何网络连接。
• 无 IDFA、无广告、无追踪、无数据统计。
• 无用户生成内容、无聊天、无外部链接。
• 全部弯管数据(30 种管规、Benfield 系数)内置在应用内。
• 计算结果确定性:相同输入永远得到相同标记。

30 秒试用路径
1. 启动后即为 90° 直弯(Stub-Up)页面。
2. 选择管材(默认 1/2" EMT),输入高度,点击计算。
3. 显示标记距离与示意图。底部 5 个标签页切换弯型。
4. 飞行模式下全部功能照常可用。""",
"zh-Hant": """KinetBend 是一個完全離線的電工彎管計算器。

審核說明
• 無帳號體系、無註冊、無登入——啟動即用。
• 100% 離線運行:應用完全不發起任何網路連線。
• 無 IDFA、無廣告、無追蹤、無數據統計。
• 無使用者生成內容、無聊天、無外部連結。
• 全部彎管資料(30 種管規、Benfield 係數)內建在應用內。
• 計算結果確定性:相同輸入永遠得到相同標記。

30 秒試用路徑
1. 啟動後即為 90° 直彎(Stub-Up)頁面。
2. 選擇管材(預設 1/2" EMT),輸入高度,點擊計算。
3. 顯示標記距離與示意圖。底部 5 個標籤頁切換彎型。
4. 飛行模式下全部功能照常可用。""",
"ja": """KinetBendは、完全オフラインの電工用配管曲げ計算アプリです。

審査者向け説明
• アカウント登録・ログイン不要 — 起動後すぐに使用できます。
• 100%オフライン動作:アプリは一切ネットワーク通信を行いません。
• IDFA・広告・トラッキング・解析なし。
• ユーザー生成コンテンツ・チャット・外部リンクなし。
• すべての曲げデータ(30規格、Benfield倍率)はアプリ内にバンドル。
• 計算は決定論的:同じ入力には常に同じマークが出ます。

30秒テスト手順
1. 起動するとスタブアップ画面が表示されます。
2. サイズ(デフォルト1/2" EMT)を選び、高さを入力して計算をタップ。
3. マーク距離と図解が表示されます。下部の5つのタブで曲げを切り替え。
4. 機内モードでも全機能が動作します。""",
}

# ---------------- 四语元数据(与 ASC-METADATA.md 同源) ----------------
COPY = {
"en-US": {
  "name": "KinetBend: Bender Calculator",
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
  "name": "彎管計算機 KinetBend",
  "subtitle": "五種彎型 精準標記 1/16英吋",
  "keywords": "彎管,配管,水管,水電,曲管,彎管機,導管,EMT,科技廠,水電工,工地,標記,計算,管徑,施工",
  "promotional_text": "五種彎型一次到位:任意角度 1/sinθ 精算、1/16 英吋分數、公釐切換、工地深色模式,全程離線。",
  "release_notes": "首次發布。",
  "description": """彎管現場最常見的五種彎,KinetBend 一機搞定:下料標記直接算好畫在管上,太陽下也看得清楚。

五種彎型
• 90° 直上(Stub-Up)— 自動扣掉彎管機 take-up,箭頭位置、終點位置直接標出
• Z 形彎(Offset)— 10/22.5/30/45/60° 內建係數,任意角度照樣用 1/sinθ 精算
• 三點馬鞍(Saddle)— 中心標記加兩側標記,22.5/45/22.5 順序一次給齊
• 四點馬鞍 — 中心距離等於障礙物寬度,兩側標記自動算出
• 斜彎(Kick)— 給高度和角度,下料距離直接出

依照工地實況設計
• 內建 30 種管徑規格:EMT/RMC/IMC,1/2 英吋到 4 英吋(NEC 最小彎曲半徑照表內建)
• 收縮量(Shrink)依 Benfield 表逐角度計算
• 每個距離同時顯示 1/16 英吋分數、小數英吋、公釐三種讀法
• 每筆結果都有圖解:標記位置直接畫在管路上
• 100% 離線。不用帳號、不連網路、不收集任何資料。

工地深色主題
高對比、按鈕大,戴著手套、頂著大太陽都好按。

不論是天花板配 EMT,還是進盤體拉鋼管,KinetBend 幫你一次標記到位。""",
},
"ja": {
  "name": "配管曲げ計算 KinetBend",
  "subtitle": "5つの曲げ 正確マーク 1/16",
  "keywords": "配管,曲げ,ベンダー,電気工事士,電工,オフセット,サドル,スタブアップ,キック,EMT,鋼管,マーキング,計算,工事,屋内配線",
  "promotional_text": "現場の5つの基本曲げをこれ1本で。任意角の1/sinθ計算、1/16インチ分数、ミリ表示切替、完全オフライン。",
  "release_notes": "初回リリース。",
  "description": """電気工事の現場で使う5つの基本曲げを、KinetBend 1本でカバー。マーク位置まで自動計算し、配管の図の上に直接描き込みます。

5つの曲げに対応
• 90°スタブアップ — ベンダーのテイクアップを自動控除。矢印位置と終点をマーク
• オフセット — 10/22.5/30/45/60°の標準倍率に加え、任意角度は1/sinθで正確に計算
• 3点サドル — 中心マーク+両側マーク、22.5/45/22.5の順序をまとめて表示
• 4点サドル — 中心間隔=障害物幅で、両側マークを自動計算
• キック — 高さと角度からマークまでの距離を直接算出

現場目線の設計
• 30規格を内蔵:EMT/RMC/IMC、1/2〜4インチ(NEC Table 2の最小曲げ半径込み)
• シュリンクはBenfield表に沿って角度ごとに計算
• すべての距離を1/16インチ分数・小数インチ・ミリの3表記で表示
• 結果には図解付き:マーク位置を配管図の上に直接描画
• 100%オフライン。アカウント登録不要、通信なし、データ収集ゼロ。

現場向けダークテーマ
高コントラスト・大きなタップ領域 — 手袋をしたまま、強い日差しの下でも操作しやすい。

天井配線のEMTでも、分電盤への鋼管工事でも、KinetBendが一度のマーキングで仕上げます。""",
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
        # 审核备注(review_information/notes.txt → ASC "App Review Information" notes)
        "review_information/notes.txt": REVIEW_NOTES[loc],
    }
    for fn, content in files.items():
        p = os.path.join(ld, fn)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
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

# 年龄分级(deliver app_rating_config_path,snake_case 键;内容类=NONE,布尔类=false)
AGE_RATING = {
    "alcohol_tobacco_or_drug_use_or_references": "NONE",
    "contests": "NONE",
    "gambling": False,
    "gambling_simulated": "NONE",
    "guns_or_other_weapons": "NONE",
    "health_or_wellness_topics": False,
    "horror_or_fear_themes": "NONE",
    "loot_box": False,
    "mature_or_suggestive_themes": "NONE",
    "medical_or_treatment_information": "NONE",
    "messaging_and_chat": False,
    "profanity_or_crude_humor": "NONE",
    "sexual_content_graphic_and_nudity": "NONE",
    "sexual_content_or_nudity": "NONE",
    "social_media": False,
    "social_media_age_restricted": False,
    "unrestricted_web_access": False,
    "user_generated_content": False,
    "violence_cartoon_or_fantasy": "NONE",
    "violence_realistic": "NONE",
    "violence_realistic_prolonged_graphic_or_sadistic": "NONE",
    "advertising": False,
    "age_assurance": False,
    "parental_controls": False,
    "korea_age_rating_override": "NONE",
    "kids_age_band": "NONE",
}
import json
with open(os.path.join(FL, "age_rating.json"), "w") as f:
    json.dump(AGE_RATING, f, indent=2)

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
  desc "Push metadata + screenshots + binary, then SUBMIT FOR REVIEW"
  lane :release do
    deliver(
      api_key_path: "/tmp/asc_key.json",
      ipa: "/tmp/KinetBend-export/KinetBend.ipa",
      skip_binary_upload: false,
      skip_metadata: false,
      skip_screenshots: false,
      force: true,                    # 跳过 HTML 报告人工确认,全自动
      submit_for_review: true,        # 直接过审提交,目标是上架
      automatic_release: false,       # 手动放行(Apple 批过后人工点发布,或改 true)
      app_rating_config_path: "fastlane/age_rating.json",
      run_precheck_before_submit: true,
      precheck_default_rule_level: "warn",
      submission_information: {
        export_compliance_uses_encryption: false,   # 纯离线,无非豁免加密(HTTPS 都不用)
        content_rights_contains_third_party_content: false,
        add_id_info_uses_idfa: false
      }
    )
  end

  desc "Only metadata + screenshots (no binary, no submit)"
  lane :meta do
    deliver(
      api_key_path: "/tmp/asc_key.json",
      skip_binary_upload: true,
      force: true,
      app_rating_config_path: "fastlane/age_rating.json",
      submission_information: {
        content_rights_contains_third_party_content: false,
        add_id_info_uses_idfa: false
      },
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
  email_address: "phinn@outlook.com",
  phone_number: "+86 138 0000 0000"
)
submission_information({
  export_compliance_uses_encryption: false,
  content_rights_contains_third_party_content: false,
  add_id_info_uses_idfa: false
})
''')
print("Fastfile + Deliverfile written")
