#!/usr/bin/env python
"""
comfygen.py -- batch image generation front-end for a local ComfyUI instance.

Examples:
  python comfygen.py --family flux        --prompt "a blue whale girl eating rice" --batch 4 --out out/flux1
  python comfygen.py --family illustrious --prompt "1girl, blue hair, maid outfit" --steps 28 --cfg 6 --batch 8 --out out/il1
  python comfygen.py --family anima       --prompt "a blue whale girl in a server room" --steps 30 --batch 4 --out out/anima1

Design notes:
  - Talks to the ComfyUI HTTP API directly (default 127.0.0.1:8188); no third-party
    dependencies beyond the standard library.
  - One invocation can produce several images (--batch); all files land in the --out
    folder with monotonically increasing names.
  - Prints one TSV row per image: seconds per image and the image path, which upstream
    tooling (e.g. an automated visual filter) can consume directly.
"""
import argparse, json, os, shutil, sys, time, urllib.request, urllib.error

HOST = os.environ.get("COMFY_HOST", "http://127.0.0.1:8188")

# Root of the ComfyUI output folder. Override with the COMFY_OUT environment variable.
COMFY_OUT = os.environ.get("COMFY_OUT", os.path.join(os.path.expanduser("~"), "ComfyUI", "output"))

# ---- Model wiring for the three families (taken from official templates / measured, not guessed) ----
FLUX_UNET   = "flux1-schnell-fp8.safetensors"
FLUX_T5     = "t5xxl_fp8_e4m3fn.safetensors"
FLUX_CLIPL  = "clip_l.safetensors"
FLUX_VAE    = "ae.safetensors"
IL_CKPT     = "Illustrious-XL-v1.0.safetensors"
ANIMA_UNET  = "anima-base-v1.0.safetensors"
ANIMA_TURBO = "anima-turbo-v1.1.safetensors"
ANIMA_TE    = "qwen_3_06b_base.safetensors"
ANIMA_VAE   = "qwen_image_vae.safetensors"

DEFAULT_NEG = {
    "flux": "",
    "illustrious": "lowres, bad anatomy, bad hands, extra fingers, worst quality, low quality, jpeg artifacts, watermark, signature",
    "anima": "worst quality, low quality, score_1, score_2, score_3, blurry, jpeg artifacts, sepia",
}

def build_flux(a, seed):
    return {
        "1": {"class_type":"UNETLoader","inputs":{"unet_name":a.unet or FLUX_UNET,"weight_dtype":"default"}},
        "2": {"class_type":"DualCLIPLoader","inputs":{"clip_name1":FLUX_T5,"clip_name2":FLUX_CLIPL,"type":"flux"}},
        "3": {"class_type":"VAELoader","inputs":{"vae_name":FLUX_VAE}},
        "4": {"class_type":"CLIPTextEncode","inputs":{"text":a.prompt,"clip":["2",0]}},
        "5": {"class_type":"CLIPTextEncode","inputs":{"text":a.negative,"clip":["2",0]}},
        "6": {"class_type":"EmptyLatentImage","inputs":{"width":a.width,"height":a.height,"batch_size":a.batch}},
        "7": {"class_type":"KSampler","inputs":{"seed":seed,"steps":a.steps,"cfg":a.cfg,
             "sampler_name":a.sampler,"scheduler":a.scheduler,"denoise":1.0,
             "model":["1",0],"positive":["4",0],"negative":["5",0],"latent_image":["6",0]}},
        "8": {"class_type":"VAEDecode","inputs":{"samples":["7",0],"vae":["3",0]}},
        "9": {"class_type":"SaveImage","inputs":{"filename_prefix":a.prefix,"images":["8",0]}},
    }

def build_illustrious(a, seed):
    return {
        "1": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":a.ckpt or IL_CKPT}},
        "2": {"class_type":"CLIPTextEncode","inputs":{"text":a.prompt,"clip":["1",1]}},
        "3": {"class_type":"CLIPTextEncode","inputs":{"text":a.negative,"clip":["1",1]}},
        "4": {"class_type":"EmptyLatentImage","inputs":{"width":a.width,"height":a.height,"batch_size":a.batch}},
        "5": {"class_type":"KSampler","inputs":{"seed":seed,"steps":a.steps,"cfg":a.cfg,
             "sampler_name":a.sampler,"scheduler":a.scheduler,"denoise":1.0,
             "model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0]}},
        "6": {"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},
        "7": {"class_type":"SaveImage","inputs":{"filename_prefix":a.prefix,"images":["6",0]}},
    }

def build_anima(a, seed):
    # Official template image_anima_base_v1: UNETLoader + CLIPLoader (qwen text encoder,
    #   type=stable_diffusion) + VAELoader (qwen_image_vae) + a plain KSampler.
    #   The turbo checkpoint uses fewer steps and a lower cfg.
    unet = a.unet or (ANIMA_TURBO if a.turbo else ANIMA_UNET)
    return {
        "1": {"class_type":"UNETLoader","inputs":{"unet_name":unet,"weight_dtype":"default"}},
        "2": {"class_type":"CLIPLoader","inputs":{"clip_name":a.te or ANIMA_TE,"type":"stable_diffusion"}},
        "3": {"class_type":"VAELoader","inputs":{"vae_name":a.vae or ANIMA_VAE}},
        "4": {"class_type":"CLIPTextEncode","inputs":{"text":a.prompt,"clip":["2",0]}},
        "5": {"class_type":"CLIPTextEncode","inputs":{"text":a.negative,"clip":["2",0]}},
        "6": {"class_type":"EmptyLatentImage","inputs":{"width":a.width,"height":a.height,"batch_size":a.batch}},
        "7": {"class_type":"KSampler","inputs":{"seed":seed,"steps":a.steps,"cfg":a.cfg,
             "sampler_name":a.sampler,"scheduler":a.scheduler,"denoise":1.0,
             "model":["1",0],"positive":["4",0],"negative":["5",0],"latent_image":["6",0]}},
        "8": {"class_type":"VAEDecode","inputs":{"samples":["7",0],"vae":["3",0]}},
        "9": {"class_type":"SaveImage","inputs":{"filename_prefix":a.prefix,"images":["8",0]}},
    }

BUILDERS = {"flux": build_flux, "illustrious": build_illustrious, "anima": build_anima}

PRESETS = {
    "flux":        dict(steps=4,  cfg=1.0, sampler="euler",           scheduler="simple", width=1024, height=1024),
    "illustrious": dict(steps=28, cfg=6.0, sampler="euler_ancestral", scheduler="normal", width=832,  height=1216),
    "anima":       dict(steps=30, cfg=4.0, sampler="euler",           scheduler="simple", width=1024, height=1024),
}

def post(path, payload):
    req = urllib.request.Request(HOST+path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read().decode())

def get(path):
    return json.loads(urllib.request.urlopen(HOST+path, timeout=120).read().decode())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", required=True, choices=list(BUILDERS))
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--negative", default=None)
    ap.add_argument("--width", type=int, default=None)
    ap.add_argument("--height", type=int, default=None)
    ap.add_argument("--steps", type=int, default=None)
    ap.add_argument("--cfg", type=float, default=None)
    ap.add_argument("--sampler", default=None)
    ap.add_argument("--scheduler", default=None)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--prefix", default=None)
    ap.add_argument("--out", default=None, help="copy the images into this folder (default: leave them in the ComfyUI output folder)")
    ap.add_argument("--turbo", action="store_true", help="anima: use the turbo checkpoint")
    ap.add_argument("--unet", default=None, help="override the diffusion model filename")
    ap.add_argument("--ckpt", default=None)
    ap.add_argument("--te", default=None, help="override the text encoder filename")
    ap.add_argument("--vae", default=None)
    a = ap.parse_args()

    p = PRESETS[a.family]
    for k, v in p.items():
        if getattr(a, k) is None and k in ("width","height","steps","cfg","sampler","scheduler"):
            setattr(a, k, v)
    if a.negative is None: a.negative = DEFAULT_NEG[a.family]
    if a.prefix is None:   a.prefix = "gen_%s" % a.family
    seed = a.seed if a.seed is not None else int(time.time()) % (2**31)

    wf = BUILDERS[a.family](a, seed)
    t0 = time.time()
    r = post("/prompt", {"prompt": wf})
    pid = r["prompt_id"]
    print("# family=%s seed=%d batch=%d prompt_id=%s" % (a.family, seed, a.batch, pid), file=sys.stderr)

    out = None
    while time.time() - t0 < 3600:
        time.sleep(2)
        try:
            h = get("/history/"+pid)
        except Exception as e:
            print("# service did not respond: %s" % e, file=sys.stderr); return 3
        if pid in h:
            st = h[pid].get("status", {})
            if st.get("completed"):
                out = h[pid]["outputs"]; break
            if st.get("status_str") == "error":
                for m in st.get("messages", []):
                    if m[0] == "execution_error":
                        print("ERROR node=%s type=%s msg=%s" % (m[1].get("node_id"), m[1].get("node_type"), m[1].get("exception_message")), file=sys.stderr)
                return 3
    if not out:
        print("# timed out before completion", file=sys.stderr); return 3

    dt = time.time() - t0
    imgs = []
    for node, val in out.items():
        for im in val.get("images", []):
            imgs.append(im)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    for im in imgs:
        src = os.path.join(COMFY_OUT, im.get("subfolder", ""), im["filename"])
        dst = src
        if a.out:
            dst = os.path.join(a.out, im["filename"])
            shutil.copy2(src, dst)
        size_mb = os.path.getsize(dst)/1024/1024 if os.path.exists(dst) else 0
        print("%.1f\t%s\t%.2fMB" % (dt/len(imgs), dst, size_mb))

main()
