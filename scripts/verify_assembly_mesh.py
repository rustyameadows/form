#!/usr/bin/env python3
"""Independent numerical reader for the rounded-pouch assembly proof JSON.

Uses Python's standard library, not FORM, Earcut or the mesher implementation.
Checks original cubic integrals/arc samples, rigid poses, mass, UVs, incidence,
Euler characteristic and every recorded physical seam sample.
"""
import argparse
import bisect
import collections
import json
import math
from pathlib import Path


def point(p):
    return p["x"], p["y"]


def cubic(a, b):
    p = [point(a["anchor"]), point(a.get("outgoing", a["anchor"])),
         point(b.get("incoming", b["anchor"])), point(b["anchor"])]
    return [tuple(v[i] for v in p) for i in (0, 1)]


def coefficients(p):
    a, b, c, d = p
    return a, 3 * (b - a), 3 * (a - 2 * b + c), d - a + 3 * (b - c)


def integral_area(curve):
    x, y = map(coefficients, curve)
    return sum((x[i] * j * y[j] - y[i] * j * x[j]) / (i + j)
               for i in range(4) for j in range(1, 4)) / 2


def evaluate(curve, t):
    return tuple((1-t)**3*p[0] + 3*(1-t)**2*t*p[1]
                 + 3*(1-t)*t*t*p[2] + t**3*p[3] for p in curve)


def arc_table(curve, count=8192):
    samples = [evaluate(curve, i/count) for i in range(count+1)]
    lengths = [0.0]
    for a, b in zip(samples, samples[1:]):
        lengths.append(lengths[-1] + math.dist(a, b))
    return samples, lengths


def arc_point(table, fraction):
    samples, lengths = table
    target = fraction * lengths[-1]
    end = min(len(samples)-1, max(1, bisect.bisect_left(lengths, target)))
    start = end-1
    f = (target-lengths[start]) / (lengths[end]-lengths[start])
    return tuple(samples[start][i] * (1-f) + samples[end][i] * f for i in (0, 1))


def norm(a):
    return math.sqrt(sum(x*x for x in a))


def triangle_area(a, b, c):
    u = [b[i]-a[i] for i in range(3)]
    v = [c[i]-a[i] for i in range(3)]
    return norm((u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2],
                 u[0]*v[1]-u[1]*v[0])) / 2


def verify(path):
    data = json.loads(Path(path).read_text())
    mesh = data["study"]["mesh"]
    positions = [tuple(p[k] for k in ("x", "y", "z")) for p in mesh["restPositionsMm"]]
    triangles = [(t["a"], t["b"], t["c"]) for t in mesh["triangles"]]
    material = [point(p) for p in data["material_points_mm"]]
    assert 3 <= len(positions) <= 4096 and len(triangles) <= 8192
    assert all(math.isfinite(v) for p in positions for v in p)
    elements = {e["id"]: e for e in data["source_artwork"]["elements"]}
    seams = {s["id"]: s for s in data["source_artwork"]["sewingSeams"]}
    placements = {(p["panel"]["elementID"], p["panel"]["copy"]): p
                  for p in data["definition"]["panels"]}
    panels = {(p["id"]["elementID"], p["id"]["copy"]): p for p in data["panel_records"]}
    # This original independent reference fixture has unrotated, positive source
    # dimensions and no source path transform. Never silently generalize the reader.
    curve_tables = {}
    boundary_vertices = {}
    minimum_angle = 180.0
    source_areas = {}
    for key, panel in panels.items():
        source = elements[key[0]]
        assert source.get("rotation", 0) == 0 and source.get("affine") is None and source.get("parentID") is None and not source.get("flipX",False) and not source.get("flipY",False)
        path = source["path"]
        assert abs(path["width"]-source["width"]) < 1e-9
        assert abs(path["height"]-source["height"]) < 1e-9
        area = 0
        for contour in path["contours"]:
            nodes = contour["nodes"]
            signed = 0
            for a, b in zip(nodes, nodes[1:]+nodes[:1]):
                curve = cubic(a, b)
                curve_tables[(source["id"], a["id"])] = arc_table(curve)
                signed += integral_area(curve)
            area += signed
        source_areas[key] = abs(area)
        indices = set(panel["vertexIndices"])
        assert indices and all(mesh["panelIDs"][i] == panel["panelIndex"] for i in indices)
        faces = [t for t in triangles if t[0] in indices]
        assert all(set(t) <= indices for t in faces)
        incident = collections.Counter(tuple(sorted(e)) for a,b,c in faces for e in ((a,b),(b,c),(c,a)))
        assert set(incident.values()) <= {1, 2}
        boundary_vertices[key]={i for edge,count in incident.items() if count==1 for i in edge}
        assert len(indices)-len(incident)+len(faces) == 1  # This reference has one exterior/no holes.
        assert set(i for t in faces for i in t) == indices
        areas = [triangle_area(*(positions[i] for i in t)) for t in faces]
        assert min(areas) > 1e-8
        for triangle in faces:
            lengths=[math.dist(positions[triangle[a]],positions[triangle[b]]) for a,b in ((0,1),(1,2),(2,0))]
            for i,j,k in ((0,1,2),(1,2,0),(2,0,1)):
                angle=math.degrees(math.acos(max(-1,min(1,(lengths[i]**2+lengths[j]**2-lengths[k]**2)/(2*lengths[i]*lengths[j])))))
                minimum_angle=min(minimum_angle,angle)
        summed = sum(areas)
        assert abs(summed-panel["meshAreaMm2"]) < 1e-7
        assert abs(summed-abs(area)) < 2, (summed, area)
        expected_mass = summed*panel["densityGSM"]*1e-9
        assert abs(sum(mesh["massesKg"][i] for i in indices)-expected_mass) < 1e-12
        pose = placements[key]["pose"]
        for i in indices:
            p = material[i]
            expected = tuple(pose["originMm"][k] + p[0]*pose["uAxis"][k]
                             + p[1]*pose["vAxis"][k] for k in ("x","y","z"))
            assert math.dist(expected, positions[i]) < 1e-7
            assert abs(mesh["uv"][i]["x"]*panel["materialSizeMm"]["x"]-p[0]) < 1e-7
            assert abs(mesh["uv"][i]["y"]*panel["materialSizeMm"]["y"]-p[1]) < 1e-7
    maximum_sample_error = 0
    for sample in data["seam_samples"]:
        seam = seams[sample["seamID"]]
        assert abs(sample["secondFraction"] - (1-sample["firstFraction"] if seam.get("reversed",False) else sample["firstFraction"])) < 1e-10
        for prefix in ("first", "second"):
            end = seam[prefix]
            key = end["elementID"], end["copy"]
            table = curve_tables[(key[0], end["edgeID"])]
            fraction = sample[prefix+"Fraction"]
            expected_local = arc_point(table, fraction)
            source = elements[key[0]]
            expected_world = expected_local[0]+source["x"], expected_local[1]+source["y"]
            p = material[sample[prefix+"Vertex"]]
            origin = panels[key]["sourceOriginMm"]
            actual = p[0]+origin["x"], p[1]+origin["y"]
            error = math.dist(expected_world, actual)
            maximum_sample_error = max(maximum_sample_error,error)
            assert error < 0.005, (prefix, fraction, error)
            assert abs(sample[prefix+"DistanceMm"]-table[1][-1]*fraction) < 0.005
    # Independently reject the old sparse-stitch defect: every actual boundary
    # vertex along a declared sewn curve must have a physical paired sample.
    for seam_id,seam in seams.items():
        for prefix in ("first","second"):
            end=seam[prefix];key=end["elementID"],end["copy"]
            if key not in panels: continue
            sewn={sample[prefix+"Vertex"] for sample in data["seam_samples"] if sample["seamID"]==seam_id}
            samples=curve_tables[(key[0],end["edgeID"])][0]
            origin=panels[key]["sourceOriginMm"];source=elements[key[0]]
            for vertex in boundary_vertices[key]:
                p=material[vertex];local=(p[0]+origin["x"]-source["x"],p[1]+origin["y"]-source["y"])
                if min(math.dist(local,q) for q in samples)<0.05:
                    assert vertex in sewn,("Unpaired adaptive source boundary",seam_id,prefix,vertex)
    mass_ratio=max(mesh["massesKg"])/min(mesh["massesKg"])
    assert minimum_angle>4 and mass_ratio<50,(minimum_angle,mass_ratio)
    report = {"verified":True,"vertices":len(positions),"triangles":len(triangles),
              "constraints":len(mesh["links"]),"panels":len(panels),
              "source_seam_samples":len(data["seam_samples"]),"every_sewn_boundary_vertex_paired":True,"minimum_triangle_angle_degrees":minimum_angle,"mass_ratio":mass_ratio,
              "maximum_independent_arc_sample_error_mm":maximum_sample_error,
              "total_mass_kg":sum(mesh["massesKg"]),
              "independent_cubic_areas_mm2":list(source_areas.values())}
    return report


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--report")
    args=parser.parse_args()
    result=verify(args.path)
    rendered=json.dumps(result,indent=2,sort_keys=True)
    print(rendered)
    if args.report:
        Path(args.report).write_text(rendered+"\n")
