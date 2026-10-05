#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
doctor.py -- 识图体系的自检（一条命令看清哪一层坏了）

为什么需要：这套体系有 4 层、2 个 Key、1 个本地服务、1 个真值集。
出问题时最贵的是「不知道是哪一层坏了」—— 今天已经为这个绕了两次弯
（一次误判 deepseek-flash 不能看图、一次误判 Ollama 卡死）。

用法：
  python doctor.py            # 静态检查（不花钱、不调模型）
  python doctor.py --live     # 额外各后端实调一次（会消耗额度）
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# 本地 OCR 是可选项：优先环境变量 TESSERACT_EXE，其次 PATH 里的 tesseract。
TESSERACT = os.environ.get("TESSERACT_EXE") or shutil.which("tesseract") or ""

OK, BAD, WARN = "[ OK ]", "[FAIL]", "[WARN]"
results = []


def say(tag, label, detail=""):
    results.append((tag, label, detail))
    print("%s %-34s %s" % (tag, label, detail))


def check_python():
    try:
        from PIL import Image  # noqa: F401
        import PIL
        say(OK, "Python 依赖 Pillow", PIL.__version__)
    except Exception as e:
        say(BAD, "Python 依赖 Pillow", str(e)[:60])
    for mod in ("difflib", "json", "urllib.request", "concurrent.futures"):
        try:
            __import__(mod)
        except Exception as e:
            say(BAD, "标准库 %s" % mod, str(e)[:60])


def check_tesseract():
    exe = Path(TESSERACT) if TESSERACT else None
    if not (exe and exe.exists()):
        say(WARN, "本地 OCR tesseract", "未找到 —— 设 TESSERACT_EXE 或加入 PATH；缺它只影响 L0 的 OCR")
        return
    try:
        r = subprocess.run([str(exe), "--version"], capture_output=True, timeout=20)
        v = (r.stdout or b"").decode("utf-8", "replace").splitlines()[0].strip()
        say(OK, "本地 OCR tesseract", v)
    except Exception as e:
        say(BAD, "本地 OCR tesseract", str(e)[:60])
    langs = subprocess.run([str(exe), "--list-langs"], capture_output=True, timeout=20)
    # TWO traps here, both hit on 2026-10-02:
    #   (a) tesseract prints the list on STDERR, not stdout;
    #   (b) language codes contain underscores (chi_sim / chi_tra), so filtering with
    #       str.isalpha() silently drops exactly the Chinese packs we care about.
    text = ((langs.stdout or b"") + (langs.stderr or b"")).decode("utf-8", "replace")
    got = [l.strip() for l in text.splitlines()
           if l.strip() and l.strip().replace("_", "").isalnum()]
    need = {"chi_sim", "jpn", "eng"}
    miss = need - set(got)
    say(OK if not miss else WARN, "  └ 语言包",
        "有 %s%s" % (", ".join(sorted(got)) or "（读不到列表）",
                     "" if not miss else "  缺 %s" % ", ".join(sorted(miss))))


def check_keys():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            for name in ("DASHSCOPE_API_KEY", "ZAI_API_KEY"):
                try:
                    v, _ = winreg.QueryValueEx(k, name)
                    say(OK, "环境变量 %s" % name, "已设（%d 字符，值不显示）" % len(str(v).strip()))
                except FileNotFoundError:
                    say(WARN, "环境变量 %s" % name, "未设 —— 对应后端会被跳过")
    except Exception as e:
        say(WARN, "读用户环境变量", str(e)[:60])


def check_ollama():
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=8) as r:
            j = json.loads(r.read().decode())
        names = [m.get("name") for m in j.get("models", [])]
        if names:
            say(OK, "本地 Ollama 服务", "%d 个模型：%s" % (len(names), ", ".join(names[:3])))
        else:
            say(WARN, "本地 Ollama 服务", "服务在，但没有模型（ollama pull qwen2.5vl:7b）")
    except Exception as e:
        say(WARN, "本地 Ollama 服务", "连不上：%s" % str(e)[:50])


def check_truthset():
    p = HERE / "testset" / "truth.json"
    if not p.exists():
        say(BAD, "真值测试集", "缺 %s" % p); return
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        say(BAD, "真值测试集", "解析失败：%s" % str(e)[:60]); return
    n = sum(len(i["facts"]) for i in d["images"])
    no_short = [f["id"] for i in d["images"] for f in i["facts"] if not f.get("short")]
    say(OK, "真值测试集", "%d 图 / %d 条事实" % (len(d["images"]), n))
    if no_short:
        say(WARN, "  └ short 字段缺失", "%d 条（机器打分要用）：%s" % (len(no_short), ", ".join(no_short[:5])))
    else:
        say(OK, "  └ short 字段齐全", "机器打分可用")


def check_tools():
    for name in ("eyeprobe.py", "vrecheck.py", "vscore.py", "eye.py", "使用判据.md"):
        p = HERE / name
        say(OK if p.exists() else WARN, "工具 %s" % name,
            "%.1f KB" % (p.stat().st_size / 1024) if p.exists() else "缺失")


def check_live(models):
    """Actually call each configured backend once (costs quota)."""
    from eyeprobe import user_env, call, img_b64, BACKENDS
    # 探针图放临时目录并按需生成（不依赖本机固定路径）
    probe = Path(tempfile.gettempdir()) / "dsh-doctor-probe.png"
    if not probe.exists():
        # 生成一张探针小图，保证任何机器上都能实调
        from PIL import Image, ImageDraw
        probe.parent.mkdir(parents=True, exist_ok=True)
        im = Image.new("RGB", (420, 120), "white")
        ImageDraw.Draw(im).text((10, 45), "DOCTOR PROBE 12345", fill="black")
        im.save(probe)
    b64, _ = img_b64(str(probe))
    for m in models:
        b = BACKENDS.get(m)
        if not b:
            say(WARN, "实调 %s" % m, "未知后端"); continue
        if b.get("keyenv") and not user_env(b["keyenv"]):
            say(WARN, "实调 %s" % m, "跳过（无 Key）"); continue
        ok, res, secs = call(m, b64, "只回答图中的数字。")
        if ok:
            say(OK, "实调 %s" % m, "%.1fs -> %s" % (secs, res[0][:40].replace("\n", " ")))
        else:
            say(BAD, "实调 %s" % m, str(res)[:60])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="额外各后端实调一次（消耗额度）")
    ap.add_argument("--models", default="dashscope,zhipu,ollama")
    a = ap.parse_args()
    print("=" * 74)
    print("识图体系自检 doctor.py  |  %s" % ("含实调" if a.live else "静态检查"))
    print("=" * 74)
    check_python()
    check_tesseract()
    check_keys()
    check_ollama()
    check_truthset()
    check_tools()
    if a.live:
        print("-" * 74)
        check_live([m.strip() for m in a.models.split(",") if m.strip()])
    bad = sum(1 for t, _, _ in results if t == BAD)
    warn = sum(1 for t, _, _ in results if t == WARN)
    print("=" * 74)
    print("结论：%d 项 OK ／ %d 项 WARN ／ %d 项 FAIL" % (len(results) - bad - warn, warn, bad))
    print("判定：" + ("可以直接干活" if bad == 0 else "有硬故障，先修 FAIL 项"))


if __name__ == "__main__":
    main()
