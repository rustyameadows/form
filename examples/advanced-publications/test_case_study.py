"""Offline source/coordinate regressions. These never call or launch LAB."""
import copy
import importlib.util
import itertools
import math
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location("case_study", pathlib.Path(__file__).with_name("case_study.py"))
case = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(case)


class CaseStudyTests(unittest.TestCase):
    ids = ["00112233-4455-4677-8899-AABBCCDDEEFF", "10112233-4455-4677-8899-AABBCCDDEEFF", "20112233-4455-4677-8899-AABBCCDDEEFF"]
    metrics = {identifier: {"closedWidth": 175+i*11, "closedHeight": 230+i*7, "closedThickness": 10+i*8} for i, identifier in enumerate(ids)}

    def test_one_and_three_volumes_use_identical_generic_capability_and_actual_distinct_stock(self):
        for ids in (self.ids[:1], self.ids):
            p = case.plan_case_study(ids, self.metrics)
            self.assertEqual(len(p["definition"]["panels"]), 5)
            self.assertEqual(len(p["lining_definition"]["panels"]), 5)
            self.assertEqual(p["definition"]["stockThickness"], "board")
            self.assertEqual(p["lining_definition"]["stockThickness"], "lining")
            self.assertNotEqual(p["board_stock"]["profile"]["color"], p["lining_stock"]["profile"]["color"])
            self.assertFalse(any("publicationID" in d for d in (p["definition"], p["lining_definition"])))
            self.assertEqual(p["parameters"]["innerWidth"], sum(self.metrics[i]["closedThickness"] for i in ids)+3+.8*(len(ids)-1))
            for panel in p["definition"]["panels"]:
                wrap = panel["features"]["wrap"]
                value = case._evaluate(wrap["turnInMM"], p["resolved_values"])
                layout = next(r for r in p["layout"] if r["id"] == panel["id"])
                size = [case._evaluate(layout["size"][axis], p["resolved_values"]) for axis in ("x", "y")]
                self.assertLess(value, min(size)/2)

    def test_fullnet_source_bindings_and_regions_match_native_definition_without_scaling(self):
        for ids in (self.ids[:1], self.ids):
            p = case.plan_case_study(ids, self.metrics)
            s = case._source_plan(p, "ABCDEF00-1111-4222-8333-444455556666")
            values = s["parameters"]
            aliases = {"iw": values["innerWidth"], "ih": values["innerHeight"], "idp": values["innerDepth"], "b": values["board"],
                       "s": values["skin"], "l": values["lining"], "t": values["turnIn"], "g": values["layoutGap"]}
            self.assertAlmostEqual(case._evaluate(s["bindings"][0]["expression"], aliases), values["width"])
            self.assertAlmostEqual(case._evaluate(s["bindings"][1]["expression"], aliases), values["depth"])
            self.assertTrue(all(len(b["expression"]) <= 256 for b in s["bindings"]))
            self.assertTrue(all(len(str(r[field][axis])) <= 256 for r in s["regions"] for field in ("origin", "size") for axis in ("x", "y")))
            for row, region in zip(p["layout"], s["regions"]):
                for field in ("origin", "size"):
                    for axis in ("x", "y"):
                        self.assertAlmostEqual(case._evaluate(row[field][axis], p["resolved_values"]), case._evaluate(region[field][axis], values))
                if row["wrapped"]:
                    origin = [case._evaluate(region["origin"][axis], values) for axis in ("x", "y")]
                    size = [case._evaluate(region["size"][axis], values) for axis in ("x", "y")]
                    margin = values["board"]+values["turnIn"]
                    self.assertGreaterEqual(origin[0], margin);self.assertGreaterEqual(origin[1], margin)
                    self.assertLessEqual(origin[0]+size[0]+margin, values["width"]+1e-8)
                    self.assertLessEqual(origin[1]+size[1]+margin, values["depth"]+1e-8)
            self.assertEqual(s["artwork"]["backgroundOpacity"], 0)
            self.assertTrue(all(e["fontSize"] > 0 for e in s["artwork"]["elements"] if e["kind"] == "text"))

    def test_flat_case_rigid_permutation_preserves_board_separation_and_cavity_axes(self):
        p = case.plan_case_study(self.ids, self.metrics)
        definition, values = p["definition"], p["resolved_values"]
        bounds = []
        for panel, component in zip(definition["panels"], definition["components"]):
            origin = [case._evaluate(component["anchor"][a], values) for a in ("x", "y")]
            position = [case._evaluate(component["position"][a], values) for a in ("x", "y", "z")]
            matrix = case._rotation(*(component["rotationDegrees"][a] for a in ("x", "y", "z")))
            points = []
            for point in panel["polygon"]:
                x, y = [case._evaluate(point[a], values) for a in ("x", "y")]
                for z in (-values["board"]/2, values["board"]/2):
                    local = [x-origin[0], -y+origin[1], z]
                    points.append([position[i]+sum(matrix[i][j]*local[j] for j in range(3)) for i in range(3)])
            bounds.append(([min(q[i] for q in points) for i in range(3)], [max(q[i] for q in points) for i in range(3)]))
        for a, b in itertools.combinations(bounds, 2):
            overlap = [min(a[1][i], b[1][i])-max(a[0][i], b[0][i]) for i in range(3)]
            self.assertFalse(all(v > 1e-7 for v in overlap), "Real chipboard cores must not intersect.")
        matrix = case._rotation(90, 0, 90)
        for source, target in (([1, 0, 0], [0, 1, 0]), ([0, 1, 0], [0, 0, 1]), ([0, 0, 1], [1, 0, 0])):
            actual = [sum(matrix[i][j]*source[j] for j in range(3)) for i in range(3)]
            self.assertTrue(all(abs(a-b) < 1e-10 for a, b in zip(actual, target)))

    def test_all_emitted_artwork_layers_supply_native_common_fields_and_valid_group_ownership(self):
        import uuid
        required = {"id", "kind", "x", "y", "width", "height", "text", "color", "fontSize"}
        for ids in (self.ids[:1], self.ids):
            source = case._source_plan(case.plan_case_study(ids, self.metrics), "ABCDEF00-1111-4222-8333-444455556666")
            layers = source["artwork"]["elements"]
            owners = {element["id"]: element for element in layers}
            self.assertEqual(len(owners), len(layers))
            for element in layers:
                self.assertTrue(required.issubset(element), f"Every native ArtworkElement, including groups, needs its common Codable fields: {element}")
                uuid.UUID(element["id"])
                self.assertIn(element["kind"], ("group", "text"))
                self.assertIsInstance(element["text"], str)
                self.assertRegex(element["color"], r"^#[0-9A-Fa-f]{6}$")
                for key in ("x", "y", "width", "height", "fontSize"):
                    self.assertNotIsInstance(element[key], bool)
                    self.assertTrue(isinstance(element[key], (int, float)) and math.isfinite(element[key]), key)
                self.assertGreater(element["width"], 0);self.assertGreater(element["height"], 0);self.assertGreater(element["fontSize"], 0)
                if element.get("parentID"):
                    self.assertEqual(owners[element["parentID"]]["kind"], "group")
            self.assertTrue(set(source["foil_ids"]).issubset(owners))
            self.assertTrue(all(owners[identifier]["kind"] == "group" for identifier in source["foil_ids"]))

    def test_order_is_explicit_and_offsets_change_without_replacing_source_artwork(self):
        forward = case.plan_case_study(self.ids, self.metrics)
        reverse = case.plan_case_study(list(reversed(self.ids)), self.metrics)
        self.assertEqual(forward["parameters"]["innerWidth"], reverse["parameters"]["innerWidth"])
        self.assertNotEqual(forward["parameters"]["volumeOffset1"], reverse["parameters"]["volumeOffset1"])
        self.assertEqual(forward["dimension_bindings"][4]["inputs"]["t0"]["sourceObjectID"], self.ids[0])
        calls = []
        record = {"project_id": "P", "object_id": "CASE", "ordered_book_ids": self.ids, "source_object_id": "ART", "volume_placements": []}
        def callback(tool, args):
            calls.append((tool, copy.deepcopy(args)))
            return {"id": "P"} if tool == "form_get_project" else {}
        changed = case.reorder_case_volumes(callback, record, list(reversed(self.ids)))
        self.assertEqual(changed["source_object_id"], "ART")
        self.assertEqual([name for name, _ in calls], ["form_get_project", "form_update_object"])
        self.assertNotIn("artwork", calls[1][1])
        self.assertNotIn("parameters", calls[1][1])

    def test_changed_project_and_invalid_inputs_reject_before_mutations(self):
        calls = []
        def callback(tool, args):
            calls.append(tool)
            return {"id": "B", "objects": []}
        with self.assertRaises(ValueError): case.build_case_study(callback, self.ids, {"id": "A"})
        self.assertEqual(calls, ["form_get_project"])
        for ids in ([], self.ids+self.ids):
            with self.assertRaises(ValueError): case.dimension_bindings(ids)
        with self.assertRaises(ValueError): case._evaluate("__import__('os').system('anything')", {})

    def test_closed_bounds_use_native_curve_and_alias_authority_even_when_enclosure_is_paged(self):
        report = {"object_id": self.ids[0], "resolved": {"closed_width_mm": 180.5, "closed_thickness_mm": 18.2,
                  "closed_height_mm": 241.1, "closed_bounds_mm": {"minimum_mm": [-6.5, -3.2, -125.1], "maximum_mm": [174, 15, 116]}},
                  "enclosure": {"truncated": True, "items": [{"authored": {"size": {"x": "unknownAlias(bindingFlexWidth)", "y": "do not evaluate"}}}]}}
        source = {"id": self.ids[0], "parameters": {}, "sheetAssembly": {"derived": {"unavailableToPython": "nativeOnly"}}}
        actual = case._closed_bounds(report, source)
        self.assertEqual(actual, report["resolved"]["closed_bounds_mm"])
        actual["minimum_mm"][0] = 999
        self.assertEqual(report["resolved"]["closed_bounds_mm"]["minimum_mm"][0], -6.5, "The retained inspection evidence stays immutable.")

    def test_missing_malformed_or_wrong_owner_native_bounds_never_fall_back_to_an_approximation(self):
        good = {"object_id": self.ids[0], "resolved": {"closed_width_mm": 100, "closed_thickness_mm": 10,
                "closed_height_mm": 140, "closed_bounds_mm": {"minimum_mm": [0, 0, -70], "maximum_mm": [100, 10, 70]}}}
        variants = []
        missing = copy.deepcopy(good);missing["resolved"].pop("closed_bounds_mm");variants.append(missing)
        wrong = copy.deepcopy(good);wrong["object_id"] = self.ids[1];variants.append(wrong)
        mismatch = copy.deepcopy(good);mismatch["resolved"]["closed_bounds_mm"]["maximum_mm"][0] = 101;variants.append(mismatch)
        for value in [True, float("nan"), float("inf"), "100"]:
            invalid = copy.deepcopy(good);invalid["resolved"]["closed_bounds_mm"]["maximum_mm"][0] = value;variants.append(invalid)
        for report in variants:
            with self.assertRaises(ValueError):case._closed_bounds(report, {"id": self.ids[0]})

    def test_builder_emits_only_existing_public_commands_and_retains_two_material_owners(self):
        import uuid
        project_id = str(uuid.uuid4()).upper()
        objects = [{"id": identifier, "parameters": {}, "sheetAssembly": {"publicationID": str(uuid.uuid4()).upper()}} for identifier in self.ids]
        active = {"id": project_id, "objects": objects}
        calls, definitions = [], {}
        def callback(tool, args):
            calls.append((tool, copy.deepcopy(args)))
            if tool == "form_get_project": return active
            if tool == "form_publication":
                m = self.metrics[args["object_id"]]
                return {"project_id": project_id, "object_id": args["object_id"], "resolved": {"closed_bounds_mm": {"minimum_mm": [0, 0, -m["closedHeight"]/2], "maximum_mm": [m["closedWidth"], m["closedThickness"], m["closedHeight"]/2]}, "size_mm": {"x": m["closedWidth"], "y": m["closedHeight"]}, "stack_thickness_mm": m["closedThickness"],
                        "trim_width_mm": m["closedWidth"], "trim_height_mm": m["closedHeight"], "text_block_thickness_mm": m["closedThickness"],
                        "binding_allowance_mm": 0, "spine_thickness_mm": m["closedThickness"], "leaf_count": 20, "logical_page_count": 40,
                        "closed_width_mm": m["closedWidth"], "closed_height_mm": m["closedHeight"], "closed_thickness_mm": m["closedThickness"]},
                        "enclosure": {"items": [], "total": 0, "truncated": False}}
            if tool == "form_construction":
                if args["command"] == "create":
                    identifier = str(uuid.uuid4()).upper();definitions[identifier] = args["definition"]
                    return {"object_id": identifier}
                return {"parameters": {p["name"]: p["value"] for p in definitions[args["object_id"]]["parameters"]}, "interiors": []}
            if tool == "form_add_object": return {"id": str(uuid.uuid4()).upper()}
            return {}
        result = case.build_case_study(callback, self.ids, active)
        self.assertEqual(len(result["physical_ids"]), 2)
        self.assertNotEqual(result["object_id"], result["lining_object_id"])
        self.assertEqual(len(result["volume_placements"]), 3)
        self.assertTrue(all(p["rotation_degrees"] == 180 for p in result["volume_placements"]))
        positions = {args["object_id"]: args["position"] for name, args in calls
                     if name == "form_update_object" and "position" in args}
        self.assertEqual(positions[result["object_id"]], [0, 0, 0],
                         "Native closed grounding already includes wrapping caliper; no extra skin-height offset.")
        parameters = result["parameters"]
        self.assertEqual(positions[result["lining_object_id"]],
                         [(parameters["board"]+parameters["skin"])/2, parameters["board"]+2*parameters["skin"], 0],
                         "The independent lining keeps its existing interior layer registration.")
        base = parameters["lining"]+parameters["skin"]+parameters["board"]
        for i, placement in enumerate(result["volume_placements"]):
            low = placement["source_closed_bounds"]["minimum_mm"]
            self.assertAlmostEqual(placement["position_mm"][1], base+parameters["skin"]+parameters[f"volumeOffset{i}"]-low[1],
                                   msg="Removing the outer wrapper compensation must not move fitted book layers.")
        source_updates = [args for name, args in calls if name == "form_update_object" and args["object_id"] == result["source_object_id"]]
        self.assertTrue(source_updates[0]["canvas_source_only"])
        self.assertEqual(sum(name == "form_link_artwork" for name, _ in calls), 2)
        self.assertTrue(all(name in {"form_get_project", "form_publication", "form_construction", "form_paper", "form_update_object", "form_create_recipe", "form_add_object", "form_set_artwork", "form_link_artwork"} for name, _ in calls))


if __name__ == "__main__":
    unittest.main()
