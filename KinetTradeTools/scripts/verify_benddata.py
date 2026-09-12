#!/usr/bin/env python3
"""verify_benddata.py — benddata.json 完整性门禁(对齐 KinetDriverStudy verify_bank 模式)。

检查项:
  1. JSON 可解析,version/source 字段存在
  2. conduit id 唯一
  3. id 命名 = type 小写-tradeSize
  4. 数值字段全为正
  5. EMT/RMC/IMC 三类各有 10 档管径且管径集合一致
  6. shrinkPerInch 与 Benfield 常数表逐档比对(黄金值)
  7. 1/2"–4" 全 30 项
退出码非 0 = 门禁失败。
"""
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "KitCore" / "Sources" / "KitCore" / "benddata.json"

# Benfield shrink 系数黄金表(每英寸 offset 的缩短量,英寸)
BENFIELD_SHRINK = {
    '1/2"': 5 / 16,      # 0.3125
    '3/4"': 3 / 8,       # 0.375
    '1"': 7 / 16,        # 0.4375
    '1-1/4"': 9 / 16,    # 0.5625
    '1-1/2"': 5 / 8,     # 0.625
    '2"': 11 / 16,       # 0.6875
    '2-1/2"': 13 / 16,   # 0.8125
    '3"': 15 / 16,       # 0.9375
    '3-1/2"': 17 / 16,   # 1.0625
    '4"': 19 / 16,       # 1.1875
}

EXPECTED_SIZES = [
    '1/2"', '3/4"', '1"', '1-1/4"', '1-1/2"',
    '2"', '2-1/2"', '3"', '3-1/2"', '4"',
]


def main() -> int:
    errors: list[str] = []

    raw = json.loads(DATA.read_text(encoding="utf-8"))

    if not raw.get("version"):
        errors.append("version 字段缺失")
    if not raw.get("source"):
        errors.append("source 字段缺失")

    conduits = raw.get("conduits", [])
    ids = [c["id"] for c in conduits]
    if len(ids) != len(set(ids)):
        dupes = [i for i in ids if ids.count(i) > 1]
        errors.append(f"id 重复: {sorted(set(dupes))}")

    for c in conduits:
        cid = c["id"]
        # id 命名规则:type 小写 + "-" + tradeSize 去掉英寸引号
        expect_id = c["type"].lower() + "-" + c["tradeSize"].replace('"', '')
        if cid != expect_id:
            errors.append(f"{cid}: id 应为 {expect_id}")
        # 数值正数
        for field in ("takeUpInches", "shrinkPerInch", "minRadiusInches"):
            if not c.get(field) or c[field] <= 0:
                errors.append(f"{cid}: {field} 非正数")
        # Benfield shrink 黄金值
        want = BENFIELD_SHRINK.get(c["tradeSize"])
        if want is None:
            errors.append(f"{cid}: 管径 {c['tradeSize']} 不在黄金表内")
        elif abs(c["shrinkPerInch"] - want) > 1e-9:
            errors.append(f"{cid}: shrinkPerInch={c['shrinkPerInch']} 应为 {want}")

    # 三类各 10 档、管径集合一致
    by_type: dict[str, list] = {}
    for c in conduits:
        by_type.setdefault(c["type"], []).append(c["tradeSize"])
    for t in ("EMT", "RMC", "IMC"):
        sizes = sorted(by_type.get(t, []), key=EXPECTED_SIZES.index)
        if len(sizes) != 10:
            errors.append(f"{t}: 应 10 档,实际 {len(sizes)}: {sizes}")
        elif sizes != sorted(EXPECTED_SIZES, key=EXPECTED_SIZES.index):
            errors.append(f"{t}: 管径集合不符: {sizes}")
    extra = set(by_type) - {"EMT", "RMC", "IMC"}
    if extra:
        errors.append(f"未知管型: {sorted(extra)}")

    total = len(conduits)
    if total != 30:
        errors.append(f"总数应 30(3 型 × 10 档),实际 {total}")

    if errors:
        print(f"✗ verify_benddata FAIL({len(errors)} 项):")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"✓ verify_benddata PASS:{total} 项管规,3 型 × 10 档,shrink 黄金值全对")
    return 0


if __name__ == "__main__":
    sys.exit(main())
