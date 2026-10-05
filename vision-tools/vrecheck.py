#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vrecheck.py -- 分歧项复检器（定位 → 裁图放大 → 重问 → 确定性取色）

为什么需要它：多模型交叉验证只能抓「模型之间」的分歧。
当所有模型一致、却与本工具写的真值冲突时，靠投票是没用的 ——
必须回到像素：把那一小块抠出来放大，再看；顺手把颜色用算法量出来。

流程（每一步都可独立失败，失败就退到下一步的保守方案）：
  1) 让每个模型定位争议项 → bbox 并集（拿不到就用固定区域兜底）
  2) 按 bbox 裁图 + 放大 3x
  3) 用同一问题重问所有模型（只看放大块）
  4) 用 PIL 量化取主色（确定性证据，不经模型）
  5) 输出「整图答案 vs 放大后答案 vs 颜色证据」三联对照

用法：
  python vrecheck.py <图片> --item "胸前有没有一枚独立的宝石胸针？" \
      --models dashscope,zhipu --out 报告.md --crop-out 目录
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from eyeprobe import BACKENDS, call, img_b64  # noqa: E402

try:
    from PIL import Image
except ImportError:
    print("need Pillow"); sys.exit(2)


def parse_bbox(text, sent_size, orig_size):
    """Pull a bbox out of a model answer and rescale sent->original coords."""
    m = re.search(r"\[?\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\]?", text)
    if not m:
        return None
    if re.search(r'"found"\s*:\s*false', text, re.I):
        return None
    x1, y1, x2, y2 = (int(g) for g in m.groups())
    sw, sh = sent_size
    ow, oh = orig_size
    fx, fy = ow / sw, oh / sh
    box = [int(x1 * fx), int(y1 * fy), int(x2 * fx), int(y2 * fy)]
    x1, y1, x2, y2 = box
    if x2 <= x1 or y2 <= y1 or (x2 - x1) < 8 or (y2 - y1) < 8:
        return None
    return [max(0, x1), max(0, y1), min(ow, x2), min(oh, y2)]


def dominant_colors(im, n=6, ignore_near_white=True):
    """Deterministic colour evidence (no model involved)."""
    small = im.convert("RGB").resize((96, 96))
    q = small.quantize(colors=n, method=Image.MEDIANCUT)
    pal = q.getpalette()
    rows = []
    for cnt, idx in sorted(q.getcolors(), reverse=True):
        r, g, b = pal[idx * 3:idx * 3 + 3]
        if ignore_near_white and r > 235 and g > 235 and b > 235:
            continue
        rows.append(("#%02X%02X%02X" % (r, g, b), cnt, (r, g, b)))
    total = sum(c for _, c, _ in rows) or 1
    return [(h, round(100.0 * c / total, 1)) for h, c, _ in rows]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--item", required=True, help="争议项（一个具体问题）")
    ap.add_argument("--models", default="dashscope,zhipu")
    ap.add_argument("--crop-out", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--pad", type=float, default=0.35, help="bbox 外扩比例")
    ap.add_argument("--region", default="", help="手动指定 x1,y1,x2,y2（跳过模型定位，定位不准时用）")
    a = ap.parse_args()

    src = Path(a.image)
    if not src.exists():
        print("image not found"); sys.exit(2)
    models = [m.strip() for m in a.models.split(",") if m.strip() in BACKENDS]
    im0 = Image.open(src).convert("RGB")
    orig = im0.size

    # full-image payload (same pipeline as the models saw originally)
    b64_full, sent = img_b64(str(src))
    print("image : %s  %dx%d (sent %dx%d)" % (src.name, orig[0], orig[1], sent[0], sent[1]))
    print("item  : %s" % a.item)
    print("=" * 76)

    # ---------- step 1: locate ----------
    boxes = []
    region = None
    if a.region:
        try:
            region = tuple(int(x) for x in a.region.split(","))
            if len(region) != 4:
                raise ValueError("need 4 numbers")
            print("  区域 %s（--region 手动指定，跳过模型定位）" % (list(region),))
        except Exception:
            print("  --region 格式错误（应为 x1,y1,x2,y2），改用模型定位")
            region = None
    for m in ([] if region is not None else models):
        prompt = ('在图中找到「%s」所在区域。只输出 JSON，不要解释：'
                  '{"found":true,"bbox":[x1,y1,x2,y2]}  '
                  '（x/y 为图中像素坐标；确实找不到就输出 {"found":false}）') % a.item
        ok, res, secs = call(m, b64_full, prompt)
        if not ok:
            print("  定位 %-10s FAIL %s" % (m, res)); continue
        b = parse_bbox(res[0], sent, orig)
        print("  定位 %-10s %5.1fs → %s" % (m, secs, b if b else "未给出可用框"))
        if b:
            boxes.append(b)
        time.sleep(0.8)

    if region is None and boxes:
        x1 = min(b[0] for b in boxes); y1 = min(b[1] for b in boxes)
        x2 = max(b[2] for b in boxes); y2 = max(b[3] for b in boxes)
        padx = int((x2 - x1) * a.pad); pady = int((y2 - y1) * a.pad)
        x1, y1 = max(0, x1 - padx), max(0, y1 - pady)
        x2, y2 = min(orig[0], x2 + padx), min(orig[1], y2 + pady)
        region = (x1, y1, x2, y2)
        print("  → 并集区域 %s  （外扩 %.0f%%）" % (list(region), a.pad * 100))
    elif region is None:
        w, h = orig
        region = (0, 0, w, int(h * 0.45))
        print("  → 定位全部失败，退到固定区域（上半 45%%）%s" % (list(region),))

    # ---------- step 2: crop + upscale ----------
    crop = im0.crop(region)
    scale = max(1, min(4, int(1600 / max(1, crop.size[0]))))
    big = crop.resize((crop.size[0] * scale, crop.size[1] * scale), Image.LANCZOS)
    outdir = Path(a.crop_out) if a.crop_out else HERE / "recheck-out"
    outdir.mkdir(parents=True, exist_ok=True)
    stem = "%s_%s" % (src.stem, re.sub(r"[^A-Za-z0-9\u4e00-\u9fff]+", "", a.item)[:18])
    crop_path = outdir / ("%s_crop.png" % stem)
    big_path = outdir / ("%s_x%d.png" % (stem, scale))
    crop.save(crop_path); big.save(big_path)
    print("  裁图 %s  → 放大 %dx  %s" % (crop.size, scale, big_path))

    # ---------- step 3: deterministic colour evidence ----------
    cols = dominant_colors(crop)
    print("  区域主色（算法取色，不经模型）：%s" % ", ".join("%s %s%%" % c for c in cols[:5]))

    # ---------- step 4: re-ask on the crop ----------
    b64_crop, sent_crop = img_b64(str(big_path))
    print("\n  —— 同一问题，改问放大块 ——")
    recrop = {}
    for m in models:
        ok, res, secs = call(m, b64_crop, a.item)
        if ok:
            recrop[m] = res[0]
            print("  [放大后] %-10s %5.1fs  %s" % (m, secs, res[0][:110].replace("\n", " ")))
        else:
            print("  [放大后] %-10s FAIL %s" % (m, res))
        time.sleep(0.8)

    print("\n  —— 对照：整图直接问 ——")
    full = {}
    for m in models:
        ok, res, secs = call(m, b64_full, a.item)
        if ok:
            full[m] = res[0]
            print("  [整图  ] %-10s %5.1fs  %s" % (m, secs, res[0][:110].replace("\n", " ")))
        else:
            print("  [整图  ] %-10s FAIL %s" % (m, res))
        time.sleep(0.8)

    # ---------- report ----------
    lines = ["# 复检报告：%s" % a.item, "",
             "- 图片：`%s`" % src,
             "- 区域：`%s`（定位来源：%s）" % (list(region), "模型 bbox 并集" if boxes else "固定上半区"),
             "- 放大：%dx → `%s`" % (scale, big_path),
             "- 区域主色（算法，不经模型）：%s" % ", ".join("%s (%s%%)" % c for c in cols[:6]),
             "", "## 整图答案", ""]
    for m, t in full.items():
        lines += ["**%s**：%s" % (m, t), ""]
    lines += ["## 放大后答案", ""]
    for m, t in recrop.items():
        lines += ["**%s**：%s" % (m, t), ""]

    if a.out:
        Path(a.out).write_text("\n".join(lines), encoding="utf-8")
        print("\nreport -> %s" % a.out)
    print("crop   -> %s" % big_path)


if __name__ == "__main__":
    main()
