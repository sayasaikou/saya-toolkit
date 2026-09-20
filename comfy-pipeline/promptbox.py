#!/usr/bin/env python
"""
promptbox.py -- randomized prompt generator

Given a character, build a complete prompt by sampling a scene (time / place / weather / mood)
plus character detail (outfit / expression / action / camera), instead of a plain white-background standing pose.

Usage:
  python promptbox.py --character saya --count 8 --seed 12345                 # print 8 prompts
  python promptbox.py --character saya --count 8 --seed 12345 --save out.txt  # also write to a file
  python promptbox.py --list-characters                                       # list available character profiles
  python promptbox.py --character saya --count 4 --family illustrious         # tag-style output (comma separated)
  python promptbox.py --character saya --count 4 --no-lora                    # omit the LoRA trigger word

Design rules:
- Character profiles and scene pools are separate. A profile may only state verified facts;
  anything unverified is marked NEEDS-CHECK and must never be invented.
- Consistency beats variety: sampled expressions pass through the profile persona filter
  (a shy character never receives a "laughing" expression).
- A profile may carry `lora`, `lora_weight` and `trigger`; fill them in once a LoRA is trained and
  the generator adds them to the output automatically.
- Two output syntaxes: natural (for Anima / Flux) and tags (comma style for Illustrious / SDXL).
"""
import argparse, io, json, os, random, sys

# The console may be GBK on a Chinese Windows install; force UTF-8 so non-ASCII never raises UnicodeEncodeError.
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
    """Sample one complete setup: scene + character + camera."""
    t = pools["time"]
    w = pools["weather"]
    pl = pools["place"]
    m = pools["mood"]
    c = pools["camera"]
    l = pools["light"]
    a_all = pools["action"]
    e_all = pools["expression"]

    # Persona filter: allow_* lists in the profile are whitelists; absent means everything is allowed.
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
    """Natural-language syntax (Anima / Flux)."""
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
    """Tag syntax (Illustrious / SDXL)."""
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
    ap.add_argument("--character", required=False, help="character id (see --list-characters)")
    ap.add_argument("--count", type=int, default=8)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--family", default="anima", choices=["anima", "flux", "illustrious"],
                    help="anima/flux produce natural language; illustrious produces tags")
    ap.add_argument("--save", default=None, help="write the result to a file")
    ap.add_argument("--json", dest="as_json", action="store_true", help="emit JSON for downstream tooling")
    ap.add_argument("--no-lora", action="store_true", help="omit the LoRA trigger word")
    ap.add_argument("--list-characters", action="store_true")
    a = ap.parse_args()

    chars = {k: v for k, v in load(CHARS).items() if not k.startswith("_")}
    pools = load(POOLS)

    if a.list_characters:
        for cid, c in chars.items():
            flag = "" if c.get("verified") else "  [appearance unverified: NEEDS-CHECK]"
            print(f"{cid:16} {c.get('display', ''):12} lora={c.get('lora', '-')}{flag}")
        return 0

    if not a.character:
        print("--character is required (use --list-characters to list profiles)", file=sys.stderr); return 2
    if a.character not in chars:
        print(f"unknown character profile: {a.character}", file=sys.stderr); return 2

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
        lines = [f"# character={a.character}  mode={a.family}  root_seed={seed}  lora={char.get('lora') or 'none'}", ""]
        for r in results:
            lines.append(f"[{r['index']}] seed={r['seed']}")
            lines.append(r["prompt"])
            lines.append("")
        text = "\n".join(lines)

    print(text)
    if a.save:
        with open(a.save, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"# written to {a.save}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
