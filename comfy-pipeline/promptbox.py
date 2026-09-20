#!/usr/bin/env python
"""
promptbox.py —— 随机提示词生成器（大肥鱼自用）

用途：给一个角色，随机拼出「场景（时间/地点/天气/氛围）+ 人物（服装/神态/动作/镜头）」的完整提示词，
     而不是"白底 + 站姿"的证件照。

用法：
  python promptbox.py --character saya --count 8 --seed 12345                 # 打印 8 段
  python promptbox.py --character saya --count 8 --seed 12345 --save out.txt  # 同时落盘
  python promptbox.py --list-characters                                       # 看有哪些角色档案
  python promptbox.py --character saya --count 4 --family illustrious         # 输出标签式（逗号串）
  python promptbox.py --character saya --count 4 --no-lora                    # 不挂 LoRA 触发词

设计要点（写死，别再走弯路）：
- **角色档案与场景池分开**：角色档案只写"确定的事实"；不确定的一律标 NEEDS-CHECK，不许编。
- **一致性优先于花哨**：抽到的神态要过角色的 persona 过滤器（比如害羞型角色不会抽到"大笑"）。
- 每个角色可挂 `lora` 名 + `lora_weight` + `trigger`（训好 LoRA 后填上即可，生成器会自动加进工作流）。
- 输出两种语法：natural（Anima/Flux 用的自然语言）与 tags（Illustrious/SDXL 用的逗号标签）。
"""
import argparse, io, json, os, random, sys

# 控制台可能是 GBK（中文 Windows）→ 强制 UTF-8，免得中文与符号报 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
CHARS = os.path.join(HERE, "promptbox-characters.json")
POOLS = os.path.join(HERE, "promptbox-pools.json")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pick(rng, pool, n=1):
    n = min(n, len(pool))
    return rng.sample(pool, n)


def build_plan(rng, pools, char):
    """抽一次完整设定：场景 + 人物 + 镜头"""
    t = pools["time"]
    w = pools["weather"]
    pl = pools["place"]
    m = pools["mood"]
    c = pools["camera"]
    l = pools["light"]
    a_all = pools["action"]
    e_all = pools["expression"]

    # persona 过滤：角色档案里的 allow_* 是白名单（没写就是全放）
    if char.get("allow_actions"):
        a_pool = [x for x in a_all if x["key"] in char["allow_actions"]]
    else:
        a_pool = a_all
    if char.get("allow_expressions"):
        e_pool = [x for x in e_all if x["key"] in char["allow_expressions"]]
    else:
        e_pool = e_all
    if not a_pool:
        a_pool = a_all
    if not e_pool:
        e_pool = e_all

    scene = {
        "time": rng.choice(t),
        "weather": rng.choice(w),
        "place": rng.choice(pl),
        "mood": rng.choice(m),
        "light": rng.choice(l),
    }
    person = {
        "outfit": rng.choice(char["outfits"]) if isinstance(char["outfits"][0], str) else rng.choice(char["outfits"]),
        "expression": rng.choice(e_pool),
        "action": rng.choice(a_pool),
    }
    shot = rng.choice(c)
    return scene, person, shot


def to_natural(char, scene, person, shot):
    """自然语言式（Anima / Flux）"""
    name = char.get("display", char["id"])
    look = char["look_natural"]
    trig = (char.get("trigger", "") + " ") if char.get("trigger") else ""
    s = (
        f"{trig}An anime illustration of {name}, {look}. "
        f"She is {person['action']['natural']} {shot['natural']}. "
        f"She wears {person['outfit']}. "
        f"Her expression is {person['expression']['natural']}. "
        f"The scene: {scene['place']['natural']}, {scene['time']['natural']}, {scene['weather']['natural']}. "
        f"{scene['light']['natural']}, {scene['mood']['natural']} mood, detailed, soft colors"
    )
    return " ".join(s.split())


def to_tags(char, scene, person, shot):
    """标签式（Illustrious / SDXL）"""
    outfit = person["outfit"]
    if isinstance(outfit, dict):
        outfit = outfit.get("tags") or outfit.get("natural") or ""
    parts = [
        char.get("trigger", "") if char.get("trigger") else char["id"],
        "1girl", "solo",
        char["look_tags"],
        outfit,
        person["expression"]["tags"],
        person["action"]["tags"],
        shot["tags"],
        scene["place"]["tags"],
        scene["time"]["tags"],
        scene["weather"]["tags"],
        scene["light"]["tags"],
        scene["mood"]["tags"],
        "masterpiece", "best quality", "detailed",
    ]
    return ", ".join(p for p in parts if p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--character", required=False, help="角色 id（见 --list-characters）")
    ap.add_argument("--count", type=int, default=8)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--family", default="anima", choices=["anima", "flux", "illustrious"],
                    help="anima/flux 出自然语言；illustrious 出标签式")
    ap.add_argument("--save", default=None, help="把结果写到文件")
    ap.add_argument("--json", dest="as_json", action="store_true", help="输出 JSON（给脚本吃）")
    ap.add_argument("--no-lora", action="store_true", help="不带 LoRA 触发词")
    ap.add_argument("--list-characters", action="store_true")
    a = ap.parse_args()

    chars = {k: v for k, v in load(CHARS).items() if not k.startswith("_")}
    pools = load(POOLS)

    if a.list_characters:
        for cid, c in chars.items():
            flag = "" if c.get("verified") else "  [外貌未经核对 NEEDS-CHECK]"
            print(f"{cid:16} {c.get('display', ''):12} lora={c.get('lora', '-')}{flag}")
        return 0

    if not a.character:
        print("需要 --character（或 --list-characters 看名单）", file=sys.stderr); return 2
    if a.character not in chars:
        print(f"没有这个角色档案：{a.character}", file=sys.stderr); return 2

    char = dict(chars[a.character])
    char.setdefault("id", a.character)
    if a.no_lora:
        char["trigger"] = ""
        char["lora"] = None

    seed = a.seed if a.seed is not None else random.randrange(2**31)
    rng = random.Random(seed)
    tag_mode = (a.family == "illustrious")

    results = []
    for i in range(a.count):
        scene, person, shot = build_plan(rng, pools, char)
        prompt = to_tags(char, scene, person, shot) if tag_mode else to_natural(char, scene, person, shot)
        results.append({
            "index": i + 1,
            "family": a.family,
            "character": a.character,
            "seed": rng.randrange(2**31),
            "prompt": prompt,
            "lora": char.get("lora"),
            "lora_weight": char.get("lora_weight", 1.0),
            "plan": {"scene": scene, "person": person, "shot": shot},
        })

    if a.as_json:
        text = json.dumps({"root_seed": seed, "items": results}, ensure_ascii=False, indent=2)
    else:
        lines = [f"# 角色={a.character}  模式={a.family}  根种子={seed}  LoRA={char.get('lora') or '无'}", ""]
        for r in results:
            lines.append(f"[{r['index']}] seed={r['seed']}")
            lines.append(r["prompt"])
            lines.append("")
        text = "\n".join(lines)

    print(text)
    if a.save:
        with open(a.save, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"# 已写入 {a.save}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
