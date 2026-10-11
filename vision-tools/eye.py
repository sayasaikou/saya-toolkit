#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eye.py -- 一条命令走完整个识图流程（工具箱的统一入口）

为什么存在：eyeprobe / vrecheck / vscore 是三个**孤立**的工具，每次都要先想起来、
再手动串起来。这个脚本把它们串成**一条流水线**，并且强制给每个结论打证据等级。

流程（每一步都可降级，失败就退到保守方案）：
  L0 算法证据   尺寸 / 主色 / 本地 tesseract      —— 不经模型，不会幻觉
  L1 多模型并排 百炼 + 智谱 + 本地 Ollama（自动跳过不可用的）
  L2 自动分歧   裁判输出结构化 JSON：一致 / 冲突 / 孤证
  L3 自动复检   对**每个冲突项**自动分块放大 → 重问 → 取色
  L4 汇总报告   每项标 [确证] / [推断] / [存疑]

证据等级判据（写死，不许含糊）：
  [确证] 多模型一致，或复检后收敛，或有算法证据支持
  [推断] 只有单一来源提到（可能是幻觉，也可能是别人漏了）
  [存疑] 模型之间矛盾，且复检后仍未收敛

用法：
  python eye.py <图片> [--preset outfit|ocr|diff] [--question "..."] [--out 报告.md]
  python eye.py <图片> --models dashscope,zhipu      # 指定模型
  python eye.py <图片> --no-recheck                   # 只做 L0~L2，不复检
"""

import argparse
import difflib
import json
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from eyeprobe import BACKENDS, PRESETS, user_env, call, img_b64, slice_vertical  # noqa: E402
from vrecheck import dominant_colors  # noqa: E402

try:
    from PIL import Image
except ImportError:
    print("need Pillow"); sys.exit(2)

TESSERACT = r"E:\dsh-ai\tesseract\tesseract.exe"


# ------------------------------------------------------- global time budget
# 2026-10-03: a 2700x5400 (14.6 MP) image ran 9 minutes and produced NOTHING. The cause
# was unbounded waiting, not wrong answers: 180s socket timeout x 3 attempts = 540s per
# backend, multiplied by every block and every recheck item. There was also no way to see
# WHERE it was stuck, so the only option was to kill it.
#
# The pipeline now carries a WALL-CLOCK budget. Every stage asks "is there time left?",
# and anything skipped is NAMED IN THE REPORT -- silently dropping work is more dangerous
# than reporting a wrong answer (the same rule that produced the "[存疑·未复检]" fix).
DEADLINE = None          # epoch seconds; None = unbounded
SKIPPED = "(未跑·超预算)"   # marker for work the budget cut; never counts as an answer


def set_budget(seconds):
    global DEADLINE
    DEADLINE = (time.time() + seconds) if seconds and seconds > 0 else None


def budget_left():
    return None if DEADLINE is None else DEADLINE - time.time()


def budget_ok(need=8.0):
    left = budget_left()
    return True if left is None else left >= need


def budget_tag():
    left = budget_left()
    return "不限时" if left is None else "剩 %.0fs" % max(0.0, left)


# ------------------------------------------------------------------ L0
def l0_evidence(path):
    """Deterministic evidence. No model involved, so it can never hallucinate."""
    ev = {}
    im = Image.open(path)
    ev["size"] = "%dx%d" % im.size
    ev["colors"] = dominant_colors(im, n=6)
    ev["ocr"] = ""
    ev["ocr_note"] = ""
    if Path(TESSERACT).exists():
        # tesseract on Windows can fail on non-ASCII paths -> work on an ASCII copy
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as t:
                tmp = t.name
            im.convert("RGB").save(tmp)
            r = subprocess.run([TESSERACT, tmp, "stdout", "-l", "chi_sim+jpn+eng"],
                               capture_output=True, timeout=60)
            txt = (r.stdout or b"").decode("utf-8", "replace").strip()
            ev["ocr"] = txt
            if not txt:
                ev["ocr_note"] = "tesseract 未读出文字（艺术字/无文字都可能）"
        except Exception as e:
            ev["ocr_note"] = "tesseract 失败：%s" % str(e)[:80]
        finally:
            if tmp and Path(tmp).exists():
                try: Path(tmp).unlink()
                except Exception: pass
    else:
        ev["ocr_note"] = "tesseract 不在 %s" % TESSERACT
    return ev


# ------------------------------------------------------------------ L1
def available_models(want):
    """Keep only backends that can actually run right now."""
    ok = []
    for m in want:
        b = BACKENDS.get(m)
        if not b:
            continue
        if b.get("keyenv") and not user_env(b["keyenv"]):
            print("  skip %-10s (env %s not set)" % (m, b["keyenv"]))
            continue
        ok.append(m)
    return ok


def ask_all(models, b64, question):
    out = {}
    for m in models:
        if not budget_ok(10):
            print("  %-10s SKIP  %s" % (m, budget_tag()))
            continue
        ok, res, secs = call(m, b64, question, deadline=DEADLINE)
        if ok:
            txt, usage = res
            out[m] = txt
            flag = ""
            if usage.get("repeat_collapsed"):
                flag = "   [!] 复读 x%d 已折叠" % usage["repeat_collapsed"]
            print("  %-10s %6.1fs  %d 字   [%s]%s" % (m, secs, len(txt), budget_tag(), flag))
        else:
            print("  %-10s FAIL %s" % (m, str(res)[:90]))
        time.sleep(0.8)
    return out


# ------------------------------------------------------------- L2-schema
# 结构化路径：让模型按固定 JSON 输出，分歧检测变成**程序化比对**。
# 为什么值得做：模型裁判是目前最大的误差源 —— 它会限流（实测 429 多次）、会波动
# （同一份答案判两次分数不同）、还会把"看不清"当成有效答案。固定 schema 把
# 「理解自由文本」这件难事，换成「比对字符串」这件确定的事。
NOCLUE = ("看不清", "无法", "不能确定", "不确定", "看不到", "无法判断", "无法看清",
          "can't tell", "cannot tell", "unclear", "not sure")

NEG_WORDS = ("不", "无", "没有", "没", "非", "未", "否", "并非")


def _norm_forms(s):
    """归一化 + 变体：返回 [带括号形态, 去括号形态]（去重）。

    为什么要两个都留着：实测两个方向都会翻车 ——
      · 去括号治好了「有宝石（位于领口正中）」被括号内容撑大字符集；
      · 但 `vest_buttons` 那条的关键信息「呈 2×2 矩阵」**恰好写在括号里**，
        一去就没了。⇒ 任何一层比对，**任一形态命中即算命中**。
    """
    nfkc = unicodedata.normalize('NFKC', str(s)).replace('×', 'x').replace('＊', '*')
    forms = []
    for v in (nfkc, re.sub(r'[（(][^（()）]*[)）]', '', nfkc)):
        v = re.sub(r'[\s，,。.、;；:：!！?？"“”\'‘’~～\-—_]', '', v).strip().lower()
        if v and v not in forms:
            forms.append(v)
    return forms


def norm_answer(s):
    """比对用的主形态：优先"去括号"版（它更干净）。
    只用于比对，报告里永远显示原文。否定词原样保留（不/无/没/非/未/否）。"""
    forms = _norm_forms(s)
    return forms[-1] if forms else ''


# 颜色词 —— 颜色是识图里问得最多、也最容易被"看着差不多"糊弄过去的属性。
# 归一到单字：深蓝/浅蓝/蓝色 -> 蓝。
# 「金属」必须先剔掉：实测模型答「银色**金属**圆扣」，那个"金"字会让
#    「金色搭扣」的对立检查失效，把说错的答案放过去。
_COLORS = ("深蓝", "浅蓝", "天蓝", "藏青", "宝蓝", "蓝色", "蓝",
           "白色", "白", "黑色", "黑", "金色", "金", "银色", "银",
           "红色", "红", "绿色", "绿", "粉色", "粉", "紫色", "紫",
           "黄色", "黄", "灰色", "灰", "棕色", "棕", "橙色", "橙")

# 虚词：`covers()` 判"字面全覆盖"时不算关键信息。
# 只收纯功能字（的/了/是/个/和…），**不收**「有 / 无 / 不 / 各 / 双 / 两 / 上 / 下 / 中」
# 这类会改变语义的字 —— 它们在是非题、数量题里是实打实的答案。
_STOPWORDS = set("的了是个和与及等这那而且也都还就之其")


def _colors(s):
    t = str(s).replace("金属", "").replace("金属色", "")
    out = set()
    for c in _COLORS:
        if c in t:
            # 取的是"去掉『色』字后的最后一个字" —— 早先写成 c[-1]，于是
            # 「金色」「银色」「白色」统统归一到「色」，把"金色 vs 银色"这种
            # 硬对立直接抹平（单元测试当场抓出来的）。
            out.add(c.replace("色", "")[-1])
    return out


def covers(short, long):
    """`long` 是否**字面全覆盖**了 `short`（只修"差标点/括号/全角"这类假错）。
    阈值故意卡在**全部命中**：少一个字就不算。理由 —— 放宽到"覆盖 70-90%"会把真正的
    错误也放过：实测 `shoes` 那条模型把「金色搭扣」说成「银色金属圆扣」，字符覆盖仍有
    9/10，只有把「金」这一个字逮住才能判它错。**打分器宁可偏严**：高估模型能力会让
    本鱼在真实交付里翻车，低估只会让它多查一遍。

    但**虚词不算关键信息**（2026-10-03 补）：真值「喷水的小鲸鱼」，模型答
    「有喷水孔与微笑表情的小鲸鱼」—— 只因为那一句里没有「的」字就被判错，纯属冤枉。
    实词（尤其是颜色、数量、部位名）一个都不能少，虚词可以少。
    """
    for s in _norm_forms(short):
        for l in _norm_forms(long):
            if len(s) > len(l) + 2:          # 只认"更详细"这个方向
                continue
            ss = {ch for ch in s if ch not in _STOPWORDS}
            if ss and ss <= set(l):
                return True
    return False


def has_neg(s):
    return any(n in str(s) for n in NEG_WORDS)


# 极短的是/否类答案必须按"极性"归一化 —— 否则「无」vs「没有」、「否」vs「不露肩」
# 会被当成两个不同答案。实测后果：两条本来答对的项被算成答错，分数被严重低估
# （报 28.6%，人工核对其实是 6/7）。
_SYN = {"否": "NEG", "不是": "NEG", "没有": "NEG", "无": "NEG", "不": "NEG", "未": "NEG",
        "是": "POS", "有": "POS", "对": "POS", "存在": "POS", "是的": "POS"}


def polarity(s):
    """'NEG' / 'POS' / None —— 用于把「否」和「不露肩」认成同一类答案。"""
    t = str(s).strip().rstrip("。.!！")
    if t in _SYN:
        return _SYN[t]
    if has_neg(t):
        return "NEG"
    return None


def relation(a, b):
    """三分类，比"像不像"更贴近真实语义关系：

    same       两两相似（措辞差异无所谓）
    compatible 一方是另一方的子集 —— **一详一略，说的是同一件事**，不算矛盾
               （实测：'有口袋，口袋里有笔' vs '有口袋，口袋上有鲸鱼图案，里面插着多支笔'）
    conflict   真矛盾 —— 包括**一方否定一方肯定**这种最典型的冲突
               （实测：'露肩' vs '不露肩'，字符层面是子集关系，但语义相反；
                所以否定词必须先拦一道，否则字符子集判断会把矛盾当成兼容）
    """
    a, b = str(a).strip(), str(b).strip()
    # 否定检查必须排在 similar() 前面：'露肩' 是 '不露肩' 的子串，containment
    # 会先命中并把它判成"一致" —— 而这两个答案语义完全相反。
    if has_neg(a) != has_neg(b):
        return "conflict"
    # 颜色对立同样要前置（2026-10-03 加的）：实测「深蓝色玛丽珍鞋（带扣为银色金属圆扣）」
    # vs「深蓝玛丽珍鞋，金色搭扣」—— 去掉括号后两者字符集 Jaccard 高达 0.70，被
    # similar() 判成 same，把"金色说成银色"这个错误整个放过去了。
    #
    # 判据是"**各有一个对方没有的颜色**"（真撞车），而不是"没有共同颜色"：
    #   · 目标案例    a={蓝,银} b={蓝,金} —— 双方各有独有 ⇒ 冲突 是
    #   · 一详一略    a={蓝,白} b={白}    —— 只有一方有独有 ⇒ 是补充信息，不算冲突 是
    #   （早先只判"交集为空"，于是共享的"蓝"把"银 vs 金"整个遮住了。）
    ca, cb = _colors(a), _colors(b)
    if ca and cb and (not (ca & cb) or ((ca - cb) and (cb - ca))):
        return "conflict"
    if similar(a, b):
        return "same"
    # 子集判断走归一化后的文本（去括号/全角/标点），否则
    # 「有宝石（位于领口）」和「有宝石」会因为括号内容判成两个集合。
    na, nb = norm_answer(a), norm_answer(b)
    sa, sb = set(na), set(nb)
    if sa and sb and (sa <= sb or sb <= sa):
        return "compatible"
    if covers(a, b) or covers(b, a):
        return "compatible"
    return "conflict"



def build_schema_prompt(facts):
    lines = ["请逐项回答下面的问题。**只输出一个 JSON 对象**，不要解释、不要代码块标记。",
             '格式：{"<条目id>": "<你的答案>"}，例如 {"collar": "立领"}。',
             "看不清的项就把值写成「看不清」，不要猜。",
             "",
             "四条硬要求（2026-10-02 被饲主逐条纠正后加的）：",
             "1) **涉及左右必须写清参照系** —— 「画面左侧/右侧」跟「角色自身的左手/右手」"
             "是相反的（人物面向镜头时尤其容易搞反）。请写成「角色右手拿…」这种带参照的形式。",
             "2) **非人类的特征用准确的词** —— 看到鳍、鳍状耳、角、尾这类结构时，"
             "不要拿最接近的常见动物部位（耳／猫耳）顶替；拿不准就描述你看到的形状。",
             "3) **专业术语照用，但后面用括号补一句白话**。饲主原话：「术语看不懂是我的问题，"
             "对 ai 来说肯定越准确越好啊」⇒ **不许为了好懂而降级准确性**。"
             "正确写法：「门襟（衣服前面那条从上到下的开口边）有一圈白色荷叶边（波浪形的花边）」。"
             "反过来，**也不许说没信息量的话** —— 像「四角略圆」这种，要么说清具体形状，要么别说。",
             "4) **部位名词要补一句「它指哪里」**，别只丢一个名词。写「领子」「领口」时补上位置，"
             "例如「领子开口处（脖子前面领子中间那段）」，否则读的人分不清是哪个部位。",
             "",
             "要回答的条目："]
    for f in facts:
        lines.append("- %s：%s" % (f["id"], f["q"]))
    return "\n".join(lines)


def parse_schema_json(text, facts):
    """Tolerant parse: strip fences, take outermost {...}, keep only known ids."""
    if not text:
        return None
    t = text.strip()
    if t.startswith("```"):
        parts = t.split("```")
        if len(parts) >= 2:
            t = parts[1]
            if t.lower().lstrip().startswith("json"):
                t = t.lstrip()[4:]
    s, e = t.find("{"), t.rfind("}")
    if s < 0 or e < 0:
        return None
    try:
        obj = json.loads(t[s:e + 1])
    except Exception:
        return None
    known = {f["id"] for f in facts}
    out = {}
    for k, v in obj.items():
        k2 = str(k).strip().strip('"')
        if k2 in known:
            out[k2] = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return out or None


def is_noclue(v):
    """这条回答算不算"没答上来"。

    **不能只看"含不含这些词"**（2026-10-03 实测踩出来的，代价不小）：
    dashscope 答「右手抬起，五指微张，指尖朝前，呈轻盈抓取或施法状；左手未完全显示，
    **无法**判断具体姿态」—— 主体答得清清楚楚，只因结尾补了一句"无法判断左手"，
    整条就被判成"没看清"。后果是连锁的：`_real()` 把它滤掉 → `info()` 归零 →
    **轮 2 的象限复检压根不触发**；L2 的分歧检测也会把这条当成"该模型没答"。

    判据改成：**短回答看词，长回答看这些词是不是主体**。
    """
    s = str(v or "").strip()
    if not s:
        return True
    hits = [n for n in NOCLUE if n in s]
    if not hits:
        return False
    if len(s) <= 20:                       # 短回答里出现 = 真的没看清
        return True
    stripped = s
    for h in hits:                         # 长回答：剥掉这些词，看还剩多少实质内容
        stripped = stripped.replace(h, "")
    return len(stripped) < 12


def similar(a, b, thr=0.72):
    """Cheap semantic-ish equality.
    Three tiers: exact / containment / char-set Jaccard / char-level ratio.
    The Jaccard tier exists because Chinese answers differ mostly by modifiers --
    "金色藤蔓纹样" vs "金色藤蔓纹" is the SAME answer, but SequenceMatcher alone
    scored them apart and the strict scorer called it wrong.

    2026-10-03: every tier below now runs on `norm_answer()` output (NFKC + 去括号 +
    去标点). Before that, "四颗，2×2" vs "四颗，2x2" failed ALL three tiers and was
    reported as a model error -- it was purely a full-width multiplication sign."""
    a, b = str(a).strip(), str(b).strip()
    if a == b:
        return True
    na, nb = norm_answer(a), norm_answer(b)
    if na and na == nb:
        return True
    pa, pb = polarity(a), polarity(b)
    if pa and pb and pa == pb:
        return True                      # 「否」vs「不露肩」、「无」vs「没有」
    if na and nb and (na in nb or nb in na):
        return True
    sa, sb = set(na), set(nb)
    if sa and sb:
        j = len(sa & sb) / float(len(sa | sb))
        if j >= 0.62:
            return True
    return difflib.SequenceMatcher(None, na, nb).ratio() >= thr


def ask_structured(model, b64, facts, retries=2):
    prompt = build_schema_prompt(facts)
    # 项数多时预算要放大，否则 JSON 会被截断、整张卡作废
    budget = 1600 if len(facts) <= 12 else (3200 if len(facts) <= 30 else 4800)
    for _ in range(retries + 1):
        if not budget_ok(10):
            return None, "global budget exhausted"
        ok, res, secs = call(model, b64, prompt, max_tokens=budget, deadline=DEADLINE)
        if not ok:
            return None, str(res)[:90]
        got = parse_schema_json(res[0], facts)
        if got:
            return got, "%.1fs" % secs
        time.sleep(1)
    return None, "JSON parse failed"


def compare_structured(per_model, facts):
    """Program-driven dispute detection -- no judge model involved.
    Returns the SAME shape the judge path returns, so report code stays shared."""
    q = {f["id"]: f["q"] for f in facts}
    agreed, conflicts, single = [], [], []
    for f in facts:
        fid = f["id"]
        vals = {}
        for m, got in per_model.items():
            if not got:
                continue
            v = got.get(fid)
            if v and not is_noclue(v):
                vals[m] = str(v).strip()
        if not vals:
            continue
        if len(vals) == 1:
            who = list(vals)[0]
            single.append({"item": q[fid], "who": who, "value": vals[who]})
            continue
        # 两两判关系：只要有一对 conflict 就是冲突项；若只有 compatible，那只是
        # "一方说得更详细"，仍然归入确证但标注出来。
        ms = list(vals)
        worst = "same"
        for i in range(len(ms)):
            for j in range(i + 1, len(ms)):
                r = relation(vals[ms[i]], vals[ms[j]])
                if r == "conflict":
                    worst = "conflict"
                    break
                if r == "compatible":
                    worst = "compatible"
            if worst == "conflict":
                break
        if worst == "conflict":
            conflicts.append({"item": q[fid], "claims": dict(vals)})
        elif worst == "compatible":
            rep = max(vals.values(), key=len)
            agreed.append({"item": q[fid], "value": rep,
                           "support": "%d/%d（一方更详细）" % (len(vals), len(per_model))})
        else:
            agreed.append({"item": q[fid], "value": list(vals.values())[0],
                           "support": "%d/%d" % (len(vals), len(per_model))})
    return {"agreed": agreed, "conflicts": conflicts, "single_source": single}


def score_structured(per_model, facts):
    """Score each model against the truth stored in the same facts.
    通用卡（没有 truth/short）不参与打分 —— 它只负责描述。"""
    if not any(f.get("truth") or f.get("short") for f in facts):
        return None
    out = {}
    for m, got in per_model.items():
        if not got:
            out[m] = None
            continue
        hit = wrong = miss = 0
        detail = []
        for f in facts:
            v = got.get(f["id"])
            ref = f.get("short") or f["truth"]      # machine-scoring reference
            if is_noclue(v):
                miss += 1
                detail.append((f["id"], "未答/看不清", ref))
            elif relation(v, ref) in ("same", "compatible"):
                # 用 relation 而不是 similar："更详细"的答案也算命中。
                # 只判 similar 会把「有口袋，口袋上有鲸鱼图案，里面插着多支笔」判成
                # 答错（真值 short 只有「有口袋，插着笔」）—— 实测低估了 2 项。
                hit += 1
            else:
                wrong += 1
                detail.append((f["id"], str(v), ref))
        total = len(facts)
        out[m] = {"hit": hit, "wrong": wrong, "miss": miss, "total": total,
                  "pct": round(100.0 * hit / total, 1) if total else 0.0, "detail": detail}
    return out


# ------------------------------------------------------------------ L2
DISPUTE_PROMPT = """下面是多个视觉模型对同一张图（或同一组问题）的独立回答。

请只做一件事：把它们归成三类，并**只输出 JSON**（不要解释、不要代码块标记）：

{
  "agreed":        [{"item": "简短条目名", "value": "它们一致的结论", "support": "3/3"}],
  "conflicts":     [{"item": "简短条目名", "claims": {"模型名": "它说了什么", "另一个模型": "它说了什么"}}],
  "single_source": [{"item": "简短条目名", "who": "模型名", "value": "只有它提到的内容"}]
}

规则：
- 只有**实质冲突**才进 conflicts（说法互相矛盾）；措辞不同但意思相同算 agreed。
- 某个模型完全没提的项，不要当成冲突。
- 条目名要短（4-10 字），方便后面逐条复检。

各模型回答：
%s
"""


def detect_disputes(judge, answers):
    body = []
    for m, txt in answers.items():
        body.append("### 模型：%s\n%s" % (m, txt))
    prompt = DISPUTE_PROMPT % "\n\n".join(body)
    b = BACKENDS[judge]
    key = user_env(b["keyenv"])
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {"model": b["model"], "messages": [{"role": "user", "content": prompt}],
               "max_tokens": 2000, "temperature": 0}
    import urllib.request
    # 这里的 240s 是另一处黑洞（裁判自己也会挂住）—— 同样受全局预算约束
    to = 240
    left = budget_left()
    if left is not None:
        if left <= 5:
            raise ValueError("global budget exhausted before dispute detection")
        to = max(5, min(240, int(left)))
    req = urllib.request.Request(b["url"], data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=to) as r:
        raw = json.loads(r.read().decode())["choices"][0]["message"]["content"].strip()
    t = raw
    if t.startswith("```"):
        t = t.split("```")[1]
        if t.lower().startswith("json"):
            t = t[4:]
    s, e = t.find("{"), t.rfind("}")
    if s < 0 or e < 0:
        raise ValueError("judge returned no JSON object: %s" % raw[:160])
    return json.loads(t[s:e + 1])


# ------------------------------------------------------------------ L3
def _ask_regions(regions, path, models, q, tag):
    """regions: [(label, (x1,y1,x2,y2)), ...] -> 逐块放大提问 + 取主色（算法证据）

    预算守护：一块要跑 len(models) 次调用，进块之前先问一次"还有时间吗"。超预算的块
    标成 SKIPPED 而不是"失败" —— 两者在报告里的含义完全不同。
    """
    out = []
    for label, box in regions:
        if not budget_ok(12):
            print("      · %s SKIP（%s）" % (label, budget_tag()))
            out.append({"band": label, "answers": {}, "colors": [], "box": list(box),
                        "zoom": 0, "skipped": SKIPPED})
            continue
        crop = Image.open(path).crop(box)
        w, h = crop.size
        # 按**长边**定缩放，而且允许放大。
        # 早先写的是 `int(1600 / 宽)` —— 横带保留整幅宽度时（2346px）永远算出 1，
        # 所谓"放大复检"在高分辨率图上从来没生效过（2026-10-03 实测抓出：
        # 六个复检块里五个答"看不清"）。目标 2000 与 img_b64 的 max_side 对齐，
        # 送到模型手里不会再被缩一次。
        longest = max(w, h) or 1
        sc = 1.0 if longest >= 2000 else min(3.0, 2000.0 / longest)
        big = crop.resize((max(1, int(w * sc)), max(1, int(h * sc))), Image.LANCZOS)
        tmp = Path(tempfile.gettempdir()) / ("eye_%s_%d.png" % (tag, abs(hash(label)) % 99999))
        big.save(tmp)
        try:
            b64, _ = img_b64(str(tmp))
            answers = {}
            for m in models:
                if not budget_ok(10):
                    answers[m] = SKIPPED
                    continue
                ok, res, secs = call(m, b64, q, deadline=DEADLINE)
                answers[m] = res[0] if ok else "(失败)"
                time.sleep(0.5)
            cols = dominant_colors(crop, n=4)
        finally:
            try: tmp.unlink()
            except Exception: pass
        out.append({"band": label, "answers": answers, "colors": cols,
                    "box": list(box), "zoom": sc})
    return out


def _real(vals):
    """只保留"真的作答了"的值 —— 调用失败、以及被预算跳过的块，都不算答案。

    这条过滤是整套流水线的命门：早期版本把"过滤后只剩一个值"当成一致，于是一个
    孤零零的「看不清」被误判成"多模型一致"，把 5 个分歧项错误升格成确证。
    跳过（SKIPPED）与「看不清」必须一视同仁地排除。
    """
    return [v.strip() for v in vals
            if v and v != "(失败)" and v != SKIPPED and not is_noclue(v)]


def _converged(per_band):
    """>=2 个模型在**同一块**给出**实质相同且非「看不清」**的答案，才算收敛。

    两处都踩过坑：
      ① 早期版本只是"去重后剩一个" —— 过滤掉失败项后，一个孤零零的「看不清」被当成
         一致，把分歧项错误升格成确证。那是整套流水线最该防的失败模式。
      ② 后来改成了精确相等（set 去重），又太严：「右侧」vs「右」其实是同一答案，
         却被判成不收敛。现在统一走 similar()（精确/包含/字符集/相似度四档）。
    """
    for b in per_band:
        vals = _real(b["answers"].values())
        if len(vals) < 2:
            continue
        ok = True
        for i in range(len(vals)):
            for j in range(i + 1, len(vals)):
                if relation(vals[i], vals[j]) == "conflict":
                    ok = False
                    break
            if not ok:
                break
        if ok:
            return True
    return False


def _thirds(box):
    x1, y1, x2, y2 = box
    step = (y2 - y1) / 3.0
    pad = int(step * 0.04)
    return [(x1, max(y1, int(y1 + i * step) - pad), x2,
             min(y2, int(y1 + (i + 1) * step) + pad)) for i in range(3)]


# ------------------------------------------------------- L3 zone targeting
# 2026-10-03: 复检原来是"把整图切成上/中/下"。对**头面部**的问题（领型/呆毛/发饰）
# 那是灾难 —— 整个头只落在最上面那块的一小部分里，等于没放大；放大倍数全被浪费在
# 无关的裙摆和背景上。实测后果：ref-a 14 项全部判成冲突，报告失去分辨力。
# 现在先按问题里的部位词，把**真正相关的那条横带**裁出来，再在带内切三段。
_ZONES = (
    # (关键词, 纵向窗口 按图高比例)
    (("领", "领口", "领型", "颈", "头", "发", "呆毛", "刘海", "耳", "眼", "脸",
      "帽", "头饰", "蝴蝶结", "表情", "肤色", "鳍"), (0.00, 0.45)),
    (("肩", "胸", "胸针", "袖", "袖口", "手", "手指", "臂", "腕", "腰", "腰封",
      "扣", "纽扣", "扣子", "衬衫", "马甲", "背心", "围裙", "口袋", "笔",
      "记事本", "花纹", "图案", "纹路", "装饰"), (0.15, 0.75)),
    (("裙", "裙摆", "开衩", "衬裙", "袜", "鞋", "腿", "脚", "尾", "鲸尾",
      "玛丽珍", "脚跟"), (0.55, 1.00)),
)


def zone_for(item):
    """按问题里的部位词挑纵向窗口；认不出来返回 None（退回整图切三段）。"""
    t = str(item)
    for kws, win in _ZONES:
        if any(k in t for k in kws):
            return win
    return None


def _quadrants(box):
    """把一个框切成 2x2 四个象限（带少量重叠，免得边界上的东西被切两半）。

    为什么不是横着切三条（第一版）：正方形框横切出来的是 1534x511 的**长条**，
    宽度一点没减，放大倍数只有 1.3x；而象限是 767x767 —— 宽度减半、放大到 2.6x。
    对「脸颊印记」这种小目标，问题出在**水平方向没聚焦**，横切根本没碰到它。
    """
    x1, y1, x2, y2 = box
    mx, my = (x1 + x2) // 2, (y1 + y2) // 2
    pad_x, pad_y = int((x2 - x1) * 0.05), int((y2 - y1) * 0.05)
    return [
        (x1, y1, min(x2, mx + pad_x), min(y2, my + pad_y)),
        (max(x1, mx - pad_x), y1, x2, min(y2, my + pad_y)),
        (x1, max(y1, my - pad_y), min(x2, mx + pad_x), y2),
        (max(x1, mx - pad_x), max(y1, my - pad_y), x2, y2),
    ]


def _zone_boxes(path, win):
    """返回 `(boxes, labels)`。

    认得出部位 → **一个以中轴为中心的正方形框**（整块送去问，而不是再切碎）。
    认不出部位、或窗口小到没意义 → 整图的上下三等分（老行为）。

    为什么不是"整幅宽度的一条横带"（第一版就是那么写的，实测被打回来）：
    立绘里人物只占中间一条，保留整幅 2346px 宽之后，`img_b64` 按长边缩放会**把人缩得更小**
    —— 六块复检里五块答「看不清」，同一模型还在两块上给出互相矛盾的形状（黑桃／梅花）。
    正方形框能让同样的像素预算全部落在人物身上。
    """
    W, H = Image.open(path).size
    if win:
        top, bot = int(H * win[0]), int(H * win[1])
        if bot - top >= 60:
            half = int((bot - top) * 0.5)
            cx = W // 2
            x1, x2 = max(0, cx - half), min(W, cx + half)
            if x2 - x1 < 200:                 # 太窄就退回整幅宽
                x1, x2 = 0, W
            return [(x1, top, x2, bot)], ["部位整块"]
    return _thirds((0, 0, W, H)), ["上部", "中部", "下部"]


def recheck(item, claims, path, models, judge, refine=True):
    """自适应两轮复检：
       轮 1 - **按部位裁出相关横带**（认不出部位就整图），切三段放大，逐块重问
       轮 2 - 若没收敛，挑"给出实质答案且最长"的那一段，再切三份（放大到 9 倍）
       每块都附算法取色（不经模型）。"""
    W, H = Image.open(path).size
    tag = "c%d" % (abs(hash(item)) % 9999)
    zone = zone_for(item)
    boxes, labels = _zone_boxes(path, zone)
    if zone:
        q = ("这张图是角色某个部位的**局部放大**。请回答：%s "
             "直接给出你的判断；确实看不清就写「看不清」，不要猜。" % item)
    else:
        q = ("只看这张局部的图：%s。请直接回答你的判断；确实看不清就写「看不清」，不要猜。"
             % item)

    bands = _ask_regions(list(zip(labels, boxes)), path, models, q, tag)
    conv = _converged(bands)
    refined = []

    if refine and not conv:
        def info(b):
            return max((len(v) for v in _real(b["answers"].values())), default=0)
        pick = max(range(len(bands)), key=lambda i: info(bands[i]))
        # 第二轮很贵（再切 3 块 x len(models) 次调用），没时间就别开
        if info(bands[pick]) > 0 and budget_ok(24):
            base = bands[pick]["band"]
            subs = _quadrants(bands[pick]["box"])
            sub_labels = [base + s for s in ("左上", "右上", "左下", "右下")]
            refined = _ask_regions(list(zip(sub_labels, subs)),
                                   path, models, q, tag + "f%d" % pick)
            conv = _converged(refined) or conv

    return {"item": item, "claims": claims, "bands": bands + refined,
            "converged": conv, "refined": len(refined) > 0,
            "zone": (list(zone) if zone else None)}


def _band_box(path, idx, n=3):
    w, h = Image.open(path).size
    step = h / n
    pad = int(step * 0.04)
    top = max(0, int(idx * step) - pad)
    bot = min(h, int((idx + 1) * step) + pad)
    return (0, top, w, bot)



# ------------------------------------------------------------------ L4
def grade(item, value, support, conflicts=None, rechecked=None):
    if conflicts:
        if rechecked and rechecked.get("converged"):
            return "确证"
        return "存疑"
    if support and "/" in str(support):
        try:
            a, b = [int(x) for x in str(support).split("/")[:2]]
            if b and a == b:
                return "确证"
        except Exception:
            pass
        if b and a > 1:
            return "确证"
    return "推断"


def main():
    # Windows 控制台默认是 GBK 码页：中文输出会乱码，emoji 会直接 UnicodeEncodeError
    # 把整个进程打死（2026-10-03 实测：一个 U+26A0 让 14.6MP 那张图在第 3 秒就崩了，
    # 看起来却像"脚本跑不动大图"）。统一成 UTF-8 + replace，任何字符都打得出来。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("-q", "--question", default=None)
    ap.add_argument("--preset", choices=sorted(PRESETS.keys()), default=None)
    ap.add_argument("--models", default="dashscope,zhipu,ollama",
                    help="默认百炼+本地。**zhipu 2026-10-03 降级为可选**：实测同一张图三次分别"
                         "返回 301 / 0 / 141 字（一次直接空响应）、耗时 37~75s，在并排里更像"
                         "噪声源。要它上就显式写 --models dashscope,zhipu,ollama")
    ap.add_argument("--out", default="")
    ap.add_argument("--no-recheck", action="store_true")
    ap.add_argument("--recheck-models", default="dashscope,zhipu,ollama",
                    help="复检用的模型（默认百炼+本地：一个稳、一个无限次且不 429）")
    ap.add_argument("--schema", default="",
                    help="结构化模式：用真值集里的图片 id（如 ref-a / cute-01）当答题卡，"
                         "模型按固定 JSON 回答 -> 程序比对 + 自动对真值打分，全程不用裁判")
    ap.add_argument("--jobs", type=int, default=1, help="并发数（默认 1；>1 更快但更易触发限流）")
    ap.add_argument("--max-recheck", type=int, default=4,
                    help="最多复检几个冲突项（默认 4；每项两轮×三块×每模型一次调用，很费）")
    ap.add_argument("--budget", type=int, default=420,
                    help="整条流水线的总时间预算（秒，默认 420；0 = 不限）。超预算的步骤会被"
                         "跳过并在报告里点名 —— 宁可少查几项，也不要跑到一半被掐断")
    ap.add_argument("--max-side", default="2000",
                    help="入口降采样：长边上限像素（默认 2000；0 = 不缩）。实测 2700x5400 "
                         "这种长图不缩会显著拖慢每个后端 —— 要看细节请裁块放大，别指望整图")
    a = ap.parse_args()

    try:
        max_side = int(a.max_side)
    except ValueError:
        max_side = 2000
    t_start = time.time()
    set_budget(a.budget)

    src = Path(a.image)
    if not src.exists():
        print("image not found: %s" % src); sys.exit(2)
    q = a.question or (PRESETS[a.preset] if a.preset else PRESETS["diff"])

    schema_facts = []
    if a.schema:
        cands = []
        # (a) 通用卡（schemas/*.json，通常没有真值，只出描述）
        schema_dir = HERE / "schemas"
        if schema_dir.exists():
            for p in sorted(schema_dir.glob("*.json")):
                try:
                    cands += json.loads(p.read_text(encoding="utf-8")).get("images", [])
                except Exception as e:
                    print("  跳过 %s：%s" % (p.name, str(e)[:60]))
        # (b) 真值集里的卡（带真值 -> 能打分）
        tp = HERE / "testset" / "truth.json"
        if tp.exists():
            try:
                cands += json.loads(tp.read_text(encoding="utf-8")).get("images", [])
            except Exception as e:
                print("truth set unreadable: %s" % e)
        im = next((x for x in cands if x["id"] == a.schema), None)
        if not im:
            print("schema id not found: %s" % a.schema)
            print("available: %s" % ", ".join(x["id"] for x in cands))
            sys.exit(2)
        schema_facts = im["facts"]
        has_truth = any(f.get("short") or f.get("truth") for f in schema_facts)
        q = "（schema 模式）%s —— %d 项%s" % (
            im["label"], len(schema_facts),
            "" if has_truth else "（通用卡：无真值，只出描述不打分）")

    print("=" * 78)
    print("eye.py  |  %s" % src.name)
    print("问题   | %s" % q[:100].replace("\n", " "))
    print("预算   | %s（--budget %d 秒，0 = 不限）"
          % ("不限时" if not a.budget else "%d 秒" % a.budget, a.budget))
    print("=" * 78)

    # ---- L0
    print("\n[L0] 算法证据（不经模型）")
    ev = l0_evidence(str(src))
    print("  尺寸   : %s" % ev["size"])
    print("  主色   : %s" % ", ".join("%s %s%%" % c for c in ev["colors"][:4]))
    print("  本地OCR: %s" % (ev["ocr"][:70].replace("\n", " / ") or ev["ocr_note"]))

    # ---- L1
    print("\n[L1] 多模型并排")
    models = available_models([m.strip() for m in a.models.split(",") if m.strip()])
    if not models:
        print("没有可用模型"); sys.exit(2)
    orig = Image.open(str(src)).size
    b64, sent = img_b64(str(src), max_side=(max_side if max_side > 0 else 10 ** 9))
    if sent != orig:
        print("  降采样 : %dx%d -> %dx%d（--max-side %d）"
              % (orig[0], orig[1], sent[0], sent[1], max_side))
        print("           [!] 整图缩过会丢细节 —— 要抠小目标请先裁块（vision_crop / vrecheck）")

    scores, judge = None, None
    if schema_facts:
        print("  (schema 模式：模型按固定 JSON 回答，分歧检测不用裁判)")
        per_model, timing = {}, {}
        if a.jobs > 1:
            with ThreadPoolExecutor(max_workers=a.jobs) as ex:
                futs = {m: ex.submit(ask_structured, m, b64, schema_facts) for m in models}
                for m, fu in futs.items():
                    got, note = fu.result()
                    per_model[m], timing[m] = got, note
        else:
            for m in models:
                got, note = ask_structured(m, b64, schema_facts)
                per_model[m], timing[m] = got, note
                time.sleep(0.6)
        for m in models:
            got = per_model.get(m)
            print("  %-10s %-24s %s" % (m, timing.get(m, ""),
                  ("%d/%d 项" % (len(got), len(schema_facts))) if got else "无有效 JSON"))
        answers = {m: json.dumps(g, ensure_ascii=False, indent=1)
                   for m, g in per_model.items() if g}
        if not answers:
            print("所有模型都没给出可解析的 JSON"); sys.exit(2)
        print("\n[L2] 程序化分歧检测（无裁判）")
        dis = compare_structured(per_model, schema_facts)
        scores = score_structured(per_model, schema_facts)
    else:
        answers = ask_all(models, b64, q)
        if len(answers) < 1:
            print("所有模型都失败了"); sys.exit(2)
        print("\n[L2] 自动分歧检测（模型裁判）")
        judge = next((m for m in ("dashscope", "zhipu") if m in answers), list(answers)[0])
        try:
            dis = detect_disputes(judge, answers)
        except Exception as e:
            print("  分歧检测失败：%s" % str(e)[:120])
            dis = {"agreed": [], "conflicts": [], "single_source": []}
    # ---- 程序兜底（2026-10-10 加，起因：实测报告打出 [确证]（1/1））
    # 裁判模型（judge path）没有"单源"这个概念 ⇒ 会把只有一个模型提到的条目
    # 塞进 agreed 桶，报告再按 support 打成 [确证] —— 而且汇总里还显示"孤证 0 项"。
    # 这里按 support 把 1/N 的条目一律降级成孤证：单源不算确证。
    # 单源时「一致」本身就是伪命题：实测只给一个模型（--models dashscope），
    # 裁判却报出"模型B / 模型C"并打成 3/3 —— 来源是编的。
    # ⇒ 真实来源 < 2 时，agreed 一律降级为孤证。
    if len(answers) < 2:
        for _it in dis.get("agreed", []):
            dis.setdefault("single_source", []).append({
                "item": _it.get("item", "?"),
                "who": "（只有 1 个真实来源，裁判报的多源是编的）",
                "value": _it.get("value", "")})
        if dis.get("agreed"):
            print("  [兜底] 本次只有 1 个模型答题：所有「一致」降级为「孤证」（单源不能算确证）")
        dis["agreed"] = []
        # 冲突同样需要 ≥2 个真实来源：单源时所谓的"冲突"是同一个模型被裁判拆成多份
        for _it in dis.get("conflicts", []):
            _cl = _it.get("claims", {})
            dis.setdefault("single_source", []).append({
                "item": _it.get("item", "?"),
                "who": "（单源内部表述不一；报告里的多源是裁判编的）",
                "value": " ｜ ".join("%s: %s" % (k, v) for k, v in _cl.items())})
        dis["conflicts"] = []
    _kept, _demoted = [], 0
    for _it in dis.get("agreed", []):
        _sup = str(_it.get("support", "")).replace(" ", "").split("/")
        if len(_sup) == 2 and _sup[0].isdigit() and int(_sup[0]) < 2:
            dis.setdefault("single_source", []).append({
                "item": _it.get("item", "?"),
                "who": "（裁判判为一致，但实际只有 %s 个来源）" % _sup[0],
                "value": _it.get("value", "")})
            _demoted += 1
        else:
            _kept.append(_it)
    if _demoted:
        print("  [兜底] %d 项只有一个来源，已从「一致」降级为「孤证」（单源不算确证）" % _demoted)
    dis["agreed"] = _kept
    print("  一致 %d 项 / 冲突 %d 项 / 孤证 %d 项"
          % (len(dis.get("agreed", [])), len(dis.get("conflicts", [])),
             len(dis.get("single_source", []))))
    if scores:
        print("  对真值打分：" + " ｜ ".join(
            "%s %s" % (m, ("%.1f%%" % s["pct"]) if s else "n/a") for m, s in scores.items()))

    # ---- L3
    rechecks = []
    # 没有被复检的冲突项也要留痕：早先只把"复检过的"写进报告，于是 --max-recheck 0
    # 时 19 个冲突项在报告里凭空消失（汇总还显示"存疑 0"）—— 静默丢失比判错更危险。
    skipped = list(dis.get("conflicts", []))
    budget_skipped = 0
    if dis.get("conflicts") and not a.no_recheck:
        rm = [m.strip() for m in a.recheck_models.split(",") if m.strip()] or models[:2]
        todo = dis["conflicts"][:a.max_recheck]
        # 预算守护：一项复检最坏要 3 块 × 2 轮 × len(rm) 次调用。宁可少查几项并在报告里
        # 写明，也不要跑到一半被时间掐断 —— 那样缺了什么根本看不出来。
        left = budget_left()
        if left is not None:
            est = 6 * 20          # 保守估计：6 次调用 × 20 秒
            affordable = max(0, int((left - 20) // est))
            if affordable < len(todo):
                budget_skipped = len(todo) - affordable
                print("  [预算] %s —— 本次最多复检 %d 项（原计划 %d 项，差额会标成存疑）"
                      % (budget_tag(), affordable, len(todo)))
                todo = todo[:affordable]
        skipped = dis["conflicts"][len(todo):]
        if todo:
            print("\n[L3] 对 %d 个冲突项自动复检（模型：%s）%s"
                  % (len(todo), ", ".join(rm),
                     "" if len(todo) == len(dis["conflicts"])
                     else "  —— 共 %d 项，本次只查前 %d（--max-recheck 可调）"
                          % (len(dis["conflicts"]), len(todo))))
        for c in todo:
            item = c.get("item", "?")
            print("  · %s ..." % item)
            try:
                r = recheck(item, c.get("claims", {}), str(src), rm, judge)
                print("    收敛：%s" % ("是" if r["converged"] else "否"))
                rechecks.append(r)
            except Exception as e:
                print("    复检失败：%s" % str(e)[:90])
                rechecks.append({"item": item, "claims": c.get("claims", {}),
                                 "bands": [], "converged": False})

    # ---- L4
    lines = ["# eye.py 报告 · %s" % src.name, "",
             "- 问题：%s" % q,
             "- 模型：%s ｜ 裁判：%s" % (", ".join(models), judge),
             "- 证据等级：**确证**＝多源一致或有算法支持 ｜ **推断**＝单一来源 ｜ **存疑**＝矛盾且复检未收敛",
             "- 图片：%dx%d（送模型 %dx%d ｜ `--max-side %d`）"
             % (orig[0], orig[1], sent[0], sent[1], max_side),
             "- 耗时：%.0fs ｜ 预算：%s"
             % (time.time() - t_start,
                "不限" if not a.budget else "%ds（%s）" % (a.budget, budget_tag())),
             "",
             "> 本流水线带**全局时间预算**：到点就收工；没跑完的步骤标成 `%s`，"
             "**既不算「没看到」也不算「否」**。要跑全就把 `--budget` 调大。" % SKIPPED,
             "",
             "## 一、L0 算法证据（不经模型，不会幻觉）", "",
             "| 项 | 值 |", "| --- | --- |",
             "| 尺寸 | %s |" % ev["size"],
             "| 主色 | %s |" % ", ".join("%s (%s%%)" % c for c in ev["colors"][:6]),
             "| 本地 OCR | %s |" % (ev["ocr"].replace("\n", " ⏎ ")[:180] or ev["ocr_note"]),
             ""]

    agreed = dis.get("agreed", [])
    resolved = [r for r in rechecks if r.get("converged")]
    unresolved = [r for r in rechecks if not r.get("converged")]

    lines += ["## 二、确证项（多源一致 / 复检后收敛 / 有算法支持）", ""]
    if agreed or resolved:
        for x in agreed:
            lines.append("- **[确证] %s**：%s（%s）"
                         % (x.get("item", "?"), x.get("value", ""), x.get("support", "")))
        for r in resolved:
            hit = None
            for b in r.get("bands", []):
                vals = [v[:80] for v in _real(b["answers"].values())]
                if vals and len(set(vals)) == 1:
                    hit = (b["band"], vals[0]); break
            if hit:
                lines.append("- **[确证·复检收敛] %s**：放大到「%s」后各模型一致 —— %s"
                             % (r["item"], hit[0], hit[1]))
            else:
                lines.append("- **[确证·复检收敛] %s**：放大后各模型答案一致" % r["item"])
    else:
        lines.append("- （无）")
    lines.append("")

    lines += ["## 三、存疑项（矛盾；未收敛 或 未复检）", ""]
    if unresolved or skipped:
        for r in unresolved:
            lines.append("- **[存疑·复检未收敛] %s**：%s"
                         % (r["item"], json.dumps(r.get("claims", {}), ensure_ascii=False)))
        for c in skipped:
            lines.append("- **[存疑·未复检] %s**：%s"
                         % (c.get("item", "?"), json.dumps(c.get("claims", {}), ensure_ascii=False)))
        lines.append("")
        lines.append("> 这些项建议人眼裁夺，或换更强模型再问一次 —— 本鱼不替它们编答案。")
        if skipped:
            lines.append("> **其中 %d 项根本没被复检**（受 `--max-recheck` 限制，本次上限 %d）。"
                         "要查全部就把这个值调大。" % (len(skipped), a.max_recheck))
            if budget_skipped:
                lines.append("> ⏱ 其中 **%d 项是被时间预算砍掉的**（--budget %d 秒）—— "
                             "不是没冲突，是没来得及查。" % (budget_skipped, a.budget))
    else:
        lines.append("- （无）")
    lines.append("")

    lines += ["## 四、复检详情（每个冲突项是怎么查的）", ""]
    if rechecks:
        for r in rechecks:
            lines.append("### %s" % r["item"])
            for who, what in (r.get("claims") or {}).items():
                lines.append("- **%s** 原来说：%s" % (who, what))
            for b in r.get("bands", []):
                if b.get("skipped") or not b["answers"]:
                    lines.append("  - **%s** 放大块 → %s（时间预算用尽，这一块没跑）"
                                 % (b["band"], SKIPPED))
                    continue
                ans = " ｜ ".join("%s：%s" % (k, v[:60].replace("\n", " "))
                                  for k, v in b["answers"].items())
                cols = ", ".join("%s %s%%" % c for c in b["colors"][:3])
                lines.append("  - **%s** 放大块 → %s" % (b["band"], ans))
                lines.append("    - 该块主色：%s" % cols)
            lines.append("- **判定：%s**"
                         % ("确证（复检后收敛）" if r["converged"] else "存疑（复检未收敛）"))
            lines.append("")
    else:
        lines.append("- （本次没有冲突项）")
        lines.append("")

    lines += ["## 五、孤证项（单一来源 → 按推断对待）", ""]
    ss = dis.get("single_source", [])
    if ss:
        for x in ss:
            lines.append("- **[推断] %s**：%s（只有 %s 提到）"
                         % (x.get("item", "?"), x.get("value", ""), x.get("who", "?")))
    else:
        lines.append("- （无）")
    lines.append("")

    if scores:
        lines += ["## 六、对真值打分（schema 模式专属）", "",
                  "> **这个分数是「严格字面下界」**：它只认字面接近（精确／包含／字符集重叠／字面相似度），",
                  "> 因此**措辞不同但意思相同**的答案也可能被判错。要宽松上界请用 `vscore.py`（LLM 裁判）。",
                  "> **真实水平落在两者之间**；下面「打错的项」会连模型原话一起列出，方便你自己判断是真错还是措辞问题。",
                  "",
                  "| 模型 | 命中 | 说错 | 未答/看不清 | 得分 |",
                  "| --- | --- | --- | --- | --- |"]
        for m, s in scores.items():
            if s:
                lines.append("| %s | %d | %d | %d | **%.1f%%** |"
                             % (m, s["hit"], s["wrong"], s["miss"], s["pct"]))
            else:
                lines.append("| %s | - | - | - | n/a |" % m)
        lines.append("")
        lines += ["**打错的项（模型说错 / 未答）**：", ""]
        for m, s in scores.items():
            if not s or not s["detail"]:
                continue
            lines.append("- **%s**：" % m)
            for fid, said, truth in s["detail"][:8]:
                lines.append("  - `%s` — 它说：%s ｜ 真值：%s" % (fid, said[:50], truth[:70]))
        lines.append("")

    lines += ["## %s、原始回答（可追溯）" % ("七" if scores else "六"), ""]
    for m, txt in answers.items():
        lines += ["### %s" % m, "", txt, ""]

    # ---- 补跑建议：预算砍掉东西时必须给出怎么补，否则"没查"就等于永远不知道
    bands_cut = sum(1 for r in rechecks for b in r.get("bands", []) if b.get("skipped"))
    if skipped or bands_cut:
        nb = 900 if not a.budget else max(a.budget * 2, 900)
        cmd = 'python eye.py "%s"' % src
        if a.schema:
            cmd += " --schema %s" % a.schema
        cmd += " --budget %d --max-recheck %d" % (nb, max(len(dis.get("conflicts", [])), 4))
        lines += ["## %s、还没查完的 —— 补跑命令" % ("八" if scores else "七"), "",
                  "本次有 **%d 项冲突没被复检**，另有 **%d 个放大块没跑**（时间预算 / `--max-recheck` 所限）。"
                  % (len(skipped), bands_cut),
                  "它们**不代表「看不清」或「没有」**，只代表这次没问到。要接着查就把预算与上限一起放大：",
                  "", "```", cmd, "```", ""]

    report = "\n".join(lines)
    if a.out:
        Path(a.out).write_text(report, encoding="utf-8")
        print("\nreport -> %s" % a.out)
    else:
        print("\n" + report[:1500])

    # short console summary
    print("\n汇总：确证 %d（其中复检收敛 %d）｜ 存疑 %d（含未复检 %d）｜ 推断 %d"
          % (len(agreed) + len(resolved), len(resolved),
             len(unresolved) + len(skipped), len(skipped), len(ss)))


if __name__ == "__main__":
    main()
