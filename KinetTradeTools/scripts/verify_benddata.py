#!/usr/bin/env python3
"""
benddata.json 完整性门禁:
  1. version / source 字段存在
  2. id 唯一,命名规则 = type小写-管径(去引号)
  3. take-up / minRadius 数值为正
  4. EMT/RMC/IMC 三型 × 1/2"–4" 全 30 项
  5. 不允许残留 shrinkPerInsh/shrink 字段(shrink 是角度函数,已收编进 BendAngle.shrinkPerInch(angle:),数据里出现即为双重真值)
退出码非 0 = 门禁失败。
"""
import json
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "KitCore" / "Sources" / "KitCore" / "benddata.json"

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
        for field in ("takeUpInches", "minRadiusInches"):
            if not c.get(field) or c[field] <= 0:
                errors.append(f"{cid}: {field} 非正数")
        # shrink 不得出现在数据里(角度函数,见 BendAngle.shrinkPerInch)
        for banned in ("shrinkPerInch", "shrink"):
            if banned in c:
                errors.append(f"{cid}: 禁止字段 {banned}(shrink 已按角度建模,勿在数据里双写)")

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

    print(f"✓ verify_benddata PASS:{total} 项管规,3 型 × 10 档,字段完备无残留")
    return 0


if __name__ == "__main__":
    sys.exit(main())
