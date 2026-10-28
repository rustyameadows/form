#!/usr/bin/env python3
"""Independently decode FORM output with pinned Pyembroidery 1.5.1.
Usage: python verify_embroidery_dst.py file.dst file.json [file.threads.json]
Install validation-only dependency in an isolated venv: pip install pyembroidery==1.5.1.
"""
import json
import math
import pathlib
import sys
import importlib.metadata
import pyembroidery as embroidery


def verify(dst, source, sidecar=None):
    assert importlib.metadata.version("pyembroidery") == "1.5.1"
    source = json.loads(pathlib.Path(source).read_text())
    pattern = embroidery.read(str(dst), settings={"trim_at": 1000000, "clipping": False})
    expected = []
    x = y = 0
    actions = {"stitch": embroidery.STITCH, "jump": embroidery.JUMP,
               "colorChange": embroidery.COLOR_CHANGE, "end": embroidery.END}
    for command in source["commands"]:
        action = command["action"]
        if action in ("stitch", "jump"):
            dx, dy = command["x"] - x, command["y"] - y
            steps = max(1, math.ceil(max(abs(dx), abs(dy)) / 121))
            startx, starty = x, y
            for index in range(1, steps + 1):
                x = startx + round(dx * index / steps)
                y = starty + round(dy * index / steps)
                expected.append([x, y, actions[action]])
        elif action == "trim":
            for dx, dy in [(2, 2), (-4, -4), (2, 2)]:
                x += dx; y += dy
                expected.append([x, y, embroidery.JUMP])
        else:
            assert (command["x"], command["y"]) == (x, y)
            expected.append([x, y, actions[action]])
    actual = [[int(x), int(y), c & embroidery.COMMAND_MASK] for x, y, c in pattern.stitches]
    assert actual == expected, next(((i, a, e) for i, (a, e) in enumerate(zip(actual, expected)) if a != e), (len(actual), len(expected)))
    design = source["design"]
    needle = [(x, y) for x, y, c in actual if c == embroidery.STITCH]
    assert needle
    assert all(abs(x) <= (design["hoopWidth"] / 2 - design["margin"]) * 10 + 1e-7 and
               abs(y) <= (design["hoopHeight"] / 2 - design["margin"]) * 10 + 1e-7 for x, y in needle)
    assert sum(c == embroidery.COLOR_CHANGE for _, _, c in actual) == sum(c["action"] == "colorChange" for c in source["commands"])
    # The independent default reader must also preserve all needle points while interpreting trims.
    interpreted = embroidery.read(str(dst))
    assert [(int(x), int(y)) for x, y, c in interpreted.stitches if c & embroidery.COMMAND_MASK == embroidery.STITCH] == needle
    if sidecar:
        manifest = json.loads(pathlib.Path(sidecar).read_text())
        order = []
        for c in source["commands"]:
            if not order or c["action"] == "colorChange": order.append(c["threadIndex"])
        sequence = manifest["thread_sequence"]
        assert [t["thread_index"] for t in sequence] == order
        assert [t["color"] for t in sequence] == [design["threads"][i]["color"] for i in order]
        assert manifest["source_digest"] == source["sourceDigest"]
        assert manifest["hoop_width_mm"] == design["hoopWidth"] and manifest["hoop_height_mm"] == design["hoopHeight"]
        movement = [(c["x"] / 10, c["y"] / 10) for c in source["commands"] if c["action"] in ("stitch", "jump")]
        xs, ys = zip(*movement); bounds = manifest["bounds_mm"]
        assert all(abs(a-b) < 1e-8 for a, b in zip([bounds["x"], bounds["y"], bounds["width"], bounds["height"]], [min(xs), min(ys), max(xs)-min(xs), max(ys)-min(ys)]))
    return {"reader": "pyembroidery 1.5.1", "decoded_records": len(actual), "stitches": len(needle), "thread_passes": sum(c == embroidery.COLOR_CHANGE for _, _, c in actual) + 1}


if __name__ == "__main__":
    print(json.dumps(verify(*sys.argv[1:]), indent=2))
