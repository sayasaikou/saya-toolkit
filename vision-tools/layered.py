#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
layered.py -- 分层解析服装构成（v2：大件 / 配件 两分法）

方法论来源（全部是用户 2026-10-02 当天提出的）：
  ① 「模型对这身衣服的构成看不清晰，所以描述很混乱，应该先分析这份服装是由哪些部分构成的，分开来分析」
  ② 「这个角色在只穿内衣的情况下，要分步穿哪些部分才能穿起这套完整的造型？」
  ③ 「再分割成**大件 + 配件**，会不会好一点？比如说连衣裙、围裙、鞋袜就是大件，
      而束腰、领带、发饰、手套这些属于配件」

为什么两分法能治本：
  平铺问法会把「束腰」和「连衣裙」当成同类去排序 —— 于是出现「束腰穿在围裙里面」这种荒谬
  （实测被用户当场指出：束腰的作用就是束住连衣裙和围裙，怎么可能系在里面）。
  但**束腰本来就不是"穿在身上的衣服"，而是"固定在别的衣服上的配件"** ——
  它的位置由**它固定的那个主体**决定。这个约束是天生的，不用靠 prompt 硬塞。

流程：
  S1  分两堆：大件（覆盖身体的）／配件（固定在别的东西上的，各带 attached_to）
  S2  逐件细看：形状／颜色细节／边缘／装饰件／自身层数／材质
  S3  装配关系：谁压谁、有没有夹层
  S4  穿衣顺序：先排大件，再说每个配件装在哪一步之后

用法：
  python layered.py <图片> [--models dashscope] [--out 报告.md] [--hint "已知构成"]
"""

import argparse
import difflib
import json
import re
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from eyeprobe import BACKENDS, user_env, call, img_b64   # noqa: E402

try:
    from PIL import Image
except ImportError:
    Image = None


def crop_zoom(src, box):
    """按百分比 box 裁图并放大，返回 (临时文件路径, 像素矩形, 放大倍数)。
    为什么要它：实测同一张图「整图问」答"前襟 5 颗扣子"（把门襟阴影当成扣子），
    「裁出来放大 3 倍再问」答"1 颗" —— 而人工核对就是 1 颗。
    小目标必须裁出来放大再问（用户 2026-10-02 提的第二条改进）。"""
    if Image is None or not isinstance(box, dict):
        return None
    try:
        x, y = float(box.get("x", 0)), float(box.get("y", 0))
        w, h = float(box.get("w", 0)), float(box.get("h", 0))
    except Exception:
        return None
    if w <= 1 or h <= 1:
        return None
    im = Image.open(src).convert("RGB")
    W, H = im.size
    x1, y1 = max(0, int(W * x / 100.0)), max(0, int(H * y / 100.0))
    x2, y2 = min(W, int(W * (x + w) / 100.0)), min(H, int(H * (y + h) / 100.0))
    if x2 - x1 < 24 or y2 - y1 < 24:
        return None
    crop = im.crop((x1, y1, x2, y2))
    sc = max(1, min(4, int(900 / max(1, crop.width))))
    big = crop.resize((crop.width * sc, crop.height * sc), Image.LANCZOS)
    p = Path(tempfile.gettempdir()) / ("layered_%d.png" % (abs(hash((x1, y1, x2, y2))) % 10 ** 8))
    big.save(p)
    return p, (x1, y1, x2, y2), sc

HARD_RULES = """硬要求：
- 涉及左右必须写清参照系（画面左/右 还是 角色自身左/右）。
- 专业术语照用，但后面用括号补一句白话（例：门襟（衣服前面那条从上到下的开口边））。
- 不许说没信息量的话（像「四角略圆」这种），要么说清形状要么别说。
- 看不清就写「看不清」，不要猜。"""


def ask_json(model, b64, prompt, budget=2600):
    ok, res, secs = call(model, b64, prompt, max_tokens=budget)
    if not ok:
        return None, str(res)[:90]
    t = res[0].strip()
    if t.startswith("```"):
        parts = t.split("```")
        if len(parts) >= 2:
            t = parts[1]
            if t.lower().lstrip().startswith("json"):
                t = t.lstrip()[4:]
    s, e = t.find("{"), t.rfind("}")
    if s < 0 or e < 0:
        return None, "no JSON"
    try:
        return json.loads(t[s:e + 1]), "%.1fs" % secs
    except Exception as ex:
        return None, "bad JSON: %s" % str(ex)[:60]


S1_PROMPT = """这是一个人物立绘。请只研究**她身上穿的服装**，先不要描述长相。

第一步：给出这套造型的**对象清单**，**每个对象自带它自己的「部位细节」**。

分**三堆**：
**A. 大件** —— **本身就是一件衣服**，能单独穿在身上、覆盖身体主要区域。
   例：连衣裙、上衣、裤子、**围裙**、鞋、袜。
**B. 配件** —— **本身不是一件完整的衣服**，必须依附在别的衣物或身体部位上才起作用。
   例：束腰／腰带、领带、发饰、手套、袖箍。
**C. 随身物** —— **既不是衣服、也不依附于衣物**，而是**独立存在于身体之外的物件**。
   例：**手持物**（包／书／杯子／武器）、身后或头顶的**光环**、**独立的翅膀／披风支架**、
   漂浮的道具。**这一堆只描述"是什么、什么样、在哪"，不参与穿衣顺序。**
   （实测教训：判据只有两堆时，小挎包被硬塞进"大件"，模型还自己写了段理由绕过去。）

⚠️ **每个对象都要给一个粗略的 `box`（位置框）**，填**百分比**（0-100，相对整张图）：
   `{"x":左边距%,"y":上边距%,"w":宽%,"h":高%}`。
   不用精确，**大概罩住这个对象在画面上的范围就行** —— 它只用来裁图放大，后面会复核。

⚠️ **每个对象都必须带一个 `details` 数组**，装**它自己的部位细节**：
   纽扣、领子、袖口、荷叶边、刺绣、口袋、系带、贴布、条纹、搭扣……
   **凡是「长在这个对象上」的东西，统统放进它自己的 details**，
   并且写明**是哪个部位**（领子／袖口／前襟／裙摆／正面／下缘……）。

⚠️ **判据（2026-10-02 被用户逐步纠正 + 三次盲测后定稿）**：
1. **分大件／配件只有一个判据：「它能不能单独当一件衣服穿？」** 能 → 大件；不能 → 配件。
   **别把「能拿下来」当判据** —— 围裙系在腰上也能解开拿下来，但它本身就是一件衣服 ⇒ 大件。
2. **同一件衣服内部的多层结构算一件**（裙摆三层料子是这一件裙子的结构，不是三件）。
3. **细节必须挂在它所属的对象里**。衣服上的纽扣、刺绣、荷叶边**不许单列成一个对象** ——
   它们是**那件衣服的部位细节**。分不清属于谁，就看**它长在哪件衣服上**。
   （实测教训：判据写松时一张图被拆出 11 件"配件"，里面混进了立领本体、刺绣、袖口荷叶边。）
4. **不是服装的东西不要列**（尾巴／鳍等身体附属结构、背景物件、手持道具）。

%s

只输出 JSON：
{"main":[{"name":"大件名（4-8字）","covers":"覆盖身体哪一段","color":"主色",
          "box":{"x":0,"y":0,"w":0,"h":0},
          "details":[{"part":"部位（领子/袖口/前襟/裙摆…）","desc":"这个部位长什么样"}]}],
 "accessories":[{"name":"配件名","attached_to":"固定在哪个对象／哪个部位上","color":"主色",
          "box":{"x":0,"y":0,"w":0,"h":0},
          "details":[{"part":"部位","desc":"这个部位长什么样"}]}],
 "props":[{"name":"随身物名","kind":"手持物/光环/武器/…","where":"在画面什么位置","color":"主色",
          "box":{"x":0,"y":0,"w":0,"h":0},
          "details":[{"part":"部位","desc":"这个部位长什么样"}]}]}

%s"""


S3_PROMPT = """还是这张人物立绘的服装。现在只看**件与件之间的关系**。

已经识别出的部件：
%s

只输出 JSON：
{"order":["最贴身的","...","最外面的"],
 "overlaps":[{"who":"哪一件","over":"压在谁上面","where":"在哪个位置"}],
 "hidden":"有没有哪一件被夹在两层之间、只露出一部分？是什么？"}

%s"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--models", default="dashscope")
    ap.add_argument("--out", default="")
    ap.add_argument("--hint", default="", help="已知构成（人给的先验）")
    ap.add_argument("--double", action="store_true",
                    help="对每件细看问两遍，两次说法不一致的字段标为存疑"
                         "（用来识别「图上本身就不清楚」的地方；调用数翻倍）")
    a = ap.parse_args()

    src = Path(a.image)
    if not src.exists():
        print("image not found: %s" % src); sys.exit(2)
    models = [m.strip() for m in a.models.split(",") if m.strip()
              and (not BACKENDS.get(m, {}).get("keyenv") or user_env(BACKENDS[m]["keyenv"]))]
    if not models:
        print("no usable model"); sys.exit(2)
    m = models[0]
    b64, _ = img_b64(str(src))

    print("=" * 78)
    print("layered.py v2（大件/配件两分法）  |  %s  |  模型 %s" % (src.name, m))
    print("=" * 78)

    # ---- S1 分两堆
    print("\n[S1] 先分两堆：大件（穿在身上的）／配件（固定在别的东西上的）")
    p1 = S1_PROMPT.replace("{RULES}", HARD_RULES)
    if a.hint:
        p1 = ("用户已经给出他对这套服装构成的理解，请以它为**参考**核对并补全，"
              "不要推翻他明显正确的地方：\n%s\n\n%s" % (a.hint, S1_PROMPT.replace("{RULES}", HARD_RULES)))
    s1, note = ask_json(m, b64, p1)
    if not s1 or not (s1.get("main") or s1.get("accessories")):
        print("  分件失败：%s" % note); sys.exit(2)
    mains = s1.get("main", [])
    accs = s1.get("accessories", [])
    props = s1.get("props", [])
    print("  【大件】%d 件：" % len(mains))
    for i, p in enumerate(mains, 1):
        print("   %d) %-14s %-22s %s" % (i, p.get("name", "?"), p.get("covers", ""), p.get("color", "")))
        for d in (p.get("details") or []):
            print("        └ %-8s %s" % (d.get("part", ""), str(d.get("desc", ""))[:62]))
    print("  【配件】%d 件：" % len(accs))
    for i, p in enumerate(accs, 1):
        print("   %d) %-14s 固定在：%-20s %s" % (i, p.get("name", "?"), p.get("attached_to", ""), p.get("color", "")))
        for d in (p.get("details") or []):
            print("        └ %-8s %s" % (d.get("part", ""), str(d.get("desc", ""))[:62]))
    if props:
        print("  【随身物】%d 件（独立于身体之外，不参与穿衣顺序）：" % len(props))
        for i, p in enumerate(props, 1):
            print("   %d) %-14s %-10s %s" % (i, p.get("name", "?"), p.get("kind", ""), p.get("where", "")))
            for d in (p.get("details") or []):
                print("        └ %-8s %s" % (d.get("part", ""), str(d.get("desc", ""))[:62]))

    # ---- S2 逐件细看（大件 + 配件 + 随身物）——每件先按 box 裁出来放大，再看
    print("\n[S2] 逐件细看（每件单独问；有 box 的先裁出来放大再问）")
    details = []
    allobjs = ([("大件", x) for x in mains] + [("配件", x) for x in accs]
               + [("随身物", x) for x in props])
    for kind, p in allobjs:
        name = p.get("name", "?")
        extra = ("它固定/附着在：%s。" % p.get("attached_to")) if p.get("attached_to") else ""
        if p.get("where"):
            extra += "它大致在：%s。" % p.get("where")
        pr = ("这是同一个人物立绘。现在**只看【%s】**（%s%s，主色 %s），不要去管别的部件。\n\n%s\n\n"
              % (name, kind, ("，" + p.get("covers")) if p.get("covers") else "",
                 p.get("color", ""), extra + HARD_RULES))
        b64use, cropped = b64, ""
        r = crop_zoom(str(src), p.get("box"))
        if r:
            path_z, rect, sc = r
            try:
                b64use, _ = img_b64(str(path_z))
                cropped = "  (已裁 %s 放大 %dx)" % (rect, sc)
            except Exception:
                b64use = b64
            finally:
                try: path_z.unlink()
                except Exception: pass
        pr = ("这是一张从人物立绘上裁下来的局部放大图。" if cropped else "这是同一个人物立绘。") + \
             ("现在**只看【%s】**（%s%s，主色 %s），不要去管别的部件。\n\n%s\n\n"
              % (name, kind, ("，" + p.get("covers")) if p.get("covers") else "",
                 p.get("color", ""), extra + HARD_RULES))
        d, note = ask_json(m, b64use, pr + S2_Q)
        unstable = None
        if a.double and d:
            d2, _ = ask_json(m, b64use, pr + S2_Q)
            unstable = field_diff(d, d2)
        if d:
            details.append({"kind": kind, "part": p, "detail": d, "cropped": cropped,
                            "unstable": unstable})
            print("  · [%s] %-14s %s%s%s" % (kind, name, note, cropped,
                  "" if not unstable else "  ⚠ 抖动：" + unstable[0][:70]))
        else:
            details.append({"kind": kind, "part": p, "detail": None, "err": note})
            print("  · [%s] %-14s 失败：%s" % (kind, name, note))
        time.sleep(0.6)

    # ---- S3 装配
    print("\n[S3] 装配关系：谁压谁 / 有没有夹层")
    s3, note3 = ask_json(m, b64, S3_PROMPT % (
        json.dumps({"main": mains, "accessories": accs}, ensure_ascii=False), HARD_RULES))
    print("  %s" % note3)
    if s3:
        print("  从里到外：%s" % " → ".join(s3.get("order", [])))
        for o in s3.get("overlaps", [])[:8]:
            print("    %s 压在 %s 上面（%s）" % (o.get("who", "?"), o.get("over", "?"), str(o.get("where", ""))[:50]))
        if s3.get("hidden"):
            print("    被夹住的：%s" % str(s3["hidden"])[:100])

    # ---- S4 穿衣顺序：大件先排，配件说时机
    print("\n[S4] 穿衣顺序（大件排序 + 配件装配时机）")
    pr4 = ("假设这个角色**现在只穿内衣**。请分两段给出顺序：\n"
           "**第一段：大件按顺序穿**（哪件先穿、哪件后穿）。\n"
           "**第二段：配件各自在哪一步之后装上** —— 配件的位置由**它固定的那件东西**决定"
           "（比如某个配件固定在围裙上，那它只能在围裙穿好之后装）。\n\n"
           "大件：%s\n配件（含固定对象）：%s\n\n"
           "⚠️ **排完自己复核**：有没有哪个配件的顺序跟它「固定在谁身上」矛盾？"
           "比如「固定在围裙外、却排在围裙之前」—— 这种自相矛盾必须重排。\n\n"
           "只输出 JSON：\n"
           '{"main_order":[{"n":1,"wear":"大件名","note":"为什么这一步"}],'
           ' "acc_order":[{"n":1,"wear":"配件名","after_main":"在哪件大件之后","attached_to":"装在哪件上","note":""}]}\n\n%s'
           % (json.dumps([x.get("name") for x in mains], ensure_ascii=False),
              json.dumps([{"name": x.get("name"), "attached_to": x.get("attached_to")} for x in accs],
                         ensure_ascii=False), HARD_RULES))
    s4, note4 = ask_json(m, b64, pr4)
    print("  %s" % note4)
    if s4:
        for st in s4.get("main_order", []):
            print("    [大件] %s. %-14s %s" % (st.get("n", "?"), st.get("wear", ""), str(st.get("note", ""))[:52]))
        for st in s4.get("acc_order", []):
            print("    [配件] %s. %-12s ← 在 %s 之后，装在 %s"
                  % (st.get("n", "?"), st.get("wear", ""), st.get("after_main", ""), st.get("attached_to", "")))

    # ---- 报告
    L = ["# 服装分层解析 · %s" % src.name, "",
         "> 方法（用户 2026-10-02 提）：**先分「大件／配件」两堆 → 逐件细看 → 装配关系 → 穿衣顺序**。",
         "> 两分法治的是这个病：把「束腰」和「连衣裙」当同类排序，会排出「束腰穿在围裙里面」的荒谬；",
         "> 而**配件的位置由它固定的主体决定**，这个约束是天生的。", ""]
    if a.hint:
        L += ["## 用户给的参考构成（先验）", "", a.hint, ""]
    L += ["## 一、大件（%d 件，穿在身上的）" % len(mains), ""]
    for i, p in enumerate(mains, 1):
        L.append("%d. **%s** —— %s，主色 %s" % (i, p.get("name"), p.get("covers", ""), p.get("color", "")))
        for d in (p.get("details") or []):
            L.append("   - **%s**：%s" % (d.get("part", ""), d.get("desc", "")))
    L += ["", "## 二、配件（%d 件，依附在别的东西上的）" % len(accs), ""]
    for i, p in enumerate(accs, 1):
        L.append("%d. **%s** —— 固定在 **%s**，主色 %s"
                 % (i, p.get("name"), p.get("attached_to", ""), p.get("color", "")))
        for d in (p.get("details") or []):
            L.append("   - **%s**：%s" % (d.get("part", ""), d.get("desc", "")))
    L += ["", "## 三、随身物（%d 件，独立于身体之外，不参与穿衣顺序）" % len(props), ""]
    if props:
        for i, p in enumerate(props, 1):
            L.append("%d. **%s**（%s）—— %s，主色 %s"
                     % (i, p.get("name"), p.get("kind", ""), p.get("where", ""), p.get("color", "")))
            for d in (p.get("details") or []):
                L.append("   - **%s**：%s" % (d.get("part", ""), d.get("desc", "")))
    else:
        L.append("- （无）")
    L += ["", "## 四、逐件细节", ""]
    for d in details:
        p, det = d["part"], d.get("detail")
        L.append("### [%s] %s%s" % (d["kind"], p.get("name"),
                                    ("（固定在 %s）" % p.get("attached_to")) if p.get("attached_to") else ""))
        if not det:
            L.append("- 解析失败：%s" % d.get("err", "")); L.append(""); continue
        for k, label in [("shape", "形状"), ("color_detail", "颜色细节"), ("edge", "边缘处理"),
                         ("ornament", "装饰件"), ("layers", "自身层数"), ("material", "材质")]:
            if det.get(k):
                L.append("- **%s**：%s" % (label, det[k]))
        if d.get("unstable"):
            L.append("- ⚠️ **存疑：两次独立提问说法不一致** —— %s" % "；".join(d["unstable"]))
        L.append("")
    if s3:
        L += ["## 五、装配关系", "", "- **从里到外**：%s" % " → ".join(s3.get("order", [])), ""]
        for o in s3.get("overlaps", []):
            L.append("- **%s** 压在 **%s** 上面（%s）" % (o.get("who"), o.get("over"), o.get("where", "")))
        if s3.get("hidden"):
            L.append("- **夹在两层之间的**：%s" % s3["hidden"])
        L.append("")
    if s4:
        L += ["## 六、穿衣顺序（假设只穿内衣）", "", "**大件**：", ""]
        for st in s4.get("main_order", []):
            L.append("%s. **%s** —— %s" % (st.get("n", "?"), st.get("wear", ""), st.get("note", "")))
        L += ["", "**配件**：", ""]
        for st in s4.get("acc_order", []):
            L.append("%s. **%s** —— 在「%s」之后装上，固定在 %s。%s"
                     % (st.get("n", "?"), st.get("wear", ""), st.get("after_main", ""),
                        st.get("attached_to", ""), st.get("note", "")))
        L.append("")
    L += ["## 七、原始 JSON（可追溯）", "", "```json",
          json.dumps({"main": mains, "accessories": accs, "props": props, "details": details,
                      "assembly": s3, "dressing": s4}, ensure_ascii=False, indent=1), "```"]

    if a.out:
        Path(a.out).write_text("\n".join(L), encoding="utf-8")
        print("\nreport -> %s" % a.out)
    print("\n汇总：大件 %d ／ 配件 %d ／ 成功细化 %d"
          % (len(mains), len(accs), sum(1 for d in details if d.get("detail"))))


S2_Q = """只输出 JSON：
{"shape":"形状与轮廓（直筒/收腰/展开/翻折？）",
 "color_detail":"颜色细节（拼色/渐变/上下不同色/格子或条纹）",
 "edge":"边缘怎么处理的（收紧/花边/滚边，在哪道边上）",
 "ornament":"装饰件：几个、什么颜色、什么形状、什么位置。⚠️ 如果看到**说不出用途的色块或笔画**（既不构成扣子也不构成蝴蝶结、和周围设计对不上），**单独写出来**：「有一处看不出是什么的X色块，在……」，不要硬给它安一个名字。",
 "layers":"这一件自己有几层（能看到几层布）",
 "material":"像什么材质（棉/纱/缎面反光/毛呢）"}"""


def _sim(a, b):
    """粗糙的语义相似判断（精确/包含/字符集/字面比四档）。
    抖动判定必须走它，不能直接比字符串 —— 实测直接比会把「2 个位于左右袖口」
    和「2 个位于左右袖口外侧」这种**同一件事的措辞差异**也报成抖动，8/8 全红，
    信号被噪声淹没。"""
    a, b = str(a).strip(), str(b).strip()
    if a == b:
        return True
    if a and b and (a in b or b in a):
        return True
    sa, sb = set(a), set(b)
    if sa and sb and len(sa & sb) / float(len(sa | sb)) >= 0.72:
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.82


_NUM = re.compile(r"(\d+)\s*[个枚颗处条只对片]")   # 只认「数量词」，不认尺寸/序号
_DIRWORDS = ("左", "右", "上", "下", "前", "后", "内", "外")


def _severity(va, vb):
    """给两次说法的差异分级 —— 全是「措辞差异」等于没信息量，必须区别对待。

    实测：8 件全报抖动时，真正的信号是「4 个 vs 6 个蝴蝶结」「左上角 vs 左下角」
    「3 颗纽扣 vs 1 个蝴蝶结」，而噪声是「无功能性装饰件」vs「无常规装饰件」。
    ⇒ **数量冲突 / 方位冲突 ＝ 图上确实看不准，要人工；措辞差异 ＝ 忽略。**

    ⚠️ 数量正则只认 `N个/枚/颗/处…`，**不能抓所有数字** —— 否则「直径 0.8cm」
    这种尺寸也会被当成数量冲突，制造假阳性（实测第一版就是这样 8/8 全红）。
    """
    if _NUM.findall(str(va)) != _NUM.findall(str(vb)):
        return "数量冲突"
    da = [d for d in _DIRWORDS if d in str(va)]
    db = [d for d in _DIRWORDS if d in str(vb)]
    if da != db:
        return "方位冲突"
    return "措辞差异"


def field_diff(a, b, keys=("ornament", "edge", "layers"), only_severe=True):
    """比较两次独立提问 —— 抖动的字段就是「图上本身不清楚」的地方。

    为什么要它：同一处细节，整图问答「3 颗扣子」、裁图放大答「1 颗」、再问一次答
    「1 个蝴蝶结」；用户核对后确认那其实是**一处 AI 作画的失误色块**。
    ⇒ **图本身没有答案时，任何模型都只能瞎猜** —— 这不是理解问题，是图的问题，
      靠改 prompt 治不了；只能靠「问两次看不一致」把它标出来。
    """
    if not a or not b:
        return None
    bad = []
    for k in keys:
        va, vb = str(a.get(k, "")).strip(), str(b.get(k, "")).strip()
        if not va or not vb or _sim(va, vb):
            continue
        sev = _severity(va, vb)
        if only_severe and sev == "措辞差异":
            continue
        bad.append("[%s] %s：A「%s」 vs B「%s」" % (sev, k, va[:36], vb[:36]))
    return bad or None

if __name__ == "__main__":
    main()
