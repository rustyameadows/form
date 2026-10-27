#!/usr/bin/env python3
"""Author an original 180 x 110 x 45 mm receiver in Blender; no external model/images.

Blender --background --threads 2 --python scripts/generate_blender_device_fixture.py --
  --output .local/cad-foundation/fixtures/blender-device
The complete .blend, static GLB, fixed source render and measured manifest are local outputs.
This is an original visual/mechanical acceptance fixture, not a supplier or electronics design.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.scale_length = 1.0
root = bpy.data.objects.new("LAB RECEIVER 01 / original Blender acceptance device", None)
scene.collection.objects.link(root)
root["provenance"] = "Original generated Blender receiver. No supplier geometry, electronics or manufacturability claim."
root["nominal_dimensions_mm"] = [180, 110, 45]
root["source_axis"] = "Blender Z-up; GLB exported Y-up"


def material(name, rgb, metallic=0.0, roughness=0.6, alpha=1.0, emission=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*rgb, alpha)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Alpha"].default_value = alpha
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1)
        bsdf.inputs["Emission Strength"].default_value = 0.8
    if alpha < 1:
        mat.surface_render_method = "DITHERED"
    mat.diffuse_color = (*rgb, alpha)
    return mat


shell_mat = material("Warm ceramic enamel / original brush detail", (0.57, 0.53, 0.46), 0.18, 0.45)
panel_mat = material("Deep slate anodized face", (0.025, 0.052, 0.075), 0.55, 0.4)
glass_mat = material("Smoked display cover / alpha glass", (0.06, 0.11, 0.14), 0.0, 0.08, 0.18)
screen_mat = material("Recessed charcoal display", (0.004, 0.009, 0.011), 0.0, 0.72)
cyan_mat = material("Cyan phosphor display lettering", (0.15, 0.65, 0.7), 0.0, 0.4, emission=(0.08, 0.48, 0.58))
metal_mat = material("Satin machined aluminum", (0.61, 0.64, 0.65), 0.88, 0.3)
rubber_mat = material("Graphite rubber grips and feet", (0.017, 0.023, 0.026), 0.0, 0.84)
orange_mat = material("Safety orange control accent", (0.7, 0.19, 0.045), 0.05, 0.52)
white_mat = material("Warm white panel legends", (0.79, 0.8, 0.74), 0.0, 0.7)
dark_mat = material("Dark screw recesses", (0.009, 0.011, 0.012), 0.15, 0.65)

# Original packed base, normal and metallic/roughness texture maps, authored in bpy.
def image(name, mode):
    result = bpy.data.images.new(name, width=128, height=128, alpha=True)
    if mode != "base":
        result.colorspace_settings.name = "Non-Color"
    pixels = []
    for y in range(128):
        for x in range(128):
            stripe = math.sin(y * 2.3) * 0.009 + math.sin(y * 0.31 + x * 0.04) * 0.004
            if mode == "base":
                v = 0.88 + stripe
                pixels.extend((v * 0.57, v * 0.53, v * 0.46, 1))
            elif mode == "normal":
                pixels.extend((0.5, 0.5 + stripe * 0.8, 1.0, 1))
            else:
                pixels.extend((1.0, 0.47 + stripe * 2, 0.18, 1))
    result.pixels = pixels
    result.pack()
    return result


nodes = shell_mat.node_tree.nodes
links = shell_mat.node_tree.links
bsdf = nodes.get("Principled BSDF")
base = nodes.new("ShaderNodeTexImage")
base.image = image("LAB original enamel micrograin", "base")
# Color is baked into our original image, avoiding unsupported shader graph factor folding.
# The same direct image node is used for the Blender source and static glTF appearance.
bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
normal = nodes.new("ShaderNodeTexImage")
normal.image = image("LAB original enamel micro normal", "normal")
normal_map = nodes.new("ShaderNodeNormalMap")
normal_map.inputs["Strength"].default_value = 0.25
links.new(normal.outputs["Color"], normal_map.inputs["Color"])
links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
pbr = nodes.new("ShaderNodeTexImage")
pbr.image = image("LAB original packed roughness metallic", "pbr")
separate = nodes.new("ShaderNodeSeparateColor")
links.new(pbr.outputs["Color"], separate.inputs[0])
links.new(separate.outputs["Green"], bsdf.inputs["Roughness"])
links.new(separate.outputs["Blue"], bsdf.inputs["Metallic"])


def own(obj, name, mat):
    obj.name = name
    obj.data.name = name + " / mesh"
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    bpy.context.view_layer.update()
    matrix = obj.matrix_world.copy()
    obj.parent = root
    obj.matrix_world = matrix
    return obj


def box(name, center, size, mat, bevel=0.0, segments=6):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    obj = bpy.context.object
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel:
        modifier = obj.modifiers.new("Manufactured edge radius", "BEVEL")
        modifier.width = bevel
        modifier.segments = segments
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = bevel > 0
    return own(obj, name, mat)


def cylinder(name, center, radius, depth, mat, vertices=64, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=center, rotation=(math.pi / 2, 0, 0))
    obj = bpy.context.object
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    if bevel:
        modifier = obj.modifiers.new("Soft machined edge", "BEVEL")
        modifier.width = bevel
        modifier.segments = 4
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = len(polygon.vertices) <= 4
    return own(obj, name, mat)


def difference(body, cutter):
    bpy.context.view_layer.objects.active = body
    modifier = body.modifiers.new("Actual bounded cavity / opening", "BOOLEAN")
    modifier.operation = "DIFFERENCE"
    modifier.solver = "EXACT"
    modifier.object = cutter
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def text(name, content, x, y, z, size, mat, align="LEFT"):
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = content
    curve.size = size
    curve.align_x = align
    curve.align_y = "CENTER"
    curve.extrude = 0.00006
    curve.bevel_depth = 0.000025
    curve.bevel_resolution = 1
    curve.resolution_u = 8
    obj = bpy.data.objects.new(name, curve)
    scene.collection.objects.link(obj)
    obj.location = (x, y, z)
    obj.rotation_euler = (math.pi / 2, 0, 0)
    return own(obj, name, mat)


# True rounded hollow housing: front is open, back and side walls remain real geometry.
housing = box("Hollow rounded enamel housing / 3 mm walls", (0, 0.004, 0.0565), (0.180, 0.037, 0.107), shell_mat, 0.010, 12)
cavity = box("cavity cutter", (0, -0.001, 0.0565), (0.174, 0.041, 0.101), dark_mat, 0.007, 12)
difference(housing, cavity)
housing["wall_mm"] = 3
housing["editability"] = "Static original visual mesh; cavity is modeled, no manufacturing certification."
front = box("Recessed anodized front plate", (0, -0.0128, 0.0565), (0.168, 0.002, 0.095), panel_mat, 0.004, 8)

# Thirty genuine speaker perforations in the front plate, visible against the dark cavity.
for row in range(5):
    for column in range(6):
        hole = cylinder("speaker opening cutter", (0.039 + column * 0.0063, -0.0128, 0.068 + row * 0.0062), 0.00135, 0.008, dark_mat, 24)
        difference(front, hole)
box("Speaker dark acoustic backing", (0.055, -0.0108, 0.0804), (0.041, 0.0006, 0.030), rubber_mat, 0.001, 4)

# The display has separate recess, frame, screen, glass and raised readable mesh graphics.
box("Satin display bezel", (-0.023, -0.0141, 0.077), (0.106, 0.0022, 0.036), metal_mat, 0.0025, 8)
box("Display black recess", (-0.023, -0.0154, 0.077), (0.101, 0.0009, 0.031), screen_mat, 0.0017, 8)
text("Display / tuned frequency", "108.6", -0.068, -0.0162, 0.079, 0.017, cyan_mat)
text("Display / frequency unit", "MHz", 0.011, -0.0162, 0.077, 0.004, cyan_mat)
text("Display / live status", "STEREO   /   STUDIO SIGNAL", -0.066, -0.0162, 0.067, 0.0029, cyan_mat)
for index in range(5):
    box("Display signal bar " + str(index + 1), (0.016 + index * 0.0017, -0.0161, 0.066 + index * 0.0005), (0.0009, 0.00012, 0.001 + index * 0.001), cyan_mat)
box("Smoked protective display glass", (-0.023, -0.0167, 0.077), (0.102, 0.0005, 0.032), glass_mat, 0.0016, 8)

# A deliberately smooth/knurled original dial: six radial rings, 192 samples, 48 flutes.
knob_center = (0.057, -0.0165, 0.033)
radial = 192
rings = [(0.0098, 0.0045), (0.011, 0.0034), (0.011, -0.0036), (0.0107, -0.0048), (0.0099, -0.0057)]
vertices = []
faces = []
for radius, depth in rings:
    for i in range(radial):
        angle = 2 * math.pi * i / radial
        knurl = 0.00022 * math.cos(angle * 48) if radius > 0.0105 else 0
        vertices.append((knob_center[0] + (radius + knurl) * math.cos(angle), knob_center[1] + depth, knob_center[2] + (radius + knurl) * math.sin(angle)))
for ring in range(len(rings) - 1):
    for i in range(radial):
        a = ring * radial + i
        b = ring * radial + (i + 1) % radial
        faces.append((a, b, b + radial, a + radial))
faces.append(tuple(reversed(range(radial))))
faces.append(tuple((len(rings) - 1) * radial + i for i in range(radial)))
mesh = bpy.data.meshes.new("Original fluted tuning dial")
mesh.from_pydata(vertices, [], faces)
mesh.update()
knob = bpy.data.objects.new("Machined tuning dial / 48 real knurled flutes", mesh)
scene.collection.objects.link(knob)
own(knob, knob.name, metal_mat)
for polygon in mesh.polygons:
    polygon.use_smooth = len(polygon.vertices) == 4
cylinder("Tuning dial inset rubber face", (0.057, -0.0219, 0.033), 0.009, 0.0005, rubber_mat, 96)
box("Tuning dial orange index", (0.057, -0.0223, 0.0392), (0.0011, 0.0004, 0.004), orange_mat, 0.0001, 4)
text("Tuning dial legend", "TUNE", 0.057, -0.014, 0.016, 0.0035, white_mat, "CENTER")

for x, label in [(-0.064, "POWER"), (-0.040, "SOURCE"), (-0.016, "PRESET")]:
    cylinder("Control seat / " + label, (x, -0.0142, 0.032), 0.0075, 0.0015, metal_mat, 64, 0.0004)
    cylinder("Tactile control / " + label, (x, -0.0167, 0.032), 0.006, 0.004, orange_mat if label == "POWER" else rubber_mat, 64, 0.0006)
    text("Panel legend / " + label, label, x, -0.014, 0.019, 0.0026, white_mat, "CENTER")
text("Original manufacturer legend", "LAB   /   RECEIVER 01", -0.071, -0.014, 0.050, 0.0036, white_mat)

# Four separate machined front fasteners with real cross-slot booleans.
for index, (x, z) in enumerate([(-0.078, 0.014), (0.078, 0.014), (-0.078, 0.099), (0.078, 0.099)]):
    screw = cylinder("Front fastener " + str(index + 1), (x, -0.0147, z), 0.0025, 0.0017, metal_mat, 64, 0.0003)
    for width, height in [(0.0033, 0.00065), (0.00065, 0.0033)]:
        cutter = box("screw slot cutter", (x, -0.01555, z), (width, 0.0007, height), dark_mat)
        difference(screw, cutter)
    box("Fastener dark recess " + str(index + 1), (x, -0.01518, z), (0.0032, 0.0001, 0.0032), dark_mat)

rear = box("Inset rear service panel", (0, 0.0215, 0.0565), (0.162, 0.0015, 0.089), rubber_mat, 0.004, 8)
for row in range(6):
    cutter = box("rear vent cutter", (0.026, 0.0215, 0.042 + row * 0.0046), (0.056, 0.006, 0.0014), dark_mat, 0.0005, 3)
    difference(rear, cutter)
for x in (-0.062, 0.062):
    for y in (-0.007, 0.014):
        box("Separate elastomer foot " + str((x, y)), (x, y, 0.002), (0.022, 0.011, 0.004), rubber_mat, 0.0015, 6)

# Freeze fonts as real geometry, and create UV0 for all authored solids.
for obj in list(scene.objects):
    if obj.type == "FONT":
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.convert(target="MESH")
# Preserve genuinely planar manufactured faces; smoothing a boolean-cut n-gon
# would create false radiating dents between screw/speaker holes.
for obj in list(scene.objects):
    if obj.type != "MESH":
        continue
    obj.data.update()
    for polygon in obj.data.polygons:
        if max(abs(value) for value in polygon.normal) > 0.99999:
            polygon.use_smooth = False
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    triangulate = obj.modifiers.new("Frozen explicit interchange triangles", "TRIANGULATE")
    triangulate.keep_custom_normals = True
    bpy.ops.object.modifier_apply(modifier=triangulate.name)
for obj in scene.objects:
    if obj.type == "MESH" and not obj.data.uv_layers:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
        bpy.ops.object.mode_set(mode="OBJECT")

world = bpy.data.worlds.new("Neutral fixed device source world")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.36, 0.39, 0.43, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.45
scene.world = world


def area(name, position, energy, size):
    light = bpy.data.lights.new(name, "AREA")
    light.energy = energy
    light.shape = "DISK"
    light.size = size
    obj = bpy.data.objects.new(name, light)
    scene.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector((0, 0, 0.055)) - obj.location).to_track_quat("-Z", "Y").to_euler()


area("Device source key", (-0.27, -0.42, 0.55), 8, 0.45)
area("Device source fill", (0.38, -0.16, 0.25), 4, 0.35)
area("Device source rim", (0.15, 0.28, 0.42), 7, 0.28)
camera_data = bpy.data.cameras.new("Fixed device comparison camera")
camera = bpy.data.objects.new("Fixed device comparison camera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0.29, -0.48, 0.255)
target = Vector((0, 0, 0.055))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.type = "ORTHO"
camera_data.ortho_scale = 0.235
scene.camera = camera
scene.render.engine = "CYCLES"
scene.cycles.samples = 16
scene.cycles.use_denoising = True
scene.render.threads_mode = "FIXED"
scene.render.threads = 2
scene.render.resolution_x = 1200
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.render.filepath = str(out / "LAB-Blender-receiver-source.png")

meshes = [obj for obj in scene.objects if obj.type == "MESH"]
bpy.context.view_layer.update()
points = [obj.matrix_world @ Vector(vertex) for obj in meshes for vertex in obj.bound_box]
minimum = [min(p[i] for p in points) for i in range(3)]
maximum = [max(p[i] for p in points) for i in range(3)]
vertices_count = sum(len(obj.data.vertices) for obj in meshes)
triangles = sum(sum(len(poly.vertices) - 2 for poly in obj.data.polygons) for obj in meshes)
for packed_image in bpy.data.images:
    if packed_image.source != "VIEWER" and packed_image.has_data:
        try:
            packed_image.pack()
        except RuntimeError:
            pass
bpy.ops.wm.save_as_mainfile(filepath=str(out / "LAB-Blender-receiver.blend"))
bpy.ops.object.select_all(action="DESELECT")
for obj in meshes:
    obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=str(out / "LAB-Blender-receiver.glb"), export_format="GLB", use_selection=True,
                          export_yup=True, export_apply=True, export_texcoords=True, export_normals=True,
                          export_tangents=True, export_materials="EXPORT", export_animations=False,
                          export_skins=False, export_morph=False, export_extras=True,
                          export_draco_mesh_compression_enable=False, export_cameras=False, export_lights=False)
manifest = {
    "provenance": "Original Blender-authored static receiver. No supplier geometry or functional electronics/manufacturability claim.",
    "blender_version": bpy.app.version_string,
    "source_unit": "meter", "source_axis": "Blender Z-up; GLB right-handed Y-up",
    "nominal_dimensions_mm": [180, 110, 45],
    "blender_bounds_meter": {"minimum": minimum, "maximum": maximum},
    "gltf_bounds_mm": {"minimum": [minimum[0] * 1000, minimum[2] * 1000, -maximum[1] * 1000], "maximum": [maximum[0] * 1000, maximum[2] * 1000, -minimum[1] * 1000]},
    "source_vertices": vertices_count, "source_triangles": triangles, "mesh_objects": len(meshes),
    "parts": [obj.name for obj in meshes],
    "materials": sorted({mat.name for obj in meshes for mat in obj.data.materials if mat}),
    "source_camera_gltf_meter": {"from": [camera.location.x, camera.location.z, -camera.location.y], "target": [target.x, target.z, -target.y], "up": [0, 1, 0], "orthographic_height_meter": camera_data.ortho_scale * 900 / 1200},
    "render": {"resolution": [1200, 900], "engine": "Cycles", "samples": 16, "threads": 2, "color_transform": "Standard sRGB", "note": "Source lighting differs from RealityKit; compare retained shape/material groups rather than pixel-identical shading."},
    "features": ["True rounded hollow enclosure and front opening", "30 actual speaker perforations", "Rear access panel with actual vent slots", "Alpha glass and separate recessed display", "48 real knurled dial flutes", "3 separate tactile controls", "4 real cross-slot front fasteners", "4 separate elastomer feet", "Original base/normal/packed PBR maps", "Actual mesh lettering and display graphics"],
}
(out / "LAB-Blender-receiver-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
bpy.ops.render.render(write_still=True)
print("LAB_BLENDER_DEVICE_ACCEPTANCE", json.dumps({"parts": len(meshes), "vertices": vertices_count, "triangles": triangles, "glb": str(out / "LAB-Blender-receiver.glb")}))
