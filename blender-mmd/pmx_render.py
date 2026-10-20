# -*- coding: utf-8 -*-
"""Import a PMX model with mmd_tools, repair texture paths, light it, render one frame.

Run headless:
    blender -b --python pmx_render.py -- --pmx <model.pmx> --out <frame.png> [options]

Options:
    --width / --height   output size (default 1080x1440)
    --samples            EEVEE TAA samples (default 64)
    --scale              mmd_tools import scale (default 0.08)
    --tex-from/--tex-to  rewrite texture root, e.g. --tex-from 'D:/old' --tex-to 'E:/new'

Why this script exists: a PMX stores absolute texture paths from the author's machine.
After import every image points at a directory that does not exist, materials render
pink/black, and the cause is not visible in the render itself. Rewriting the root is
the only reliable fix; guessing filenames is not.
"""
import argparse
import sys

import bpy
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--pmx", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--width", type=int, default=1080)
    p.add_argument("--height", type=int, default=1440)
    p.add_argument("--samples", type=int, default=64)
    p.add_argument("--scale", type=float, default=0.08)
    p.add_argument("--tex-from", default="")
    p.add_argument("--tex-to", default="")
    return p.parse_args(argv)


def enable_mmd_tools():
    # Extension IDs changed in Blender 4.2; try both spellings.
    for mod in ("bl_ext.blender_org.mmd_tools", "mmd_tools"):
        try:
            bpy.ops.preferences.addon_enable(module=mod)
            print("ADDON ENABLED", mod, flush=True)
            return True
        except Exception as exc:  # noqa: BLE001
            print("ADDON FAIL", mod, exc, flush=True)
    return False


def repair_textures(tex_from, tex_to):
    if not tex_from or not tex_to:
        return 0
    fixed = 0
    for im in bpy.data.images:
        fp = im.filepath or ""
        if fp.startswith(tex_from):
            im.filepath = tex_to + fp[len(tex_from):]
            try:
                im.reload()
            except Exception:  # noqa: BLE001
                pass
            fixed += 1
    print("TEXTURES REWRITTEN", fixed, flush=True)
    return fixed


def add_area(name, loc, energy, size, color, target):
    bpy.ops.object.light_add(type="AREA", location=loc)
    light = bpy.context.active_object
    light.name = name
    light.data.energy = energy
    light.data.size = size
    light.data.color = color
    direction = target - light.location
    light.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    return light


def main():
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    if not enable_mmd_tools():
        raise SystemExit("mmd_tools not available")

    bpy.ops.mmd_tools.import_model(filepath=args.pmx, scale=args.scale,
                                   types={"MESH", "ARMATURE"},
                                   rename_bones=False, log_level="ERROR")
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh imported")

    repair_textures(args.tex_from, args.tex_to)

    mins = Vector((1e9, 1e9, 1e9))
    maxs = Vector((-1e9, -1e9, -1e9))
    for obj in meshes:
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            mins = Vector((min(mins.x, world.x), min(mins.y, world.y), min(mins.z, world.z)))
            maxs = Vector((max(maxs.x, world.x), max(maxs.y, world.y), max(maxs.z, world.z)))
    height = maxs.z - mins.z
    center = (mins + maxs) / 2
    print("BBOX", tuple(round(v, 2) for v in mins), tuple(round(v, 2) for v in maxs), flush=True)

    bpy.ops.mesh.primitive_plane_add(size=height * 6,
                                     location=(center.x, center.y, mins.z - 0.01))
    ground = bpy.context.active_object
    mat = bpy.data.materials.new("ground")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (0.22, 0.23, 0.26, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.6
    ground.data.materials.append(mat)

    cam_dist = height * 2.6
    bpy.ops.object.camera_add(location=(center.x, center.y - cam_dist,
                                        mins.z + height * 0.52))
    cam = bpy.context.active_object
    cam.data.lens = 60.0
    direction = center - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam

    target = Vector((center.x, center.y, mins.z + height * 0.55))
    add_area("key", (center.x + height * 1.3, center.y - height * 1.4, mins.z + height * 1.5),
             height * height * 55, height * 0.35, (1.0, 0.75, 0.55), target)
    add_area("fill", (center.x - height * 1.6, center.y - height * 0.8, mins.z + height * 0.9),
             height * height * 18, height * 0.5, (0.45, 0.65, 1.0), target)
    add_area("rim", (center.x, center.y + height * 1.5, mins.z + height * 1.7),
             height * height * 30, height * 0.3, (0.8, 0.9, 1.0), target)

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.08, 0.10, 0.14, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.5

    # Engine name changed to BLENDER_EEVEE_NEXT in 4.2; keep the old name as fallback.
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    try:
        scene.eevee.taa_render_samples = args.samples
        scene.eevee.use_gtao = True
        scene.eevee.use_raytracing = True
    except Exception as exc:  # noqa: BLE001
        print("EEVEE OPTION SKIPPED", exc, flush=True)

    scene.render.resolution_x = args.width
    scene.render.resolution_y = args.height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = args.out
    print("RENDER START", flush=True)
    bpy.ops.render.render(write_still=True)
    print("RENDER DONE", args.out, flush=True)


if __name__ == "__main__":
    main()
