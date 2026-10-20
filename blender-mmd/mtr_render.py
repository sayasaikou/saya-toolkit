# -*- coding: utf-8 -*-
"""Render an MMD character through the MMD Template Renderer extension.

Run headless:
    blender -b --python mtr_render.py -- --pmx <model.pmx> --tex-dir <dir> --out <frame.png>

Required extensions:
    bl_ext.blender_org.mmd_tools      (imports PMX)
    mmd_template_renderer             (material mapping + toon render)

Known limits of the template path (measured):
    - It only recognises material names matching Cloth\\d+(Alpha)?; Cloth10 is not matched.
    - The output is flatter than the manually lit EEVEE path: no toon gradient, no outline.
    - iris_mode must be set to RAW_A or the eye materials map incorrectly.
"""
import argparse
import os
import sys

import bpy
from mathutils import Vector


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--pmx", required=True)
    p.add_argument("--tex-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--width", type=int, default=2160)
    p.add_argument("--height", type=int, default=3840)
    p.add_argument("--scale", type=float, default=0.08)
    return p.parse_args(argv)


def main():
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    for mod in ("bl_ext.blender_org.mmd_tools", "mmd_tools"):
        try:
            bpy.ops.preferences.addon_enable(module=mod)
            break
        except Exception as exc:  # noqa: BLE001
            print("ADDON FAIL", mod, exc, flush=True)
    try:
        bpy.ops.preferences.addon_enable(module="mmd_template_renderer")
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("mmd_template_renderer not available: %s" % exc)

    bpy.ops.mmd_tools.import_model(filepath=args.pmx, scale=args.scale,
                                   types={"MESH", "ARMATURE"},
                                   rename_bones=False, log_level="ERROR")
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh imported")

    mins = Vector((1e9,) * 3)
    maxs = Vector((-1e9,) * 3)
    for obj in meshes:
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            mins = Vector((min(mins.x, world.x), min(mins.y, world.y), min(mins.z, world.z)))
            maxs = Vector((max(maxs.x, world.x), max(maxs.y, world.y), max(maxs.z, world.z)))
    height = maxs.z - mins.z
    center = (mins + maxs) / 2
    print("H", round(height, 3), flush=True)

    bpy.ops.mesh.primitive_plane_add(size=height * 8,
                                     location=(center.x, center.y, mins.z - 0.01))
    ground = bpy.context.active_object
    mat = bpy.data.materials.new("gnd")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (0.18, 0.19, 0.22, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.6
    ground.data.materials.append(mat)

    # The extension expects a SUN light as the body/face light.
    bpy.ops.object.light_add(type="SUN", location=(center.x + 3, center.y - 3, mins.z + 6))
    sun = bpy.context.active_object
    sun.name = "body_sun"
    sun.data.energy = 4.0
    sun.data.color = (1.0, 0.88, 0.72)
    sun.data.angle = 0.14
    import math
    sun.rotation_euler = (math.radians(52), 0, math.radians(35))

    bpy.ops.object.light_add(type="POINT",
                             location=(center.x - height * 1.2, center.y - height * 1.0,
                                       mins.z + height * 0.9))
    fill = bpy.context.active_object
    fill.name = "fill_point"
    fill.data.energy = 60.0
    fill.data.color = (0.45, 0.65, 1.0)
    fill.data.shadow_soft_size = 0.6

    cam_dist = height * 3.6
    bpy.ops.object.camera_add(location=(center.x + height * 0.15, center.y - cam_dist,
                                        mins.z + height * 0.50))
    cam = bpy.context.active_object
    cam.data.lens = 50.0
    direction = Vector((center.x, center.y, mins.z + height * 0.50)) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam

    import mmd_template_renderer.mapping as mapping

    root = mapping.find_root(meshes[0])
    print("MTR root:", root.name if root else None, flush=True)
    if root is None:
        raise SystemExit("find_root failed")

    root.mtr.texture_dir = args.tex_dir
    root.mtr.body_light = sun
    root.mtr.face_light = sun
    try:
        root.mtr.fill1 = fill
    except Exception:  # noqa: BLE001
        pass
    root.mtr.auto_camera = False
    root.mtr.reference_preset = True
    root.mtr.iris_mode = "RAW_A"
    print("MTR cfg: tex=", root.mtr.texture_dir, flush=True)

    try:
        st = scene.mtr_scene
        if len(st.sources) == 0:
            source = st.sources.add()
            source.obj = root
        print("MTR sources:", len(st.sources), flush=True)
    except Exception as exc:  # noqa: BLE001
        print("SOURCES FAIL", exc, flush=True)

    for obj in bpy.data.objects:
        obj.select_set(False)
    root.select_set(True)
    bpy.context.view_layer.objects.active = root

    # Build the material map, then patch the roles the regex misses.
    try:
        mapping.inspect(root)
        fixed = 0
        for row in root.mtr.mapping:
            if not row.material:
                continue
            role = getattr(row, "role", "AUTO")
            if role not in ("AUTO", ""):
                continue
            name = row.material.name.lower()
            if name.startswith("cloth1"):
                row.role = "CLOTH_METAL"
                fixed += 1
            elif name.startswith("cloth"):
                row.role = "CLOTH"
                fixed += 1
        print("MAPPING fixed:", fixed, "rows:", len(root.mtr.mapping), flush=True)
    except Exception as exc:  # noqa: BLE001
        print("MAPPING FAIL", exc, flush=True)

    for action in ("CHECK", "APPLY", "RENDER"):
        try:
            result = bpy.ops.mtr.action(action=action)
            print("MTR", action, result, flush=True)
        except Exception as exc:  # noqa: BLE001
            print("MTR FAIL", action, exc, flush=True)

    if os.path.exists(args.out):
        os.remove(args.out)
    img = bpy.data.images.get("Render Result")
    if img:
        img.save_render(args.out)
        print("SAVED", args.out, flush=True)
    else:
        raise SystemExit("no Render Result")


if __name__ == "__main__":
    main()
