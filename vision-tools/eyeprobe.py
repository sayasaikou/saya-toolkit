#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eyeprobe.py -- multi-backend vision cross-check probe (工具箱的"审讯"工具)

为什么存在：单个视觉模型答一次就下结论，是本工具踩过最多的坑。
本工具做三件事：
  1) 分块：把长图切成上/中/下，逐块问同一个问题（细节召回靠放大，不靠祈祷）
  2) 多后端：同一问题问多个模型，各自独立作答
  3) 仲裁：把 N 份答案交给一个模型比对，明确列出"一致"与"冲突"

用法：
  python eyeprobe.py <图片> -q "问题" [--models dashscope,zhipu] [--blocks 3] [--out 报告.md]
  python eyeprobe.py <图片> --preset out fit   # 外观建档预设问题组

Key 来源：Windows 用户级环境变量（HKCU\\Environment），脚本自己读，从不打印。
"""

import argparse
import base64
import io
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("need Pillow: pip install Pillow")
    sys.exit(2)

# Windows 控制台默认是 GBK 码页：中文会乱码，emoji 会直接 UnicodeEncodeError 打死进程。
# 本模块是这套工具箱的公共入口（eye / layered / vrecheck / vscore / doctor 全都 import 它），
# 所以在这里统一一次，比在每个脚本里各抄三行可靠。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# ---------------------------------------------------------------- backends
BACKENDS = {
    "dashscope": {
        "url": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        "model": "qwen3-vl-plus",
        "keyenv": "DASHSCOPE_API_KEY",
        "note": "阿里百炼 vl-plus（现役主力）",
    },
    "omni": {
        "url": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        "model": "qwen3.5-omni-plus",
        "keyenv": "DASHSCOPE_API_KEY",
        "note": "阿里百炼 omni。注意： 2026-10-03 三轮实测（22 项真值）："
                "omni 59.1 / 59.1 / 54.5，vl-plus 50.0 / 54.5 / 59.1 —— "
                "**两者合计基本持平，谈不上谁更强**（早先只看两轮就下了'omni 更强'的结论，"
                "第三轮就翻了）。但方向是稳定的：omni 在 ref-b（干活形态）上 88/100/75，"
                "vl-plus 只有 38/38/50；ref-a（常态）反过来是 vl-plus 好。"
                "⇒ **互补，建议两个一起上**，别只留一个。",
    },
    "doubao": {
        # 火山方舟，OpenAI 兼容端点。**还没有 Key**（2026-10-03 查过 HKCU\Environment，
        # 只有 DASHSCOPE_API_KEY 与 ZAI_API_KEY）—— 没有 keyenv 时 available_models()
        # 会自动跳过，所以现在挂着不影响任何流程，拿到 Key 就能用。
        #
        # 注意： 拿到 Key 后要先确认两件事（方舟账号之间不一样）：
        #   1) model 到底填**模型名**还是**推理接入点 ID**（形如 ep-2026xxxx）——
        #      有的账号必须用后者，填错会报 model not found；
        #   2) 该账号有没有开通这个模型（控制台 → 开通管理）。
        # 依据：SuperCLUE-VLM 2026-04 中文多模态榜，字节 Doubao-Seed-2.0-Pro 以 90.66
        # 分列总榜第一（超 Gemini-3.1-Pro 89.35）。注意： 但那份榜测的是通用识别/图表/
        # 医疗影像，**不含"看服装细节"**，所以对我们要先实测再信（判据：换模型必过真值集）。
        "url": "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        "model": "doubao-seed-2-0-pro-260215",
        "keyenv": "ARK_API_KEY",
        "note": "火山方舟 豆包（中文视觉榜第一，待验证）",
    },
    "zhipu": {
        "url": "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        "model": "glm-4.6v-flash",
        "keyenv": "ZAI_API_KEY",
        "note": "智谱 免费备份",
    },
    "ovh": {
        "url": "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions",
        "model": "Qwen3.5-397B-A17B",
        "keyenv": None,
        "note": "OVH 匿名兜底 (2 rpm)",
    },
    "ollama": {
        "url": "http://127.0.0.1:11434/v1/chat/completions",
        "model": "qwen2.5vl:7b",
        "keyenv": None,
        "note": "本地离线",
    },
}

PRESETS = {
    "outfit": (
        "逐项描述这张图里角色的外观，只写你真正看清的："
        "① 领口与领结 ② 是否露肩 / 胸前有无独立胸针 ③ 上身衣物结构与扣子 "
        "④ 腰部（腰封/腰带/扣） ⑤ 裙子的层数与各层颜色花纹 ⑥ 围裙上的图案及其朝向 "
        "⑦ 头饰（发带/蝴蝶结位置） ⑧ 袜子 ⑨ 鞋 ⑩ 头发颜色渐变与长度。"
        "每项一行。看不清的项必须写「看不清」，不要猜。"
    ),
    "ocr": "逐字转写图中所有文字（保留换行与标点）。图中没有文字就回答「无文字」。",
    "diff": "详细列出这张图里所有显著元素、它们的相对位置和颜色。不要评价，只描述。",
}


# ---------------------------------------------------------------- helpers
def user_env(name):
    """Read a *persisted* user env var (HKCU\\Environment), not just the process env."""
    if not name:
        return ""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            val, _ = winreg.QueryValueEx(k, name)
            return str(val).strip()
    except Exception:
        return os.environ.get(name, "").strip()


def img_b64(path, max_side=2200, quality=92):
    """Load, optionally downscale, return base64 PNG/JPEG payload."""
    im = Image.open(path)
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    w, h = im.size
    scale = min(1.0, max_side / max(w, h))
    if scale < 1.0:
        im = im.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=quality)
    return base64.b64encode(buf.getvalue()).decode(), im.size


def slice_vertical(path, n):
    """Split image into n horizontal bands; return list of (label, b64, size)."""
    im = Image.open(path)
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    w, h = im.size
    out = []
    labels = {1: ["整图"], 2: ["上半", "下半"], 3: ["上部", "中部", "下部"]}
    lab = labels.get(n) or ["块%d" % (i + 1) for i in range(n)]
    step = h / n
    for i in range(n):
        top, bot = int(i * step), int((i + 1) * step)
        # small overlap so a boundary element is not cut in half
        pad = int(step * 0.04) if n > 1 else 0
        top = max(0, top - pad)
        bot = min(h, bot + pad)
        band = im.crop((0, top, w, bot))
        bw, bh = band.size
        if max(bw, bh) > 2200:
            s = 2200 / max(bw, bh)
            band = band.resize((int(bw * s), int(bh * s)), Image.LANCZOS)
        buf = io.BytesIO()
        band.save(buf, format="JPEG", quality=92)
        out.append((lab[i], base64.b64encode(buf.getvalue()).decode(), band.size))
    return out


def collapse_repeats(text, max_keep=2):
    """折叠模型的**复读崩溃**。返回 (清理后的文本, 重复次数)；没复读就原样返回、次数 0。

    2026-10-03 实测（用户当场抓的）：ollama 在一张 8 MP 立绘上把
    「角色的腿部有红色的蝴蝶结装饰。」连着吐了 **24 遍** —— 而流水线**把它当正常内容收了**：
    原样进报告的"原始回答"，还在分歧检测里被归成一个条目（"重复蝴蝶结列举，共 29 次"）。
    ⇒ **复读不是描述，是故障。** 它最坏的地方不是难看，是让"多模型交叉"里凭空多出一个
    谁都没看见的观察项，等于往证据链里掺假。

    判据（保守，只抓明显崩溃）：同一行（去空白后）重复 ≥4 次，**且**占非空行 ≥35%。
    正常的"多处蝴蝶结"描述不会让同一整句反复出现。
    """
    s = str(text or "")
    lines = [l.strip() for l in s.splitlines() if l.strip()]
    if len(lines) < 6:
        return s, 0
    # 剥掉行首编号/项目符号再比 —— 否则「10. 同一句话」和「11. 同一句话」会被当成两行，
    # 而模型复读时经常是一边吐一边加序号（本工具第一版就漏了这种情况）。
    def _key(l):
        return re.sub(r'^\s*(?:[-*•]|\d+[.、)）])\s*', '', l)
    keys = [_key(l) for l in lines]
    keys = [k for k in keys if k]
    if len(keys) < 6:
        return s, 0
    line, n = Counter(keys).most_common(1)[0]
    if n < 4 or n / float(len(keys)) < 0.35:
        return s, 0
    kept, seen = [], 0
    for l, k in zip(lines, [_key(x) for x in lines]):
        if k == line:
            seen += 1
            if seen > max_keep:      # 保留前两次（证明它确实在说这件事），其余丢掉
                continue
        kept.append(l)
    kept += ["", "[!] 模型复读：同一句「%s…」重复了 %d 次，已折叠 —— 该答案可靠性下降，"
                 "结论请以其他模型为准。" % (line[:40], n)]
    return "\n".join(kept), n


def call(backend, b64, question, retries=2, timeout=90, max_tokens=1600, deadline=None):
    """One vision call. Returns (ok, text_or_error, seconds).

    max_tokens is a parameter because structured cards (30+ items) need a bigger budget
    than a single free-form question -- a fixed 1600 silently truncated long JSON answers.

    deadline (epoch seconds, optional) is a GLOBAL wall-clock budget for the whole
    pipeline. Two rules earned the hard way live here (2026-10-03, a 2700x5400 image ran
    9 minutes without producing anything):
      1) A TIMEOUT IS NEVER RETRIED. A hung call cannot be fixed by waiting several times
         as long; retrying it was the single biggest multiplier of that 9-minute stall
         (180s x 3 attempts = 540s per backend, times every block and every recheck).
      2) The per-attempt socket timeout is clamped to what is left of the budget, so one
         slow backend can never overrun the entire pipeline.
    """
    b = BACKENDS[backend]
    key = user_env(b["keyenv"])
    if b["keyenv"] and not key:
        return False, "no key in env %s" % b["keyenv"], 0.0
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {
        "model": b["model"],
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": question},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}},
        ]}],
        "max_tokens": max_tokens,
        "temperature": 0,
    }
    data = json.dumps(payload).encode()
    last = ""
    for attempt in range(retries + 1):
        eff = timeout
        if deadline is not None:
            left = deadline - time.time()
            if left <= 5:
                return False, "global budget exhausted (%.0fs left)" % max(0.0, left), 0.0
            eff = max(5, min(timeout, int(left)))
        t0 = time.time()
        try:
            req = urllib.request.Request(b["url"], data=data, headers=headers)
            with urllib.request.urlopen(req, timeout=eff) as r:
                j = json.loads(r.read().decode())
            txt = j["choices"][0]["message"]["content"].strip()
            txt, rep = collapse_repeats(txt)
            usage = dict(j.get("usage") or {})
            if rep:
                usage["repeat_collapsed"] = rep
            return True, (txt, usage), time.time() - t0
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:200].replace("\n", " ")
            last = "HTTP %d %s" % (e.code, body)
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(4 * (attempt + 1))
                continue
            return False, last, time.time() - t0
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, str(e)[:160])
            # A timeout is terminal: the backend is too slow for THIS payload, and a
            # retry only multiplies the wait. (Socket timeouts surface as TimeoutError,
            # socket.timeout or URLError('timed out'), depending on the Python version,
            # so match on all three.)
            if isinstance(e, (TimeoutError, socket.timeout)) or "timed out" in last.lower():
                return False, "TIMEOUT after %ds -- %s" % (eff, last), time.time() - t0
            if attempt < retries:
                time.sleep(3 * (attempt + 1))
                continue
            return False, last, time.time() - t0
    return False, last, 0.0


def arbitrate(answers, judge="dashscope"):
    """Ask one model to compare the answers and separate agreement from conflict."""
    blocks = []
    for label, who, txt in answers:
        blocks.append("### 来源：%s / %s\n%s" % (who, label, txt))
    prompt = (
        "下面是多个视觉模型对同一张图（或其同一局部）的独立回答。\n"
        "请只做三件事，用中文：\n"
        "1. **一致项**：所有或多数来源互相印证的结论（逐条列）\n"
        "2. **冲突项**：来源之间说法不一致的地方 —— 逐个列出「A说… B说…」，不要替它们裁决\n"
        "3. **孤证项**：只有一个来源提到、别的没提的，标出来（可能是幻觉，也可能是别人漏了）\n"
        "不要补充你自己的观察，只做比对。\n\n" + "\n\n".join(blocks)
    )
    b = BACKENDS[judge]
    key = user_env(b["keyenv"])
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {"model": b["model"], "messages": [{"role": "user", "content": prompt}],
               "max_tokens": 2000}
    try:
        req = urllib.request.Request(b["url"], data=json.dumps(payload).encode(), headers=headers)
        with urllib.request.urlopen(req, timeout=240) as r:
            j = json.loads(r.read().decode())
        return j["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return "_仲裁失败：%s_" % str(e)[:200]


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="multi-backend vision cross-check")
    ap.add_argument("image")
    ap.add_argument("-q", "--question", default=None)
    ap.add_argument("--preset", choices=sorted(PRESETS.keys()), default=None)
    ap.add_argument("--models", default="dashscope,zhipu")
    ap.add_argument("--blocks", type=int, default=1)
    ap.add_argument("--out", default=None)
    ap.add_argument("--judge", default="dashscope")
    ap.add_argument("--no-arbitrate", action="store_true")
    a = ap.parse_args()

    q = a.question or (PRESETS[a.preset] if a.preset else PRESETS["diff"])
    models = [m.strip() for m in a.models.split(",") if m.strip() in BACKENDS]
    if not models:
        print("no valid models"); sys.exit(2)

    src = Path(a.image)
    if not src.exists():
        print("image not found: %s" % src); sys.exit(2)

    bands = slice_vertical(str(src), a.blocks)
    print("image  : %s" % src.name)
    print("models : %s" % ", ".join(models))
    print("bands  : %d" % len(bands))
    print("q      : %s..." % q[:60].replace("\n", " "))
    print("-" * 70)

    results, answers = [], []
    for label, b64, size in bands:
        for m in models:
            ok, res, secs = call(m, b64, q)
            if ok:
                txt, usage = res
                it = (usage.get("prompt_tokens_details") or {}).get("image_tokens", "?")
                print("  OK   %-10s %-5s %5.1fs  (img_tok=%s)  %s" %
                      (m, label, secs, it, txt[:58].replace("\n", " ")))
                answers.append((label, m, txt))
                results.append({"band": label, "model": m, "ok": True, "text": txt,
                                "seconds": round(secs, 1), "usage": usage, "size": size})
            else:
                print("  FAIL %-10s %-5s %5.1fs  %s" % (m, label, secs, res))
                results.append({"band": label, "model": m, "ok": False, "error": res})
            time.sleep(1.0)

    verdict = None
    if answers and not a.no_arbitrate and len(answers) > 1:
        print("-" * 70)
        print("arbitrating %d answers with %s ..." % (len(answers), a.judge))
        verdict = arbitrate(answers, a.judge)

    # ---- markdown report
    lines = ["# eyeprobe 报告", "",
             "- 图片：`%s`" % src,
             "- 模型：%s" % ", ".join(models),
             "- 分块：%d ｜ 提问：%s" % (len(bands), q[:200]), ""]
    if verdict:
        lines += ["## 仲裁结果（一致 / 冲突 / 孤证）", "", verdict, ""]
    lines += ["## 原始回答", ""]
    for r in results:
        if r["ok"]:
            lines += ["### %s · %s（%.1fs）" % (r["band"], r["model"], r["seconds"]), "",
                      r["text"], ""]
        else:
            lines += ["### %s · %s —— **失败**" % (r["band"], r["model"]), "",
                      "`%s`" % r["error"], ""]
    report = "\n".join(lines)

    if a.out:
        Path(a.out).write_text(report, encoding="utf-8")
        jsonp = Path(a.out).with_suffix(".json")
        jsonp.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        print("-" * 70)
        print("report -> %s" % a.out)
        print("raw    -> %s" % jsonp)
    else:
        print("-" * 70)
        print(report)


if __name__ == "__main__":
    main()
