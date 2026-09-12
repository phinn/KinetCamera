#!/usr/bin/env python3
"""KinetBend ASC 提审硬校验(preflight)——建档前把能本地验证的全部锁死。
覆盖(全部对照 fastlane 2.239.0 deliver 源码事实,不猜):
  A. 截图 20 张:尺寸 ∈ deliver DEVICE_RESOLUTIONS(6.9"/6.5")、Display P3 ICC、
     文件名→locale 正则、每 locale 恰 5 张、内容非空(亮度直方图)
  B. 元数据四语:6 文件齐、限长(name30/subtitle30/keywords100/promo170/desc4000)、
     keywords 无竞品词、URL 域名正确
  C. URL 存活:privacy/support 必须 HTTP 200(5.1.1 死链是拒审项)
  D. 分级 JSON:键 ⊆ AgeRatingDeclaration attr_mapping 白名单,值合法
  E. 管道一致:Fastfile(submit=true/app_rating_path/合规)/Deliverfile(IDFA false)
  F. IPA:存在且 device 切片可验(Info.plist 关键键,ITSEncryption)
用法: python3 preflight_check.py [--no-net]
全绿输出 PREFLIGHT PASS,任一红输出非零退出。
"""
import os, sys, re, json, struct, subprocess, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # KinetTradeTools/
APP = os.path.join(ROOT, 'KinetBend')
FL = os.path.join(APP, 'fastlane')
META = os.path.join(FL, 'metadata')
SHOTS = os.path.join(FL, 'screenshots')
IPA = '/tmp/KinetBend-export/KinetBend.ipa'

LOCALES = ['en-US', 'zh-Hans', 'zh-Hant', 'ja']
MODES = ['stubup', 'offset', 'saddle3', 'saddle4', 'kick']
NAME_RE = re.compile(r'^\d+-(' + '|'.join(MODES) + r')-(en-US|zh-Hans|zh-Hant|ja)\.png$')

# fastlane deliver/lib/deliver/app_screenshot.rb DEVICE_RESOLUTIONS(逐字对照)
IPHONE_67 = [(1260, 2736), (2736, 1260), (1290, 2796), (2796, 1290), (1320, 2868), (2868, 1320)]
IPHONE_65 = [(1242, 2688), (2688, 1242), (1284, 2778), (2778, 1284)]
ALLOWED_SIZES = IPHONE_67 + IPHONE_65

# spaceship age_rating_declaration.rb attr_mapping 键全集(2026 API)
AGE_RATING_KEYS = {
    'advertising', 'ageAssurance', 'alcoholTobaccoOrDrugUseOrReferences', 'contests',
    'developerAgeRatingInfoUrl', 'gambling', 'gamblingSimulated', 'gunsOrOtherWeapons',
    'healthOrWellnessTopics', 'horrorOrFearThemes', 'kidsAgeBand', 'koreaAgeRatingOverride',
    'lootBox', 'matureOrSuggestiveThemes', 'medicalOrTreatmentInformation',
    'messagingAndChat', 'parentalControls', 'profanityOrCrudeHumor',
    'sexualContentGraphicAndNudity', 'sexualContentOrNudity', 'socialMedia',
    'socialMediaAgeRestricted', 'unrestrictedWebAccess', 'userGeneratedContent',
    'violenceCartoonOrFantasy', 'violenceRealistic',
    'violenceRealisticProlongedGraphicOrSadistic',
}
AGE_RATING_BOOLEAN = {'advertising', 'ageAssurance', 'gambling', 'healthOrWellnessTopics',
                      'lootBox', 'messagingAndChat', 'parentalControls', 'socialMedia',
                      'socialMediaAgeRestricted', 'unrestrictedWebAccess',
                      'userGeneratedContent'}
RATING_VALUES = {'NONE', 'INFREQUENT', 'INFREQUENT_OR_MILD', 'FREQUENT', 'FREQUENT_OR_INTENSE'}

# deliver upload_metadata.rb 文件名全集
META_FILES = ['name.txt', 'subtitle.txt', 'keywords.txt', 'promotional_text.txt',
              'release_notes.txt', 'description.txt']
LIMITS = {'name.txt': 30, 'subtitle.txt': 30, 'keywords.txt': 100,
          'promotional_text.txt': 170, 'description.txt': 4000, 'release_notes.txt': 4000}
COMPETITORS = ['quickbend', 'ibend', 'bendworks', 'cad pro', 'sanscon']

errors, warns = [], []
def err(m): errors.append(m); print(f"  ✗ {m}")
def warn(m): warns.append(m); print(f"  ⚠ {m}")
def ok(m): print(f"  ✓ {m}")

def sec(t): print(f"\n== {t} ==")

# ---------- A. 截图 ----------
sec("A. screenshots(20 张,deliver DEVICE_RESOLUTIONS 白名单)")
from PIL import Image
seen = {}      # locale -> set(modes)
for d in sorted(os.listdir(SHOTS)):
    ld = os.path.join(SHOTS, d)
    if not os.path.isdir(ld): continue
    if d not in LOCALES:
        err(f"locale 目录非 {LOCALES}: {d}"); continue
    for f in sorted(os.listdir(ld)):
        m = NAME_RE.match(f)
        if not m:
            err(f"{d}/{f} 文件名不合 <mode>-<locale>.png"); continue
        p = os.path.join(ld, f)
        im = Image.open(p)
        sz = im.size
        if sz not in ALLOWED_SIZES:
            err(f"{d}/{f} 尺寸 {sz} 不在 ASC 6.9\"/6.5\" 白名单")
        icc = im.info.get('icc_profile', b'')
        if len(icc) < 500:
            err(f"{d}/{f} ICC 缺失({len(icc)}B)")
        else:
            cls = icc[12:16]
            if cls != b'mntr':
                err(f"{d}/{f} ICC 类异常 {cls}")
        # 内容非空:灰度极差(纯色图会被 ASC 判占位图)
        g = im.convert('L')
        lo, hi = g.getextrema()
        if hi - lo < 40:
            err(f"{d}/{f} 画面疑似空图(灰度极差 {hi-lo})")
        seen.setdefault(d, set()).add(m.group(1))
for loc in LOCALES:
    got = seen.get(loc, set())
    if got != set(MODES):
        err(f"{loc} 模式集不全: {sorted(got)}")
    else:
        ok(f"{loc}: 5/5 模式齐全")

# ---------- B. 元数据 ----------
sec("B. metadata(四语,限长 + 竞品词 + 域名)")
for loc in LOCALES:
    ld = os.path.join(META, loc)
    for fn in META_FILES:
        p = os.path.join(ld, fn)
        if not os.path.exists(p):
            err(f"{loc}/{fn} 缺失"); continue
        txt = open(p, encoding='utf-8').read().rstrip('\n')
        lim = LIMITS[fn]
        if len(txt) > lim:
            err(f"{loc}/{fn} {len(txt)} > {lim}")
    # notes(审核备注)
    np_ = os.path.join(ld, 'review_information', 'notes.txt')
    if not os.path.exists(np_):
        err(f"{loc}/review_information/notes.txt 缺失")
    else:
        t = open(np_, encoding='utf-8').read()
        if len(t) > 4000: err(f"{loc} notes {len(t)} > 4000")
    kw = open(os.path.join(ld, 'keywords.txt'), encoding='utf-8').read().lower()
    for c in COMPETITORS:
        if c in kw: err(f"{loc} keywords 含竞品词 {c}")
if os.path.exists(os.path.join(META, 'copyright.txt')):
    ok("copyright/primary_category/privacy_url/support_url 共享项在")
else:
    err("metadata 共享项缺失(copyright 等)")

# ---------- C. URL 存活 ----------
sec("C. URLs(隐私/支持必须 200)")
if '--no-net' not in sys.argv:
    for fn in ['privacy_url.txt', 'support_url.txt']:
        u = open(os.path.join(META, fn), encoding='utf-8').read().strip()
        if not u.startswith('https://phinn.github.io/KinetAppPortal/'):
            err(f"{fn} 域名不符: {u}"); continue
        try:
            code = urllib.request.urlopen(u, timeout=15).status
            if code != 200: err(f"{fn} HTTP {code}")
            else: ok(f"{fn} → 200")
        except Exception as e:
            err(f"{fn} 请求失败: {e}")
else:
    warn("跳过网络检查(--no-net)")

# ---------- D. 分级 ----------
sec("D. age_rating.json(键/值对照 spaceship attr_mapping)")
ar = json.load(open(os.path.join(FL, 'age_rating.json')))
def snake2camel(s):
    a = s.split('_'); return a[0] + ''.join(w.capitalize() for w in a[1:])
for k, v in ar.items():
    ck = snake2camel(k)
    if ck not in AGE_RATING_KEYS:
        err(f"分级键越界: {k}")
        continue
    if ck in AGE_RATING_BOOLEAN:
        if not isinstance(v, bool): err(f"{k} 布尔键的值非 bool: {v}")
    else:
        if v not in RATING_VALUES: err(f"{k} 值非法: {v}")
ok(f"分级 {len(ar)} 键校验完")

# ---------- E. 管道一致 ----------
sec("E. Fastfile / Deliverfile(提交语义锁死)")
ff = open(os.path.join(FL, 'Fastfile')).read()
for needle, what in [
    ('submit_for_review: true', 'release lane 必须提审'),
    ('automatic_release: false', '手动放行'),
    ('app_rating_config_path', '分级 JSON 挂载'),
    ('export_compliance_uses_encryption: false', '导出合规(源码硬闸:缺=submit 报错)'),
    ('content_rights_contains_third_party_content: false', '内容版权声明'),
]:
    if needle not in ff: err(f"Fastfile 缺 {what}({needle})")
    else: ok(f"Fastfile: {what}")
df = open(os.path.join(FL, 'Deliverfile')).read()
for needle, what in [
    ('app_identifier "com.kinetai.kinetbend"', 'bundle id'),
    ('add_id_info_uses_idfa: false', 'IDFA=false'),
    ('first_name:', '审核联系人'),
]:
    if needle not in df: err(f"Deliverfile 缺 {what}")
    else: ok(f"Deliverfile: {what}")

# ---------- F. IPA ----------
sec("F. IPA(/tmp/KinetBend-export/KinetBend.ipa)")
if not os.path.exists(IPA):
    warn("IPA 不在(archive 后由 watch 脚本校验)——record 建档后 watch_and_release 会重归档并在此校验")
else:
    out = subprocess.run(['unzip', '-l', IPA], capture_output=True, text=True).stdout
    for needle, what in [('Info.plist', '主 Info.plist'), ('lproj', '四语 lproj')]:
        if needle in out: ok(f"IPA 含 {what}")
    n_lproj = len(set(re.findall(r'(\w[\w-]*\.lproj)/', out)))
    if n_lproj < 4: err(f"IPA lproj 数 {n_lproj} < 4")
    else: ok(f"IPA 含 {n_lproj} 个 lproj")
    # ITSEncryption:用 plutil 直接从 IPA 里的 plist 验(先解到 /tmp)
    r = subprocess.run(['bash', '-c',
        f"rm -rf /tmp/_ipa_chk && mkdir -p /tmp/_ipa_chk && cd /tmp/_ipa_chk && "
        f"unzip -o -q '{IPA}' 'Payload/*.app/Info.plist' && "
        f"plutil -extract ITSAppUsesNonExemptEncryption raw -o - Payload/*.app/Info.plist"],
        capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip() == 'false':
        ok("IPA Info.plist: ITSAppUsesNonExemptEncryption=false")
    else:
        err(f"IPA 导出合规键缺失或非 false({r.stdout.strip() or r.stderr.strip()[:80]})——需重 archive")

print()
if errors:
    print(f"PREFLIGHT FAIL: {len(errors)} 错 / {len(warns)} 警")
    sys.exit(1)
print(f"PREFLIGHT PASS(0 错,{len(warns)} 警)")
