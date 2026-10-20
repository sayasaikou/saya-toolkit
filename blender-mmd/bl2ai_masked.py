# -*- coding: utf-8 -*-
"""Masked img2img pass: feed a Blender MV render into ComfyUI and repaint only the allowed area.

Run:
    python bl2ai_masked.py --base <render.png> --face-bbox 455,330,630,515 \
        --outdir <dir> --denoise 0.38 --cn-weight 0.6

What the mask does:
    SetLatentNoiseMask uses white = repaint, black = keep. The face box is drawn black
    (kept as rendered), the rest stays white (repainted). This is the only knob that
    separates identity preservation from style/material transfer; denoise alone cannot.

Requirements:
    Pillow, a running ComfyUI with an SDXL-architecture checkpoint, a ControlNet union
    model, and the standard nodes used below. Adjust the workflow dict if your node
    names differ.
"""
import argparse
import json
import os
import shutil
import time
import urllib.request

from PIL import Image, ImageDraw


DEFAULT_PROMPT = (
    "anime character rendered with physically based materials and ray-traced lighting, "
    "subsurface scattering on translucent skin, anisotropic hair highlights, "
    "polished metal ornaments with sharp speculars, woven fabric with fine folds, "
    "soft ray-traced shadows, global illumination, crisp 3D render, high detail"
)
DEFAULT_NEG = (
    "painterly, brush strokes, thick impasto, oil painting, cel shading, flat shading, "
    "posterized, lowres, bad anatomy, bad hands, extra fingers, worst quality, "
    "low quality, jpeg artifacts, watermark, text"
)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True, help="source render")
    p.add_argument("--face-bbox", required=True, help="x0,y0,x1,y1 in source pixels")
    p.add_argument("--outdir", required=True)
    p.add_argument("--tag", default="bl2ai")
    p.add_argument("--denoise", type=float, default=0.38)
    p.add_argument("--cn-weight", type=float, default=0.6)
    p.add_argument("--cn-type", default="lineart", choices=["lineart", "canny", "mlsd", "tile"])
    p.add_argument("--steps", type=int, default=28)
    p.add_argument("--cfg", type=float, default=6.5)
    p.add_argument("--seed", type=int, default=20261020)
    p.add_argument("--feather", type=int, default=14)
    p.add_argument("--host", default="http://127.0.0.1:8188")
    p.add_argument("--comfy-in", required=True, help="ComfyUI input dir")
    p.add_argument("--comfy-out", required=True, help="ComfyUI output dir")
    p.add_argument("--ckpt", required=True)
    p.add_argument("--cn", required=True, help="controlnet model filename")
    p.add_argument("--prompt-file", default="")
    p.add_argument("--negative-file", default="")
    return p.parse_args()


def post(host, path, payload):
    req = urllib.request.Request(host + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=180).read().decode())


def get(host, path):
    return json.loads(urllib.request.urlopen(host + path, timeout=180).read().decode())


def make_mask(width, height, bbox, path, feather):
    mask = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(mask)
    draw.ellipse(bbox, fill=0)
    mask.save(path)


def build_workflow(args, prompt, negative, mask_name):
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": args.ckpt}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["1", 1]}},
        "4": {"class_type": "LoadImage", "inputs": {"image": os.path.basename(args.base)}},
        "5": {"class_type": "VAEEncode", "inputs": {"pixels": ["4", 0], "vae": ["1", 2]}},
        "20": {"class_type": "ControlNetLoader", "inputs": {"control_net_name": args.cn}},
        "21": {"class_type": "SetUnionControlNetType",
               "inputs": {"control_net": ["20", 0], "type": args.cn_type}},
        "22": {"class_type": "ControlNetApplyAdvanced",
               "inputs": {"positive": ["2", 0], "negative": ["3", 0],
                          "control_net": ["21", 0], "image": ["4", 0],
                          "strength": args.cn_weight, "start_percent": 0.0, "end_percent": 0.9}},
        "30": {"class_type": "LoadImageMask", "inputs": {"image": mask_name, "channel": "red"}},
        "31": {"class_type": "FeatherMask",
               "inputs": {"mask": ["30", 0], "left": args.feather, "top": args.feather,
                          "right": args.feather, "bottom": args.feather}},
        "32": {"class_type": "SetLatentNoiseMask",
               "inputs": {"samples": ["5", 0], "mask": ["31", 0]}},
        "9": {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["1", 2]}},
        "10": {"class_type": "SaveImage",
               "inputs": {"filename_prefix": args.tag, "images": ["9", 0]}},
        "8": {"class_type": "KSampler",
              "inputs": {"seed": args.seed, "steps": args.steps, "cfg": args.cfg,
                         "sampler_name": "dpmpp_2m", "scheduler": "karras",
                         "denoise": args.denoise, "model": ["1", 0],
                         "positive": ["22", 0], "negative": ["22", 1],
                         "latent_image": ["32", 0]}},
    }


def main():
    args = parse_args()
    bbox = tuple(int(v) for v in args.face_bbox.split(","))
    if len(bbox) != 4:
        raise SystemExit("--face-bbox expects x0,y0,x1,y1")

    prompt = DEFAULT_PROMPT
    negative = DEFAULT_NEG
    if args.prompt_file:
        prompt = open(args.prompt_file, encoding="utf-8").read().strip()
    if args.negative_file:
        negative = open(args.negative_file, encoding="utf-8").read().strip()

    src = os.path.abspath(args.base)
    image = Image.open(src)
    mask_name = "%s_mask.png" % args.tag
    make_mask(image.width, image.height, bbox, os.path.join(args.comfy_in, mask_name), args.feather)

    staged = "%s_%s" % (args.tag, os.path.basename(src))
    shutil.copy2(src, os.path.join(args.comfy_in, staged))
    args.base = staged

    workflow = build_workflow(args, prompt, negative, mask_name)
    started = time.time()
    try:
        response = post(args.host, "/prompt", {"prompt": workflow})
    except Exception as exc:  # noqa: BLE001
        body = exc.read().decode() if hasattr(exc, "read") else str(exc)
        raise SystemExit("submit failed: %s" % body[:800])

    prompt_id = response["prompt_id"]
    outputs = None
    while time.time() - started < 1800:
        time.sleep(2)
        history = get(args.host, "/history/" + prompt_id)
        if prompt_id in history:
            status = history[prompt_id].get("status", {})
            if status.get("completed"):
                outputs = history[prompt_id]["outputs"]
                break
            if status.get("status_str") == "error":
                raise SystemExit("execution error: %s" % status.get("messages"))
    if not outputs:
        raise SystemExit("timeout waiting for %s" % prompt_id)

    os.makedirs(args.outdir, exist_ok=True)
    for value in outputs.values():
        for item in value.get("images", []):
            produced = os.path.join(args.comfy_out, item.get("subfolder", ""), item["filename"])
            if os.path.exists(produced):
                target = os.path.join(args.outdir, "%s_%s" % (args.tag, item["filename"]))
                shutil.copy2(produced, target)
                print("%.1fs  %s" % (time.time() - started, target), flush=True)


if __name__ == "__main__":
    main()
