#!/usr/bin/env python3
"""Blender 5.x: create an original synthetic garment interchange acceptance source.

Run with Blender --background --python this-file -- --output /absolute/folder
Optional --base imports the native procedural regression GLB before refinement.
No supplier model, external image, addon download, hardware or network is used.
Generated .blend/.glb/.png remain outside git; the authoring script is the source.
"""
import argparse
import json
import math
import os
import sys
from pathlib import Path

import bpy
from mathutils import Vector

args = argparse.ArgumentParser()
args.add_argument("--output", required=True)
args.add_argument("--base", required=True)
options = args.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
out = Path(options.output).resolve()
out.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.scale_length = 1.0
bpy.ops.import_scene.gltf(filepath=str(Path(options.base).resolve()))
root = next(o for o in scene.objects if o.type == "EMPTY")
root.name = "LAB / original synthetic flight jacket / Blender refined"
root["provenance"] = "Original procedural regression design refined in Blender; not a supplier garment or sewing pattern."
root["source_units"] = "meter"
root["acceptance_purpose"] = "static mesh hierarchy, curved normals, UV textures, material groups and independent patch"

# Refine the shoulder transition in the actual imported Blender mesh.
torso = next(o for o in scene.objects if "curved torso" in o.name)
height_axis = 1 if max(v.co.y for v in torso.data.vertices) > 0.4 else 2
for vertex in torso.data.vertices:
    # Handle both importer strategies: converted mesh coordinates or conversion root.
    y = vertex.co[height_axis]
    if y > 0.46:
        t = min(1.0, (y - 0.46) / 0.12)
        vertex.co.x *= 1.0 - 0.36 * (t * t * (3 - 2 * t))
torso.data.update()
# Extend sleeve roots beneath the shoulder shell so open tube ends are concealed.
for sleeve in [o for o in scene.objects if o.type == "MESH" and "sleeve" in o.name.lower()]:
    for vertex in sleeve.data.vertices:
        sign = -1 if vertex.co.x < 0 else 1
        t = max(0.0, min(1.0, (abs(vertex.co.x) - 0.25) / 0.34))
        vertex.co.x -= sign * 0.13 * (1 - t) ** 2
    sleeve.data.update()
    if sleeve.data.has_custom_normals:
        sleeve.data.normals_split_custom_set([(0, 0, 0)] * len(sleeve.data.loops))
if torso.data.has_custom_normals:
    torso.data.normals_split_custom_set([(0, 0, 0)] * len(torso.data.loops))

# All detail coordinates below are authored in Blender world meters, Z-up/front -Y.
def material(name, color, metal=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*color, 1)
    return m

thread = material("Warm grey seam thread / original", (0.22, 0.235, 0.25), rough=0.9)
brass = material("Satin warm metal / original", (0.52, 0.36, 0.16), metal=0.85, rough=0.32)
patch = material("Burnt orange woven patch / original", (0.58, 0.14, 0.035), rough=0.85)
ink = material("Cream embroidered type / original", (0.88, 0.82, 0.65), rough=0.85)
pocket = material("Midnight welt / original", (0.038, 0.052, 0.072), rough=0.62)
lining = material("Warm lining / original", (0.22, 0.09, 0.04), rough=0.8)

# Replace the tiny debug weave with actual Blender-authored packed texture pixels.
shell = next(m for m in bpy.data.materials if "midnight shell" in m.name)
bsdf = shell.node_tree.nodes.get("Principled BSDF")
base_node = next(n for n in shell.node_tree.nodes if n.type == "TEX_IMAGE" and n.image and "normal" not in n.image.name.lower())
image = bpy.data.images.new("LAB original 256px midnight weave", width=256, height=256, alpha=True)
pixels = []
for y in range(256):
    for x in range(256):
        cross = ((x // 3 + y // 3) % 2)
        stripe = math.sin(x * math.pi / 3) * 0.010 + math.sin(y * math.pi / 3) * 0.008
        v = 0.065 + stripe * 0.35 + 0.004 * cross
        pixels.extend((v * 0.88, v * 0.99, v * 1.14, 1.0))
image.pixels = pixels
image.pack()
base_node.image = image
bsdf.inputs["Roughness"].default_value = 0.62
normal_node = next((n for n in shell.node_tree.nodes if n.type == "NORMAL_MAP"), None)
if normal_node:
    normal_node.inputs["Strength"].default_value = 0.4

# Geometry helper: bevelled genuine mesh parts, curves converted before interchange export.
def own(obj, name, mat=None):
    obj.name = name
    obj["original_synthetic_detail"] = True
    if mat:
        obj.data.materials.clear()
        obj.data.materials.append(mat)
    # Evaluate newly assigned text/curve transforms before retaining world placement.
    bpy.context.view_layer.update()
    # Keep transform while parenting to imported conversion root.
    world = obj.matrix_world.copy()
    obj.parent = root
    obj.matrix_world = world
    return obj

def box(name, center, size, mat, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    obj = bpy.context.object
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        mod = obj.modifiers.new("Soft sewn edge", "BEVEL")
        mod.width = bevel
        mod.segments = 3
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
    for poly in obj.data.polygons:
        poly.use_smooth = bevel > 0
    return own(obj, name, mat)

def path(name, points, mat, radius=0.001):
    data = bpy.data.curves.new(name, "CURVE")
    data.dimensions = "3D"
    data.resolution_u = 2
    data.bevel_depth = radius
    data.bevel_resolution = 2
    curve = data.splines.new("POLY")
    curve.points.add(len(points) - 1)
    for p, xyz in zip(curve.points, points):
        p.co = (*xyz, 1)
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    return own(obj, name, mat)

# Remove the flat debug zipper/patch; replace them with real independent mesh components.
for obj in list(scene.objects):
    if obj.type == "MESH" and ("Front zipper" in obj.name or "Separate chest patch" in obj.name):
        bpy.data.objects.remove(obj, do_unlink=True)

# Narrow zipper tape follows curved front instead of floating ahead of the body.
def front_depth(z):
    t = max(0.0, min(1.0, z / 0.58))
    return -(0.105 + 0.02 * math.sin(t * math.pi) + 0.0025)
zipper_points = [(0, front_depth(0.04 + i * 0.51 / 64), 0.04 + i * 0.51 / 64) for i in range(65)]
path("Front zipper / dark textile tape", zipper_points, pocket, 0.006)
for side in (-1, 1):
    points = [(side * 0.011, front_depth(z), z) for _, _, z in zipper_points]
    path("Front zipper / parallel stitched seam " + str(side), points, thread, 0.00065)
# Joined tooth geometries preserve one meaningful source part instead of 180 tiny nodes.
teeth = []
for i in range(86):
    z = 0.045 + i * 0.0058
    for sign in (-1, 1):
        tooth = box("zip tooth", (sign * 0.0026, front_depth(z) - 0.001, z), (0.0045, 0.0035, 0.0028), brass, 0.0005)
        teeth.append(tooth)
bpy.ops.object.select_all(action="DESELECT")
for tooth in teeth:
    tooth.select_set(True)
bpy.context.view_layer.objects.active = teeth[0]
bpy.ops.object.join()
teeth[0].name = "Front zipper / 172 individual metal teeth"
slider = box("Zipper slider", (0, front_depth(0.49) - 0.004, 0.49), (0.012, 0.009, 0.018), brass, 0.002)
path("Zipper pull / rounded loop", [(0, -0.141, 0.488), (-0.005, -0.146, 0.476), (-0.004, -0.147, 0.463), (0.004, -0.147, 0.463), (0.005, -0.146, 0.476), (0, -0.141, 0.488)], brass, 0.0014)

# Real rounded patch mesh and visible embroidered border/type.
plate = box("Independent chest patch / LAB FLIGHT 01", (0.112, -0.127, 0.397), (0.099, 0.0035, 0.076), patch, 0.006)
# The patch has an authored full-face UV0, so linked artwork covers its front predictably.
uv_layer = plate.data.uv_layers.active or plate.data.uv_layers.new(name="Patch front UV0")
for loop in plate.data.loops:
    vertex = plate.data.vertices[loop.vertex_index].co
    uv_layer.data[loop.index].uv = (vertex.x / 0.099 + 0.5, vertex.z / 0.076 + 0.5)
# World text defaults face +Z; rotate to face Blender -Y.
def text(name, content, position, size):
    data = bpy.data.curves.new(name, "FONT")
    data.body = content
    data.size = size
    data.align_x = "CENTER"
    data.align_y = "CENTER"
    data.extrude = 0.00035
    data.bevel_depth = 0.00015
    data.bevel_resolution = 1
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (math.pi / 2, 0, 0)
    return own(obj, name, ink)
text("Patch embroidery / LAB", "LAB", (0.112, -0.130, 0.410), 0.024)
text("Patch embroidery / FLIGHT 01", "FLIGHT 01", (0.112, -0.130, 0.385), 0.009)
# Individual border stitches, joined into one source component.
stitches = []
for side in (-1, 1):
    for i in range(25):
        x = 0.068 + i * 0.0036
        stitches.append(box("patch stitch", (x, -0.130, 0.397 + side * 0.032), (0.0022, 0.001, 0.0008), ink))
    for i in range(17):
        z = 0.367 + i * 0.0036
        stitches.append(box("patch stitch", (0.112 + side * 0.044, -0.130, z), (0.0008, 0.001, 0.0022), ink))
bpy.ops.object.select_all(action="DESELECT")
for obj in stitches:
    obj.select_set(True)
bpy.context.view_layer.objects.active = stitches[0]
bpy.ops.object.join()
stitches[0].name = "Patch border / 84 individual sewn stitches"

# Angled welt pockets and twin seam lines fitted against the front's ellipsoid.
for sign, label in [(-1, "left"), (1, "right")]:
    pocket_points = []
    for i in range(31):
        t = i / 30
        x, z = sign * (0.065 + t * 0.105), 0.20 + t * 0.074
        radius = 0.22 + 0.055 * math.sin(z / 0.58 * math.pi * 0.8)
        y = front_depth(z) * math.sqrt(max(0.0, 1 - (x / radius) ** 2)) - 0.002
        pocket_points.append((x, y, z))
    path("Pocket welt / " + label, pocket_points, pocket, 0.005)
    for delta in (-0.006, 0.006):
        path("Pocket seam / " + label + str(delta), [(x, y - 0.001, z + delta) for x, y, z in pocket_points], thread, 0.0006)

# Curved seams and rib channels are actual geometry, independent of lighting/render-only nodes.
for sign in (-1, 1):
    pts = []
    for i in range(65):
        z = 0.05 + i * 0.47 / 64
        radius = 0.22 + 0.055 * math.sin(z / 0.58 * math.pi * 0.8)
        x = sign * radius * 0.89
        y = front_depth(z) * math.sqrt(1 - 0.89 ** 2) - 0.001
        pts.append((x, y, z))
    path("Curved side seam / " + str(sign), pts, thread, 0.00075)
    for offset in (-0.008, 0.008):
        pts = [(sign * (0.28 + t * 0.29 - 0.13 * (1 - t) ** 2), -(0.075 - 0.025 * t) - 0.001, 0.49 - 0.24 * t + offset) for t in [i / 64 for i in range(65)]]
        path("Sleeve double seam / " + str(sign) + str(offset), pts, thread, 0.0006)
for z in (-0.012, 0.018):
    pts = [(0.224 * math.cos(t), -0.109 * math.sin(t), z) for t in [i * 2 * math.pi / 128 for i in range(129)]]
    path("Waist double topstitch / " + str(z), pts, thread, 0.00065)
# A separate neck label helps verify small source pieces survive import/reopen.
box("Separate woven neck label", (0, -0.099, 0.555), (0.055, 0.002, 0.017), ink, 0.0015)
text("Neck label / ORIGINAL LAB", "ORIGINAL LAB", (0, -0.1005, 0.555), 0.005)

# Freeze all authoring curves/fonts as genuine exportable UV-capable geometry.
for obj in list(scene.objects):
    if obj.type in {"CURVE", "FONT"}:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.convert(target="MESH")
for obj in scene.objects:
    if obj.type == "MESH":
        if not obj.data.uv_layers:
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.mode_set(mode="EDIT")
            bpy.ops.mesh.select_all(action="SELECT")
            bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
            bpy.ops.object.mode_set(mode="OBJECT")

# Source render setup is excluded from GLB through explicit mesh-only selection.
world = bpy.data.worlds.new("Neutral source comparison world")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.36, 0.39, 0.43, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.45
scene.world = world

def area(name, location, energy, size):
    light = bpy.data.lights.new(name, "AREA")
    light.energy = energy
    light.shape = "DISK"
    light.size = size
    obj = bpy.data.objects.new(name, light)
    scene.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector((0, 0, 0.3)) - obj.location).to_track_quat("-Z", "Y").to_euler()
area("Source softbox / key", (-1.5, -2.0, 2.2), 170, 2.3)
area("Source softbox / fill", (1.6, -0.6, 1.0), 90, 1.8)
area("Source softbox / rim", (0.2, 1.4, 1.7), 180, 1.4)
camera_data = bpy.data.cameras.new("Source comparison orthographic camera")
camera = bpy.data.objects.new("Source comparison orthographic camera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0.72, -2.6, 0.78)
target = Vector((0, 0, 0.29))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.type = "ORTHO"
camera_data.ortho_scale = 1.48
scene.camera = camera
scene.render.engine = "CYCLES"
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x = 1200
scene.render.resolution_y = 1000
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
scene.render.filepath = str(out / "LAB-Blender-flight-jacket-source.png")

meshes = [o for o in scene.objects if o.type == "MESH"]
vertices = sum(len(o.data.vertices) for o in meshes)
triangles = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in meshes)
points = [o.matrix_world @ Vector(v) for o in meshes for v in o.bound_box]
minimum = [min(p[i] for p in points) for i in range(3)]
maximum = [max(p[i] for p in points) for i in range(3)]
# Packed pixels and authored text/curves make this .blend a complete local source.
for image in bpy.data.images:
    if image.source != "VIEWER" and image.has_data:
        try:
            image.pack()
        except RuntimeError:
            pass
bpy.ops.wm.save_as_mainfile(filepath=str(out / "LAB-Blender-flight-jacket.blend"))
bpy.ops.object.select_all(action="DESELECT")
for obj in meshes:
    obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=str(out / "LAB-Blender-flight-jacket.glb"), export_format="GLB", use_selection=True,
                          export_yup=True, export_apply=True, export_texcoords=True, export_normals=True,
                          export_tangents=True, export_materials="EXPORT", export_animations=False,
                          export_skins=False, export_morph=False, export_extras=True,
                          export_draco_mesh_compression_enable=False, export_cameras=False, export_lights=False)
manifest = {
    "provenance": "Original synthetic LAB garment, refined and exported in Blender; not supplier reconstruction or manufacturing pattern.",
    "blender_version": bpy.app.version_string,
    "source_unit": "meter", "source_axis": "Blender Z-up; GLB export right-handed Y-up",
    "mesh_objects": len(meshes), "source_vertices": vertices, "source_triangles": triangles,
    "parts": [o.name for o in meshes],
    "materials": sorted({m.name for o in meshes for m in o.data.materials if m}),
    "blender_bounds_meter": {"minimum": minimum, "maximum": maximum},
    "source_camera_gltf_meter": {"from": [camera.location.x, camera.location.z, -camera.location.y], "target": [target.x, target.z, -target.y], "up": [0, 1, 0], "orthographic_height_meter": camera_data.ortho_scale * 1000 / 1200},
    "render": {"resolution": [1200, 1000], "engine": "Cycles", "samples": 32, "color_transform": "Standard sRGB", "note": "Renderer/lighting comparison is visual, not a pixel-identical cross-engine claim."},
}
(out / "LAB-Blender-flight-jacket-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
bpy.ops.render.render(write_still=True)
print("LAB_BLENDER_JACKET_ACCEPTANCE", json.dumps({"parts":len(meshes),"vertices":vertices,"triangles":triangles,"glb":str(out / "LAB-Blender-flight-jacket.glb")}))
