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

# Root of the ComfyUI input folder. A LoadImage node only accepts a file name that is
#   already present here, so --init-image has to copy the file in (see stage_init_image).
COMFY_INPUT = os.environ.get("COMFY_INPUT", os.path.join(os.path.expanduser("~"), "ComfyUI", "input"))

# Node ids used by the optional wiring helpers. The three family graphs above only use
#   1..9, so these never collide with a base node.
LORA_NODE           = "90"
UPSCALE_LOADER_NODE = "91"
UPSCALE_APPLY_NODE  = "92"
HIRES_UP            = "95"
HIRES_SAMP          = "96"
IMG_NODE            = "80"
IMG_ENCODE          = "81"

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
    wf = {
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
    model_ref, clip_ref = wire_lora(wf, a, ["1", 0], ["2", 0])
    wf["4"]["inputs"]["clip"] = clip_ref
    wf["5"]["inputs"]["clip"] = clip_ref
    wf["7"]["inputs"]["model"] = model_ref
    wire_hires(wf, a, "7", model_ref, ["4", 0], ["5", 0], "8")
    wire_img2img(wf, a, ["3", 0])
    return wf

def build_illustrious(a, seed):
    wf = {
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
    model_ref, clip_ref = wire_lora(wf, a, ["1", 0], ["1", 1])
    wf["2"]["inputs"]["clip"] = clip_ref
    wf["3"]["inputs"]["clip"] = clip_ref
    wf["5"]["inputs"]["model"] = model_ref
    wire_hires(wf, a, "5", model_ref, ["2", 0], ["3", 0], "6")
    wire_img2img(wf, a, ["1", 2])
    return wf

def build_anima(a, seed):
    # Official template image_anima_base_v1: UNETLoader + CLIPLoader (qwen text encoder,
    #   type=stable_diffusion) + VAELoader (qwen_image_vae) + a plain KSampler.
    #   The turbo checkpoint uses fewer steps and a lower cfg.
    unet = a.unet or (ANIMA_TURBO if a.turbo else ANIMA_UNET)
    wf = {
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
    model_ref, clip_ref = wire_lora(wf, a, ["1", 0], ["2", 0])
    wf["4"]["inputs"]["clip"] = clip_ref
    wf["5"]["inputs"]["clip"] = clip_ref
    wf["7"]["inputs"]["model"] = model_ref
    wire_hires(wf, a, "7", model_ref, ["4", 0], ["5", 0], "8")
    wire_img2img(wf, a, ["3", 0])
    return wf

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

def wire_lora(wf, a, model_ref, clip_ref):
    """Insert a LoraLoader between the base model and its consumers.

    Returns (model_ref, clip_ref); without --lora both are passed through unchanged.
    The node id is fixed (LORA_NODE) because the base graphs only use 1..9.
    """
    if not a.lora:
        return model_ref, clip_ref
    wf[LORA_NODE] = {"class_type": "LoraLoader", "inputs": {
        "lora_name": a.lora,
        "strength_model": a.lora_strength,
        "strength_clip": a.lora_strength,
        "model": list(model_ref),
        "clip": list(clip_ref),
    }}
    return [LORA_NODE, 0], [LORA_NODE, 1]

def wire_hires(wf, a, base_sampler, model_ref, pos_ref, neg_ref, decode_id):
    """hires fix: base sample -> latent upscale -> second sample -> decode.

    --hires is the scale factor (anything <= 1.0 disables the pass). The second sample
    reuses the seed/steps/cfg/sampler of the base sample; its denoise comes from
    --hires-denoise (default 0.5). The VAEDecode node given as decode_id is re-pointed at
    the second sample.
    """
    if not a.hires or a.hires <= 1.0:
        return
    base = wf[base_sampler]["inputs"]
    wf[HIRES_UP] = {"class_type": "LatentUpscaleBy", "inputs": {
        "samples": [base_sampler, 0],
        "upscale_method": "nearest-exact",
        "scale_by": a.hires,
    }}
    wf[HIRES_SAMP] = {"class_type": "KSampler", "inputs": {
        "seed": base["seed"], "steps": base["steps"], "cfg": base["cfg"],
        "sampler_name": base["sampler_name"], "scheduler": base["scheduler"],
        "denoise": a.hires_denoise,
        "model": list(model_ref), "positive": list(pos_ref), "negative": list(neg_ref),
        "latent_image": [HIRES_UP, 0],
    }}
    wf[decode_id]["inputs"]["samples"] = [HIRES_SAMP, 0]

def stage_init_image(a):
    """A LoadImage node only accepts a file name that already sits in the ComfyUI input
    folder, so an absolute --init-image path is copied there first. The copy gets an i2i_
    prefix to avoid colliding with an existing file of the same name.
    """
    if not a.init_image:
        return
    if os.path.isabs(a.init_image) and os.path.exists(a.init_image):
        os.makedirs(COMFY_INPUT, exist_ok=True)
        base = "i2i_" + os.path.basename(a.init_image)
        dst = os.path.join(COMFY_INPUT, base)
        shutil.copy2(a.init_image, dst)
        print("# init image staged: %s" % dst, file=sys.stderr)
        a.init_image = base

def wire_img2img(wf, a, vae_ref):
    """--init-image: replace EmptyLatentImage with LoadImage -> VAEEncode so that the base
    sample becomes a denoise<1 repaint of the given image.

    Rationale: generating a second image from the same seed drifts the whole background
    (measured: 18 candidates, background delta 45-100, none better than the baseline).
    Growing the second frame out of the first keeps the background by construction and
    only changes the pose. Only the sampler that consumed EmptyLatentImage is re-pointed,
    so a hires second pass is not affected.
    """
    if not a.init_image:
        return
    empty_id = None
    for nid, node in wf.items():
        if isinstance(node, dict) and node.get("class_type") == "EmptyLatentImage":
            empty_id = nid
            break
    if empty_id is None:
        print("# EmptyLatentImage not found, --init-image not wired", file=sys.stderr)
        return
    wf[IMG_NODE] = {"class_type": "LoadImage", "inputs": {"image": a.init_image}}
    wf[IMG_ENCODE] = {"class_type": "VAEEncode",
                      "inputs": {"pixels": [IMG_NODE, 0], "vae": list(vae_ref)}}
    for nid, node in wf.items():
        if isinstance(node, dict) and node.get("class_type") == "KSampler":
            ref = node["inputs"].get("latent_image")
            if isinstance(ref, list) and ref[0] == empty_id:
                node["inputs"]["latent_image"] = [IMG_ENCODE, 0]
                node["inputs"]["denoise"] = a.denoise

def wire_upscale(wf, a):
    """Insert a pure ESRGAN image upscale in front of SaveImage (scale only, no repaint).

    Difference from --hires (measured):
      --hires     latent upscale + second sample: 46 s for 1.85x, repaints the image
                  (elements drift, hands break)
      --upscale   ESRGAN image upscale: 2-3 s for a fixed 4x, pixels untouched
    """
    if not a.upscale:
        return
    save_id = None
    for nid, node in wf.items():
        if isinstance(node, dict) and node.get("class_type") == "SaveImage":
            save_id = nid
            break
    if save_id is None:
        print("# SaveImage not found, --upscale not wired", file=sys.stderr)
        return
    src_ref = wf[save_id]["inputs"]["images"]
    wf[UPSCALE_LOADER_NODE] = {"class_type": "UpscaleModelLoader",
                               "inputs": {"model_name": a.upscale}}
    wf[UPSCALE_APPLY_NODE] = {"class_type": "ImageUpscaleWithModel",
                              "inputs": {"upscale_model": [UPSCALE_LOADER_NODE, 0],
                                         "image": src_ref}}
    wf[save_id]["inputs"]["images"] = [UPSCALE_APPLY_NODE, 0]


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
    ap.add_argument("--lora", default=None, help="LoRA file name (relative to models/loras)")
    ap.add_argument("--lora-strength", type=float, default=0.8, dest="lora_strength",
                    help="LoRA strength applied to both model and clip (default 0.8)")
    ap.add_argument("--hires", type=float, default=0.0,
                    help="hires fix scale factor (e.g. 1.5 / 1.8; <=1.0 disables it)")
    ap.add_argument("--hires-denoise", type=float, default=0.5, dest="hires_denoise",
                    help="denoise of the hires second pass (default 0.5; higher repaints more)")
    ap.add_argument("--init-image", default=None, dest="init_image",
                    help="img2img base image (absolute path, or a file name already in the ComfyUI input folder); combine with --denoise")
    ap.add_argument("--denoise", type=float, default=0.7,
                    help="img2img repaint strength (only used together with --init-image; default 0.7)")
    ap.add_argument("--upscale", default=None,
                    help="pure ESRGAN image upscale (file name under models/upscale_models, e.g. RealESRGAN_x4plus_anime_6B.pth or realesr-animevideov3.pth); fixed 4x, scales without repainting -- 15-23x faster than --hires")
    a = ap.parse_args()

    p = PRESETS[a.family]
    for k, v in p.items():
        if getattr(a, k) is None and k in ("width","height","steps","cfg","sampler","scheduler"):
            setattr(a, k, v)
    if a.negative is None: a.negative = DEFAULT_NEG[a.family]
    if a.prefix is None:   a.prefix = "gen_%s" % a.family
    seed = a.seed if a.seed is not None else int(time.time()) % (2**31)

    stage_init_image(a)
    wf = BUILDERS[a.family](a, seed)
    wire_upscale(wf, a)
    t0 = time.time()
    r = post("/prompt", {"prompt": wf})
    pid = r["prompt_id"]
    print("# family=%s lora=%s strength=%s hires=%s upscale=%s seed=%d batch=%d size=%dx%d prompt_id=%s"
          % (a.family, a.lora or "-", a.lora_strength if a.lora else "-",
             a.hires if a.hires > 1.0 else "-", a.upscale or "-",
             seed, a.batch, a.width, a.height, pid), file=sys.stderr)

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
