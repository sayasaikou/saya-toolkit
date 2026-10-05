#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vscore.py -- score vision models against the truth set (回归测试打分器)

设计要点：
  * 问题从真值表**动态生成**（问题和真值严格对应，不靠预设 prompts 猜）
  * 裁判用 LLM，且**交叉裁判**：不让模型给自己的答案打分（默认 A 判 B、B 判 A）
  * 四档判分：hit=1.0 / partial=0.5 / wrong=0 / missing=0

用法：
  python vscore.py                        # 跑全部图 × 默认模型
  python vscore.py --images ref-a         # 只跑一张
  python vscore.py --models dashscope,zhipu --out <report.md>
"""

import argparse
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from eyeprobe import BACKENDS, user_env, call, img_b64  # noqa: E402

TRUTH = HERE / "testset" / "truth.json"
WEIGHT = {"hit": 1.0, "partial": 0.5, "wrong": 0.0, "missing": 0.0}


def norm_id(s):
    """Tolerant id compare: judges sometimes echo '1', 'Line 1', '[line1]'..."""
    return re.sub(r"[^a-z0-9]", "", str(s or "").lower())



def ask_text(backend, prompt, max_tokens=2400, timeout=240, retries=3):
    """Plain-text call to a backend (no image) -- used for judging.
    Retries on rate-limit/5xx: without this a single 429 silently drops a whole
    sample, making every model's denominator different and the scores incomparable."""
    b = BACKENDS[backend]
    key = user_env(b["keyenv"])
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {"model": b["model"], "messages": [{"role": "user", "content": prompt}],
               "max_tokens": max_tokens, "temperature": 0}
    data = json.dumps(payload).encode()
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(b["url"], data=data, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                j = json.loads(r.read().decode())
            return j["choices"][0]["message"]["content"].strip()
        except urllib.error.HTTPError as e:
            last = e
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(6 * (attempt + 1))
                continue
            raise
        except Exception as e:
            last = e
            if attempt < retries:
                time.sleep(4 * (attempt + 1))
                continue
            raise
    raise last if last else RuntimeError("ask_text failed")


def build_question(facts):
    lines = ["请逐项回答下面关于这张图的问题。**每项一行**，只写你真正看清的；"
             "看不清就写「看不清」，不要猜。"]
    for i, f in enumerate(facts, 1):
        lines.append("%d. [%s] %s" % (i, f["id"], f["q"]))
    return "\n".join(lines)


JUDGE_PROMPT = """你是严格的视觉模型评分员。下面是【标准答案】与【某模型的回答】。

请逐条判断该模型的表现，每项给一个 verdict：
- "hit"     : 与标准答案实质一致（措辞不同、更详细都算；要点命中即可）
- "partial" : 部分正确，或含糊其辞但没有与标准答案冲突
- "wrong"   : 明确说了，但与标准答案矛盾
- "missing" : 该模型完全没有提到这一项

只输出 JSON 数组，不要任何解释文字或代码块标记：
[{"id":"<与标准答案相同的 id>","verdict":"hit|partial|wrong|missing","why":"不超过20字"}]

【标准答案】
%(truth)s

【模型回答】
%(answer)s
"""


def judge(judge_model, facts, answer):
    truth_lines = []
    for f in facts:
        truth_lines.append('- id=%s | 问题：%s | 标准答案：%s' % (f["id"], f["q"], f["truth"]))
    prompt = JUDGE_PROMPT % {"truth": "\n".join(truth_lines), "answer": answer}
    raw = ask_text(judge_model, prompt)
    # tolerate ```json fences
    t = raw.strip()
    if t.startswith("```"):
        t = t.split("```")[1]
        if t.lower().startswith("json"):
            t = t[4:]
    start, end = t.find("["), t.rfind("]")
    if start < 0 or end < 0:
        raise ValueError("judge returned no JSON array: %s" % raw[:200])
    return json.loads(t[start:end + 1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--truth", default=str(TRUTH))
    ap.add_argument("--images", default="", help="comma-separated image ids (default: all)")
    ap.add_argument("--models", default="dashscope,zhipu")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    data = json.loads(Path(a.truth).read_text(encoding="utf-8"))
    want = [x.strip() for x in a.images.split(",") if x.strip()]
    images = [im for im in data["images"] if not want or im["id"] in want]
    models = [m.strip() for m in a.models.split(",") if m.strip() in BACKENDS]
    if not images or not models:
        print("nothing to do"); sys.exit(2)

    print("truth set : %s (%d images)" % (a.truth, len(images)))
    print("models    : %s" % ", ".join(models))
    print("judge     : cross (A judges B, B judges A)")
    print("=" * 78)

    all_rows = []
    for im in images:
        p = Path(im["path"])
        if not p.exists():
            print("SKIP (missing): %s" % p); continue
        facts = im["facts"]
        q = build_question(facts)
        b64, size = img_b64(str(p))
        print("\n## %s  [%s]  %dx%d  事实 %d 条" %
              (im["label"], im["id"], size[0], size[1], len(facts)))

        answers = {}
        for m in models:
            ok, res, secs = call(m, b64, q)
            if ok:
                answers[m] = res[0]
                print("   答: %-10s %5.1fs  %d 字" % (m, secs, len(res[0])))
            else:
                print("   答: %-10s FAIL %s" % (m, res))

        for m, ans in answers.items():
            judges = [x for x in models if x != m] or [m]
            verdicts, jm, last_err = None, None, None
            for cand in judges:                       # fail over to another judge
                try:
                    verdicts = judge(cand, facts, ans)
                    jm = cand
                    break
                except Exception as e:
                    last_err = e
                    time.sleep(2)
            if verdicts is None:
                print("   判: ALL JUDGES FAILED (%s) -- sample marked UNJUDGED" % str(last_err)[:70])
                continue
            vmap = {}
            for v in verdicts:
                if isinstance(v, dict):
                    vmap[norm_id(v.get("id"))] = v
            score = 0.0
            detail = []
            unmatched = 0
            for idx, f in enumerate(facts):
                v = vmap.get(norm_id(f["id"]))
                if v is None and idx < len(verdicts):
                    # positional fallback: judge answered in order but echoed odd ids
                    cand = verdicts[idx]
                    v = cand if isinstance(cand, dict) else None
                if v is None or not v.get("verdict"):
                    unmatched += 1
                    v = {"verdict": "missing", "why": "裁判未返回该项"}
                verdict = str(v.get("verdict", "missing")).strip().lower()
                if verdict not in WEIGHT:
                    verdict = "partial"  # unknown verdict -> half credit, never silent zero
                score += WEIGHT.get(verdict, 0.0)
                detail.append({"id": f["id"], "verdict": verdict,
                               "why": v.get("why", ""), "truth": f["truth"]})
            if unmatched:
                print("       注意： 裁判漏判 %d/%d 项（按 missing 计）—— 该模型分数可能偏低"
                      % (unmatched, len(facts)))

            total = len(facts)
            pct = 100.0 * score / total if total else 0
            counts = {}
            for d in detail:
                counts[d["verdict"]] = counts.get(d["verdict"], 0) + 1
            print("   判: %-10s → %5.1f%%  (hit %d / partial %d / wrong %d / missing %d)"
                  % (jm, pct, counts.get("hit", 0), counts.get("partial", 0),
                     counts.get("wrong", 0), counts.get("missing", 0)))
            for d in detail:
                if d["verdict"] in ("wrong", "missing"):
                    print("        %-8s %-6s %s" % (d["id"], d["verdict"], d["truth"][:52]))
            all_rows.append({"image": im["id"], "label": im["label"], "model": m,
                             "judge": jm, "score": round(pct, 1),
                             "counts": counts, "detail": detail})
            time.sleep(1)

    # ---- summary
    print("\n" + "=" * 78)
    print("## 总分")
    agg = {}
    for r in all_rows:
        agg.setdefault(r["model"], []).append(r["score"])
    for m, ss in sorted(agg.items(), key=lambda kv: -sum(kv[1]) / len(kv[1])):
        print("   %-12s 平均 %5.1f%%   最高 %5.1f%%   最低 %5.1f%%   (%d 张图)"
              % (m, sum(ss) / len(ss), max(ss), min(ss), len(ss)))

    if a.out:
        lines = ["# 视觉回归评分报告", "",
                 "- 真值集：`%s`" % a.truth,
                 "- 模型：%s ｜ 裁判：交叉裁判" % ", ".join(models), ""]
        lines += ["## 总分", ""]
        for m, ss in sorted(agg.items(), key=lambda kv: -sum(kv[1]) / len(kv[1])):
            lines.append("- **%s**：平均 %.1f%%（%d 张图）" % (m, sum(ss) / len(ss), len(ss)))
        lines += ["", "## 逐图逐项", ""]
        for r in all_rows:
            lines += ["### %s · %s（裁判 %s）→ **%.1f%%**" % (r["label"], r["model"], r["judge"], r["score"]), "",
                      "| 项 | 判定 | 真值 |", "| --- | --- | --- |"]
            for d in r["detail"]:
                lines.append("| `%s` | %s | %s |" % (d["id"], d["verdict"], d["truth"]))
            lines.append("")
        Path(a.out).write_text("\n".join(lines), encoding="utf-8")
        jp = Path(a.out).with_suffix(".json")
        jp.write_text(json.dumps(all_rows, ensure_ascii=False, indent=2), encoding="utf-8")
        print("\nreport -> %s" % a.out)
        print("raw    -> %s" % jp)


if __name__ == "__main__":
    main()
