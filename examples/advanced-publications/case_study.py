#!/usr/bin/env python3
"""Authored slipcase data; caller alone drives LAB's existing public MCP.

No network client, application launcher, private package edits, image provider or
hardware calls live here. Pass ``call(tool_name, arguments) -> decoded result``
from the acceptance runner. Every geometry expression, stock and artwork layer
is saved in the project and remains editable through ordinary LAB tools.
"""
from __future__ import annotations

import ast
import copy
import hashlib
import json
import math
import uuid
from functools import reduce
from collections import Counter
from typing import Any, Callable

Call = Callable[[str, dict[str, Any]], dict[str, Any]]


def _id() -> str:
    return str(uuid.uuid4()).upper()


def _point(x: Any, y: Any) -> dict[str, Any]:
    return {"x": x, "y": y}


def _vector(x: Any = 0, y: Any = 0, z: Any = 0) -> dict[str, Any]:
    return {"x": x, "y": y, "z": z}


def _caliper(stock: dict[str, Any]) -> float:
    return sum(float(p["thicknessMM"]) for p in stock["plies"]) if stock.get("plies") else float(stock["thicknessMM"])


def stock(name: str, caliper: float, color: str, texture: str = "smooth", roughness: float = .9) -> dict[str, Any]:
    return {"name": name, "thicknessMM": caliper, "gsm": 180, "grain": "parallelHeight", "verified": False,
            "notes": "Project-authored visual construction assumption; no measured manufacturing tolerance is implied.",
            "profile": {"texture": texture, "color": color, "roughness": roughness,
                        "textureScaleMM": .65, "textureDepthMM": .018, "opacity": 1}}


def _parameter(name: str, value: float, minimum: float = 0, maximum: float = 2000) -> dict[str, Any]:
    return {"name": name, "value": float(value), "minimum": minimum, "maximum": maximum, "unit": "mm"}


def _recipe_parameter(name: str, value: float) -> dict[str, Any]:
    return {"id": name, "name": name, "value": float(value), "minimum": .01 if name in ("width", "depth") else 0,
            "maximum": 10000, "step": .01, "unit": "mm"}


def _ref(identifier: str, measurement: str, parameter: str | None = None) -> dict[str, Any]:
    value = {"sourceObjectID": identifier, "measurement": measurement}
    if parameter is not None:
        value["parameter"] = parameter
    return value


def _maximum(names: list[str]) -> str:
    return reduce(lambda a, b: f"max({a},{b})", names)


def dimension_bindings(book_ids: list[str]) -> list[dict[str, Any]]:
    """An ordered input list is project data. Reordering changes these bindings."""
    if not 1 <= len(book_ids) <= 6 or len(set(book_ids)) != len(book_ids):
        raise ValueError("Choose one to six distinct existing book source IDs.")
    thickness = {f"t{i}": _ref(identifier, "closedThickness") for i, identifier in enumerate(book_ids)}
    heights = {f"h{i}": _ref(identifier, "closedHeight") for i, identifier in enumerate(book_ids)}
    depths = {f"d{i}": _ref(identifier, "closedWidth") for i, identifier in enumerate(book_ids)}
    bindings = [
        {"parameter": "innerWidth", "expression": "+".join(thickness) + f"+2*clearance+{len(book_ids)-1}*volumeGap", "inputs": thickness},
        {"parameter": "innerHeight", "expression": _maximum(list(heights)) + "+2*clearance", "inputs": heights},
        {"parameter": "innerDepth", "expression": _maximum(list(depths)) + "+2*clearance", "inputs": depths},
    ]
    for i in range(len(book_ids)):
        inputs = {f"t{j}": thickness[f"t{j}"] for j in range(i)}
        expression = "clearance" + ("+" + "+".join(inputs) if inputs else "") + f"+{i}*volumeGap"
        bindings.append({"parameter": f"volumeOffset{i}", "expression": expression, "inputs": inputs})
    return bindings


def _evaluate(value: Any, values: dict[str, float]) -> float:
    """Evaluate only authored scalar arithmetic for offline layout/pose records."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        result = float(value)
    else:
        def walk(node: ast.AST) -> float:
            if isinstance(node, ast.Constant) and isinstance(node.value, (float, int)):
                return float(node.value)
            if isinstance(node, ast.Name):
                return math.pi if node.id == "pi" else values[node.id]
            if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
                return walk(node.operand) * (-1 if isinstance(node.op, ast.USub) else 1)
            if isinstance(node, ast.BinOp):
                a, b = walk(node.left), walk(node.right)
                if isinstance(node.op, ast.Add): return a + b
                if isinstance(node.op, ast.Sub): return a - b
                if isinstance(node.op, ast.Mult): return a * b
                if isinstance(node.op, ast.Div): return a / b
            functions = {"min": min, "max": max, "abs": abs, "sqrt": math.sqrt, "sin": math.sin, "cos": math.cos,
                         "tan": math.tan, "asin": math.asin, "acos": math.acos, "atan": math.atan, "hypot": math.hypot,
                         "radians": math.radians, "degrees": math.degrees, "floor": math.floor, "ceil": math.ceil,
                         "round": round, "clamp": lambda x, low, high: min(high, max(low, x))}
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and not node.keywords:
                return float(functions[node.func.id](*(walk(a) for a in node.args)))
            raise ValueError("Only declared finite scalar arithmetic is accepted.")
        result = walk(ast.parse(str(value), mode="eval").body)
    if not math.isfinite(result) or abs(result) > 1e7:
        raise ValueError("An authored dimension is not finite or bounded.")
    return result


def _rotation(x: float, y: float, z: float) -> list[list[float]]:
    x, y, z = map(math.radians, (x, y, z))
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    return [[cz*cy, cz*sy*sx-sz*cx, cz*sy*cx+sz*sx],
            [sz*cy, sz*sy*sx+cz*cx, sz*sy*cx-cz*sx], [-sy, cy*sx, cy*cx]]


def _matmul(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[sum(a[r][k]*b[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


def _euler(matrix: list[list[float]]) -> dict[str, float]:
    y = math.asin(max(-1., min(1., -matrix[2][0])))
    if abs(math.cos(y)) > 1e-8:
        x, z = math.atan2(matrix[2][1], matrix[2][2]), math.atan2(matrix[1][0], matrix[0][0])
    else:
        x, z = math.atan2(-matrix[1][2], matrix[1][1]), 0
    return _vector(*(0. if abs(math.degrees(v)) < 1e-9 else math.degrees(v) for v in (x, y, z)))


def _closed_bounds(inspection: dict[str, Any], source: dict[str, Any] | None = None) -> dict[str, list[float]]:
    """Consume the native closed envelope; never reproduce its geometry in Python.

    Aliases, evaluated wrap calipers and curved panels belong to the shared Core
    resolver. Pagination and the current opening pose cannot change this bound.
    An older/incomplete report fails before any case-authoring mutation.
    """
    if source is not None and inspection.get("object_id") != source.get("id"):
        raise ValueError("Closed bounds must belong to the inspected source object.")
    resolved = inspection.get("resolved", {})
    bounds = resolved.get("closed_bounds_mm")
    if not isinstance(bounds, dict):
        raise ValueError("Native closed_bounds_mm are required; update LAB before authoring a fitted case.")
    result = {}
    for key in ("minimum_mm", "maximum_mm"):
        values = bounds.get(key)
        if not isinstance(values, list) or len(values) != 3 or any(
            isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or abs(v) > 1e7 for v in values
        ):
            raise ValueError("Native closed bounds need three finite source-local millimeter coordinates.")
        result[key] = [float(v) for v in values]
    for axis, key in enumerate(("closed_width_mm", "closed_thickness_mm", "closed_height_mm")):
        value = resolved.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise ValueError("Native closed dimensions must remain finite and positive.")
        extent = result["maximum_mm"][axis] - result["minimum_mm"][axis]
        if extent <= 0 or abs(extent-value) > max(1e-6, abs(value)*1e-9):
            raise ValueError(f"Native closed bounds disagree with {key}; inspect before composing.")
    return result


def plan_case_study(book_ids: list[str], metrics: dict[str, dict[str, float]], *, name: str = "Field notes · collected volumes",
                    clearance_mm: float = 1.5, inter_volume_gap_mm: float = .8, board_mm: float = 1.6,
                    wrap_stock: dict[str, Any] | None = None, lining_stock: dict[str, Any] | None = None,
                    turn_in_mm: float = 12, flat_pose: bool = True) -> dict[str, Any]:
    bindings = dimension_bindings(book_ids)
    wrap_stock = copy.deepcopy(wrap_stock or stock("Deep teal woven wrapping · visual", .14, "#263E43", "linen", .78))
    lining_stock = copy.deepcopy(lining_stock or stock("Warm laid lining · visual", .12, "#D8D1BC", "laid"))
    if not 0 <= clearance_mm <= 20 or not 0 <= inter_volume_gap_mm <= 20 or not .5 <= board_mm <= 5:
        raise ValueError("Fit allowances and board caliper exceed this authored study's declared controls.")
    if not 2 <= turn_in_mm <= 30:
        raise ValueError("Turn-ins must be 2–30 mm in this authored study.")
    rows = [metrics[identifier] for identifier in book_ids]
    values = {"innerWidth": sum(r["closedThickness"] for r in rows)+2*clearance_mm+(len(rows)-1)*inter_volume_gap_mm,
              "innerHeight": max(r["closedHeight"] for r in rows)+2*clearance_mm,
              "innerDepth": max(r["closedWidth"] for r in rows)+2*clearance_mm,
              "board": board_mm, "skin": _caliper(wrap_stock), "lining": _caliper(lining_stock), "turnIn": turn_in_mm,
              "clearance": clearance_mm, "volumeGap": inter_volume_gap_mm, "layoutGap": 10.}
    for i in range(len(rows)):
        values[f"volumeOffset{i}"] = clearance_mm+sum(r["closedThickness"] for r in rows[:i])+i*inter_volume_gap_mm
    parameters = [_parameter(k, v, .01 if k.startswith("inner") else 0., 2000.) for k, v in values.items()]
    for p in parameters:
        if p["name"] == "board": p.update(minimum=.5, maximum=5.)
        if p["name"] == "skin": p.update(minimum=p["value"], maximum=p["value"])
        if p["name"] == "lining": p.update(minimum=.01, maximum=2.)
        if p["name"] == "turnIn": p.update(minimum=2., maximum=30.)
        if p["name"] in ("clearance", "volumeGap"): p.update(maximum=20.)
        if p["name"] == "layoutGap": p.update(minimum=4., maximum=100.)
    derived = {"margin": "board+turnIn+skin+2", "outerCoreWidth": "innerWidth+2*(lining+skin+board)",
               "sideHeight": "innerHeight+2*(lining-skin)", "sideDepth": "innerDepth+lining-skin",
               "baseDepth": "innerDepth+lining+skin+board"}
    # Positions are in the upright cavity frame. Each root has its own actual
    # butt-joint board. Two skin calipers separate adjoining core ends so the
    # real wrapping layers meet instead of penetrating neighboring chipboard.
    specs = [
        ("base", "Lower board", "outerCoreWidth", "baseDepth", ("-(lining+skin+board)", "-lining-skin-board/2", "innerDepth/2"), (90, 0, 0), True),
        ("top", "Upper board", "outerCoreWidth", "baseDepth", ("-(lining+skin+board)", "innerHeight+lining+skin+board/2", "-innerDepth/2-lining-skin-board"), (-90, 0, 0), True),
        ("left", "Left board", "sideDepth", "sideHeight", ("-lining-skin-board/2", "innerHeight+lining-skin", "-innerDepth/2-lining+skin"), (0, -90, 0), True),
        ("right", "Right board", "sideDepth", "sideHeight", ("innerWidth+lining+skin+board/2", "innerHeight+lining-skin", "innerDepth/2"), (0, 90, 0), True),
        ("back", "Rear board", "outerCoreWidth", "sideHeight", ("innerWidth+lining+skin+board", "innerHeight+lining-skin", "-innerDepth/2-lining-skin-board/2"), (0, 180, 0), True),
        ("lining-base", "Lower lining", "innerWidth", "innerDepth", (0, "-lining/2", "-innerDepth/2"), (-90, 0, 0), False),
        ("lining-top", "Upper lining", "innerWidth", "innerDepth", (0, "innerHeight+lining/2", "innerDepth/2"), (90, 0, 0), False),
        ("lining-left", "Left lining", "innerDepth", "innerHeight", ("-lining/2", "innerHeight", "innerDepth/2"), (0, 90, 0), False),
        ("lining-right", "Right lining", "innerDepth", "innerHeight", ("innerWidth+lining/2", "innerHeight", "-innerDepth/2"), (0, -90, 0), False),
        ("lining-back", "Rear lining", "innerWidth", "innerHeight", (0, "innerHeight", "-innerDepth/2-lining/2"), (0, 0, 0), False),
    ]
    panels, components, layout = [], [], []
    heights_before: Counter[str] = Counter()
    cursor = "0"
    for key, label, w, h, position, angles, wrapped in specs:
        cumulative = "+".join(f"{count}*({height})" for height, count in heights_before.items()) or "0"
        x, y = "margin", f"{cumulative}+{len(layout)}*(2*margin+layoutGap)+margin"
        polygon = [_point(x, y), _point(f"{x}+{w}", y), _point(f"{x}+{w}", f"{y}+{h}"), _point(x, f"{y}+{h}")]
        features = {"wrap": {"stock": wrap_stock, "turnInMM": f"min(turnIn,min({w},{h})/2-0.25)", "cornerRadiusMM": 1.2}} if wrapped else None
        panel = {"id": key, "name": label, "role": "body", "polygon": polygon}
        if features is not None: panel["features"] = features
        panels.append(panel)
        if flat_pose:
            position = (position[2], position[0], position[1])
            rotation = _euler(_matmul(_rotation(90, 0, 90), _rotation(*angles)))
        else:
            rotation = _vector(*angles)
        components.append({"id": key, "name": label, "rootPanelID": key, "anchor": _point(x, y),
                           "position": _vector(*position), "rotationDegrees": rotation})
        layout.append({"id": key, "name": label, "origin": _point(x, y), "size": _point(w, h), "wrapped": wrapped})
        heights_before[h] += 1
        cursor = "+".join(f"{count}*({height})" for height, count in heights_before.items()) + f"+{len(layout)}*(2*margin+layoutGap)"
    # Max accepts two arguments in the existing expression engine.
    derived["netWidth"] = _maximum([s[2] for s in specs])+"+2*margin"
    derived["netHeight"] = cursor
    definition = {"version": 3, "name": name, "parameters": parameters, "derived": derived,
                  "size": _point("netWidth", "netHeight"), "stockThickness": "board",
                  "panels": panels[:5], "hinges": [], "joins": [], "rootPanelID": "base", "components": components[:5],
                  "interiors": [{"id": "fitted-run", "name": "Declared finished lining cavity", "componentID": "left",
                                 "origin": _vector("lining-skin", "-innerHeight-lining+skin", "-lining-skin-board/2"),
                                 "size": _vector("innerWidth", "innerHeight", "innerDepth"),
                                 "rotationDegrees": _vector(0, 90, 0),
                                 "opening": {"axis": "z", "width": "innerWidth", "height": "innerHeight", "origin": _point(0, 0)}}]}
    lining_definition = {"version": 3, "name": name+" / actual paper lining", "parameters": copy.deepcopy(parameters),
                         "derived": copy.deepcopy(derived), "size": _point("netWidth", "netHeight"), "stockThickness": "lining",
                         "panels": panels[5:], "hinges": [], "joins": [], "rootPanelID": "lining-base", "components": components[5:]}
    resolved_values = dict(values)
    for key in ("margin", "outerCoreWidth", "sideHeight", "sideDepth", "baseDepth", "netWidth", "netHeight"):
        resolved_values[key] = _evaluate(derived[key], resolved_values)
    if resolved_values["netWidth"] > 10000 or resolved_values["netHeight"] > 10000:
        raise ValueError("This explicit flat layout exceeds the existing 10000 mm source extent.")
    return {"name": name, "ordered_book_ids": list(book_ids), "definition": definition, "parameters": values,
            "lining_definition": lining_definition, "dimension_bindings": bindings, "layout": layout, "resolved_values": resolved_values,
            "board_stock": stock("Archival chipboard · visual", board_mm, "#A69E87", "recycled"),
            "wrap_stock": wrap_stock, "lining_stock": lining_stock, "flat_pose": flat_pose,
            "orientation": "cavity X→worldY, Y→worldZ, Z→worldX" if flat_pose else "upright cavity XYZ",
            "manufacturing_verified": False}


def _source_plan(plan: dict[str, Any], object_id: str) -> dict[str, Any]:
    v, panel_layout = plan["resolved_values"], plan["layout"]
    namespace = uuid.UUID(object_id)
    rid = "caseArtwork" + namespace.hex
    source_parameters = {"width": v["netWidth"], "depth": v["netHeight"]}
    mirrored = ("innerWidth", "innerHeight", "innerDepth", "board", "skin", "lining", "turnIn", "layoutGap")
    source_parameters.update({key: v[key] for key in mirrored})
    inputs = {"iw": _ref(object_id, "parameter", "innerWidth"), "ih": _ref(object_id, "parameter", "innerHeight"),
              "idp": _ref(object_id, "parameter", "innerDepth"), "b": _ref(object_id, "parameter", "board"),
              "s": _ref(object_id, "parameter", "skin"), "l": _ref(object_id, "parameter", "lining"),
              "t": _ref(object_id, "parameter", "turnIn"), "g": _ref(object_id, "parameter", "layoutGap")}
    # Source dimensions and native construction regions use the same expression
    # layout. The independent source remains 1:1 mm as its consumer grows.
    replacements = {"innerWidth": "iw", "innerHeight": "ih", "innerDepth": "idp", "board": "b", "skin": "s", "lining": "l", "turnIn": "t", "layoutGap": "g"}
    def expand(expression: Any, aliases: bool = False) -> str:
        import re
        text = str(expression)
        for _ in range(8):
            changed = re.sub(r"\b("+"|".join(plan["definition"]["derived"])+r")\b", lambda m: "("+str(plan["definition"]["derived"][m[0]])+")", text)
            if text == changed: break
            text = changed
        if aliases:
            text = re.sub(r"\b("+"|".join(replacements)+r")\b", lambda m: replacements[m[0]], text)
        return text
    width_expression = "max(iw+2*(l+s+b),max(idp+l-s,idp))+2*(b+t+s+2)"
    # The engine limits individual CAD expressions to 256 bytes. Keep source
    # height algebra compact instead of expanding ten accumulated row origins.
    height_expression = "4*idp+6*ih+8*l-4*s+2*b+20*(b+t+s+2)+10*g"
    source_bindings = [{"parameter": "width", "expression": width_expression, "inputs": inputs},
                       {"parameter": "depth", "expression": height_expression, "inputs": inputs}]
    source_bindings += [{"parameter": key, "expression": alias, "inputs": {alias: inputs[alias]}} for key, alias in replacements.items()]
    elements, regions, foil_ids = [], [], []
    for row in panel_layout:
        key = row["id"]
        origin = {axis: expand(row["origin"][axis]) for axis in ("x", "y")}
        size = {axis: expand(row["size"][axis]) for axis in ("x", "y")}
        x, y = (_evaluate(origin[k], source_parameters) for k in ("x", "y"))
        width, height = (_evaluate(size[k], source_parameters) for k in ("x", "y"))
        root_id = str(uuid.uuid5(namespace, "art:"+key)).upper()
        if row["wrapped"]:
            inset = min(12., max(3., width*.14))
            art_width = max(1., width-2*inset)
            narrow = width < 45
            group = {"id": root_id, "kind": "group", "name": row["name"]+" / editable foil typography", "x": x+inset, "y": y+14,
                     "width": art_width, "height": min(100, height-28), "text": "", "color": "#CEB875", "fontSize": 14,
                     "contentSize": _point(art_width, min(100, height-28))}
            elements.append(group)
            word = "FN" if narrow else "FIELD\nNOTES" if key in ("right", "left") or width<80 else "COLLECTED\nFOR LONGER\nLOOKING"
            font_size = 9 if narrow else 24 if key in ("right", "left") and width>80 else 13
            title = {"id": str(uuid.uuid5(namespace, "title:"+key)).upper(), "parentID": root_id, "kind": "text", "name": "Case title",
                     "x": 0, "y": 0, "width": art_width, "height": min(70, height-28), "text": word, "fontSize": font_size,
                     "color": "#CEB875", "typography": {"fontName": "Georgia", "leading": font_size*1.22}}
            elements.append(title)
            foil_ids.append(root_id)
            regions.append({"id": key, "name": row["name"]+" / cap", "origin": origin, "size": size,
                            "anchors": [{"elementIDs": [root_id], "horizontal": 0, "vertical": 0}]})
        else:
            regions.append({"id": key, "name": row["name"], "origin": origin, "size": size})
    artwork = {"background": "#FFFFFF", "backgroundOpacity": 0, "bleed": 0, "elements": elements}
    return {"recipe": {"id": rid, "name": plan["name"]+" / editable wrap source", "symbol": "square.and.pencil",
                       "summary": "Project-owned physical wrap artwork and construction guides.", "parameters": [_recipe_parameter(k, value) for k, value in source_parameters.items()], "parts": []},
            "parameters": source_parameters, "bindings": source_bindings, "artwork": artwork, "regions": regions, "foil_ids": foil_ids}


def build_case_study(call: Call, book_ids: list[str], book_state: dict[str, Any], **options: Any) -> dict[str, Any]:
    """Add this authored case to the exact active project; never opens a project."""
    active = call("form_get_project", {})
    if active.get("id") != book_state.get("id"):
        raise ValueError("The active project changed; rebuild the authoring context before adding a case.")
    objects = {o["id"]: o for o in active["objects"]}
    if any(identifier not in objects or not objects[identifier].get("sheetAssembly") for identifier in book_ids):
        raise ValueError("Every ordered input must be an existing physical sheet assembly in this project.")
    inspections, metrics, bounds = {}, {}, {}
    for identifier in book_ids:
        report = call("form_publication", {"command": "sheet_assembly_inspect", "object_id": identifier, "limit": 50})
        if report.get("project_id") != active["id"] or report.get("object_id") != identifier:
            raise ValueError("The inspected source/project changed before case authoring.")
        inspections[identifier] = report
        r = report["resolved"]
        metrics[identifier] = {"closedWidth": float(r["closed_width_mm"]), "closedHeight": float(r["closed_height_mm"]), "closedThickness": float(r["closed_thickness_mm"])}
        bounds[identifier] = _closed_bounds(report, objects[identifier])
    plan = plan_case_study(book_ids, metrics, **options)
    created = call("form_construction", {"command": "create", "definition": plan["definition"], "name": plan["name"]})
    case_id = created["object_id"]
    lining_created = call("form_construction", {"command": "create", "definition": plan["lining_definition"], "name": plan["name"]+" / actual paper lining"})
    lining_id = lining_created["object_id"]
    call("form_paper", {"command": "configure", "object_id": lining_id, "stock": plan["lining_stock"]})
    lining_bindings = [{"parameter": key, "expression": "v", "inputs": {"v": _ref(case_id, "parameter", key)}} for key in plan["parameters"]]
    call("form_update_object", {"object_id": lining_id, "dimension_bindings": lining_bindings})
    call("form_paper", {"command": "configure", "object_id": case_id, "stock": plan["board_stock"]})
    # Native ordinary-paper closed bounds now include the real wrapping caliper.
    # The wrapper's physical lower surface is already grounded: adding skin
    # here would float the entire case. Independent lining/book offsets below
    # still account for their actual interior board + wrap + lining layers.
    call("form_update_object", {"object_id": case_id, "dimension_bindings": plan["dimension_bindings"], "position": [0, 0, 0]})
    if plan["flat_pose"]:
        v = plan["parameters"]
        call("form_update_object", {"object_id": lining_id, "position": [(v["board"]+v["skin"])/2, v["board"]+2*v["skin"], 0]})
    source = _source_plan(plan, case_id)
    call("form_create_recipe", {"recipe": source["recipe"]})
    art = call("form_add_object", {"recipe_id": source["recipe"]["id"], "name": plan["name"]+" / registered wrap artwork", "parameters": source["parameters"]})
    art_id = art["id"]
    call("form_set_artwork", {"object_id": art_id, "artwork": source["artwork"]})
    call("form_update_object", {"object_id": art_id, "dimension_bindings": source["bindings"], "artwork_regions": source["regions"], "canvas_source_only": True})
    for physical_id in (case_id, lining_id):
        call("form_link_artwork", {"object_id": physical_id, "source_object_id": art_id, "fit": "actual"})
    call("form_paper", {"command": "set_finish", "object_id": case_id, "finish": {
        "id": _id(), "name": "Warm metallic foil / canonical wrap typography", "kind": "foil", "side": "outside", "elementIDs": source["foil_ids"],
        "color": "#CEB875", "depthMM": 0, "heightMM": .015, "roughness": .24, "metallic": .94, "opacity": 1, "enabled": True}})
    final = call("form_construction", {"command": "inspect", "object_id": case_id})
    v = plan["parameters"]
    placements = []
    for index, identifier in enumerate(book_ids):
        low, high = bounds[identifier]["minimum_mm"], bounds[identifier]["maximum_mm"]
        if plan["flat_pose"]:
            a = v["lining"]+v["skin"]+v["board"]
            front_x = v["innerDepth"]/2+a/2
            position = [front_x-v["clearance"]+low[0], a+v["skin"]+v[f"volumeOffset{index}"]-low[1], -(low[2]+high[2])/2]
        else:
            position = None
        placements.append({"source_object_id": identifier, "offset_parameter": f"volumeOffset{index}",
                           "case_cavity_offset_mm": v[f"volumeOffset{index}"], "position_mm": position, "rotation_degrees": 180,
                           "sheet_pose": {"openingDegrees": 0, "activeSpread": 0, "bendMM": 0}, "source_closed_bounds": bounds[identifier]})
    digest = hashlib.sha256(json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"project_id": active["id"], "object_id": case_id, "lining_object_id": lining_id, "physical_ids": [case_id, lining_id], "source_object_id": art_id,
            "ordered_book_ids": list(book_ids), "definition": plan["definition"], "lining_definition": plan["lining_definition"], "dimension_bindings": plan["dimension_bindings"],
            "artwork_recipe_id": source["recipe"]["id"], "artwork_regions": source["regions"], "parameters": final["parameters"],
            "interiors": final.get("interiors"), "interiorAxes": {"stack": [0, 1, 0], "height": [0, 0, 1], "depth": [1, 0, 0], "open_side": "+X"} if plan["flat_pose"] else None,
            "volume_placements": placements, "plan_sha256": digest, "manufacturing_verified": False,
            "evidence_status": "Authored source only; caller must render/review fit, joints, wrap and foil in the ordinary app."}


def reorder_case_volumes(call: Call, case_record: dict[str, Any], book_ids: list[str]) -> dict[str, Any]:
    """Change the source order through one existing public configuration edit.

    This preserves all artwork, source IDs, camera and other scene instances.
    A source count change needs a new authored case plan because control count is
    explicit project data; one-volume plans use the very same builder.
    """
    if len(book_ids) != len(case_record["ordered_book_ids"]):
        raise ValueError("Keep this plan's explicit slot count or author a new case for a different volume count.")
    active = call("form_get_project", {})
    if active.get("id") != case_record["project_id"]:
        raise ValueError("The active project changed before reordering its physical inputs.")
    bindings = dimension_bindings(book_ids)
    call("form_update_object", {"object_id": case_record["object_id"], "dimension_bindings": bindings})
    result = copy.deepcopy(case_record)
    result.update(ordered_book_ids=list(book_ids), dimension_bindings=bindings)
    result["volume_placements"] = None  # Reinspect actual current dimensions before composing a new scene.
    return result
