#!/usr/bin/env python3
"""Generate synthetic ordinary-Copy HTML, without Figma or any clipboard access.

An independent Python wire writer (stdlib only); no production Swift encoder or
decoder is invoked. Field tags come from the public primary schema pinned at:
https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/fig/schema/fig.kiwi
Kiwi format: https://github.com/evanw/kiwi/tree/fe3ca9484ac055ccd39fe144218ec11f720222ae
The generated scene has 60 visible source nodes per card: frame, nested group,
48 colored shapes, and 10 editable labels. The default has 1500 source nodes.
"""

import argparse
import base64
import json
from pathlib import Path
import struct
import zlib


# (name, type, wire tag, array). Struct fields are positional.
def field(name, kind, tag=0, array=False):
    return (name, kind, tag, array)


def enum(name, entries):
    return (name, 0, [field(key, "uint", value) for key, value in entries])


SCHEMA = [
    ("Message", 2, [field("type", "MessageType", 1), field("nodeChanges", "NodeChange", 4, True)]),
    enum("MessageType", [("NODE_CHANGES", 1)]),
    ("NodeChange", 2, [
        field("guid", "GUID", 1), field("phase", "NodePhase", 2), field("parentIndex", "ParentIndex", 3),
        field("type", "NodeType", 4), field("name", "string", 5), field("visible", "bool", 6),
        field("size", "Vector", 11), field("transform", "Matrix", 12), field("fontSize", "float", 21),
        field("paragraphSpacing", "float", 23), field("textAlignHorizontal", "TextAlignHorizontal", 32),
        field("textDecoration", "TextDecoration", 35), field("fillPaints", "Paint", 38, True),
        field("lineHeight", "Number", 40), field("fontName", "FontName", 41), field("textData", "TextData", 42),
        field("textAutoResize", "TextAutoResize", 46), field("styleID", "uint", 49),
        field("frameMaskDisabled", "bool", 115), field("resizeToFit", "bool", 117), field("letterSpacing", "Number", 165),
    ]),
    ("GUID", 1, [field("sessionID", "uint"), field("localID", "uint")]),
    ("ParentIndex", 1, [field("guid", "GUID"), field("position", "string")]),
    enum("NodeType", [("DOCUMENT", 1), ("CANVAS", 2), ("FRAME", 4), ("ELLIPSE", 9), ("RECTANGLE", 10), ("TEXT", 13)]),
    enum("NodePhase", [("CREATED", 0)]),
    ("Vector", 1, [field("x", "float"), field("y", "float")]),
    ("Matrix", 1, [field(key, "float") for key in ["m00", "m01", "m02", "m10", "m11", "m12"]]),
    ("Color", 1, [field(key, "float") for key in ["r", "g", "b", "a"]]),
    ("Paint", 2, [field("type", "PaintType", 1), field("color", "Color", 2), field("opacity", "float", 3), field("visible", "bool", 4)]),
    enum("PaintType", [("SOLID", 0)]),
    ("FontName", 1, [field(key, "string") for key in ["family", "style", "postscript"]]),
    ("Number", 1, [field("value", "float"), field("units", "NumberUnits")]),
    enum("NumberUnits", [("RAW", 0), ("PIXELS", 1), ("PERCENT", 2)]),
    enum("TextAutoResize", [("NONE", 0)]),
    enum("TextDecoration", [("NONE", 0), ("UNDERLINE", 1)]),
    enum("TextAlignHorizontal", [("LEFT", 0), ("CENTER", 1), ("RIGHT", 2)]),
    ("TextData", 2, [field("characters", "string", 1), field("characterStyleIDs", "uint", 2, True),
        field("styleOverrideTable", "NodeChange", 3, True), field("lines", "TextLineData", 12, True)]),
    ("TextLineData", 2, [field("lineType", "LineType", 1), field("styleId", "int", 10), field("sourceDirectionality", "SourceDirectionality", 9)]),
    enum("LineType", [("PLAIN", 0)]),
    enum("SourceDirectionality", [("AUTO", 0), ("LTR", 1), ("RTL", 2)]),
]
TYPES = {definition[0]: index for index, definition in enumerate(SCHEMA)}
TYPES.update({"bool": -1, "byte": -2, "int": -3, "uint": -4, "float": -5, "string": -6})
DEFINITIONS = {definition[0]: definition for definition in SCHEMA}


def varuint(value):
    assert 0 <= value <= 0xFFFFFFFF
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def string(value):
    assert "\0" not in value
    return value.encode("utf-8") + b"\0"


def binary_schema():
    result = bytearray(varuint(len(SCHEMA)))
    for name, kind, fields in SCHEMA:
        result += string(name) + bytes([kind]) + varuint(len(fields))
        for key, type_name, tag, array in fields:
            number = TYPES[type_name]
            zigzag = (number << 1) ^ (number >> 31)
            result += string(key) + varuint(zigzag) + bytes([array]) + varuint(tag)
    return bytes(result)


def encode(value, type_name):
    if type_name == "bool":
        return bytes([bool(value)])
    if type_name == "uint":
        return varuint(value)
    if type_name == "int":
        return varuint((value << 1) ^ (value >> 31))
    if type_name == "string":
        return string(value)
    if type_name == "float":
        bits, = struct.unpack("<I", struct.pack("<f", value))
        rotated = ((bits >> 23) | (bits << 9)) & 0xFFFFFFFF
        return struct.pack("<I", rotated) if rotated & 255 else b"\0"
    _, kind, fields = DEFINITIONS[type_name]
    if kind == 0:
        return varuint(next(field[2] for field in fields if field[0] == value))
    result = bytearray()
    for key, child_type, tag, array in fields:
        if key not in value:
            assert kind != 1, f"Missing positional field {key}"
            continue
        if kind == 2:
            result += varuint(tag)
        if array:
            result += varuint(len(value[key]))
            for child in value[key]:
                result += encode(child, child_type)
        else:
            result += encode(value[key], child_type)
    if kind == 2:
        result.append(0)
    return bytes(result)


def guid(identifier):
    return {"sessionID": 7, "localID": identifier}


def node(identifier, parent, kind, name, x=0, y=0, width=30, height=20):
    value = {"guid": guid(identifier), "phase": "CREATED", "type": kind, "name": name, "visible": True,
             "size": {"x": width, "y": height}, "transform": {"m00": 1, "m01": 0, "m02": x, "m10": 0, "m11": 1, "m12": y}}
    if parent is not None:
        value["parentIndex"] = {"guid": guid(parent), "position": f"{identifier:08d}"}
    return value


def solid(r, g, b):
    return {"type": "SOLID", "color": {"r": r, "g": g, "b": b, "a": 1}, "opacity": 1, "visible": True}


def scene(cards):
    result = [node(1, None, "DOCUMENT", "Synthetic document"), node(2, 1, "CANVAS", "Synthetic page")]
    for card in range(cards):
        first = 100 + card * 60
        frame = node(first, 2, "FRAME", f"Card {card}", card % 5 * 340, card // 5 * 260, 320, 240)
        frame.update(frameMaskDisabled=True, fillPaints=[solid(.95, .96, .98)])
        group = node(first + 1, first, "FRAME", f"Contents {card}", 12, 24, 296, 208)
        group["resizeToFit"] = True
        result += [frame, group]
        for index in range(48):
            shape = node(first + 2 + index, first + 1, "ELLIPSE" if index % 3 == 0 else "RECTANGLE",
                         f"Tile {card}.{index}", index % 8 * 35, index // 8 * 24, 28, 18)
            shape["fillPaints"] = [solid(index % 5 / 6 + .1, card % 5 / 6 + .1, .6)]
            result.append(shape)
        for index in range(10):
            text = node(first + 50 + index, first + 1, "TEXT", f"Label {card}.{index}", index % 5 * 58, 150 + index // 5 * 24, 54, 20)
            text.update(fontSize=12, fontName={"family": "Helvetica", "style": "Regular", "postscript": "Helvetica"},
                        lineHeight={"value": 1.5, "units": "RAW"}, letterSpacing={"value": 10, "units": "PERCENT"},
                        textAutoResize="NONE", fillPaints=[solid(.1, .2, .3)], textData={"characters": f"{card + 1}.{index + 1}"})
            if card == 0 and index == 0:
                text.update(fontSize=16, size={"x": 240, "y": 72}, textData={"characters": "A😀\nאב", "characterStyleIDs": [0, 2, 2],
                    "styleOverrideTable": [{"styleID": 2, "fontSize": 32, "textDecoration": "UNDERLINE", "fillPaints": [solid(1, 0, 0)]},
                                           {"styleID": 9, "paragraphSpacing": 12, "textAlignHorizontal": "RIGHT"}],
                    "lines": [{"lineType": "PLAIN", "sourceDirectionality": "AUTO"}, {"lineType": "PLAIN", "styleId": 9, "sourceDirectionality": "RTL"}]})
            result.append(text)
    return result


def deflate(data):
    compressor = zlib.compressobj(level=9, wbits=-15)
    return compressor.compress(data) + compressor.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cards", type=int, default=25)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / ".local/validation/figma-paste/dense-script-1500.html")
    args = parser.parse_args()
    if not 1 <= args.cards <= 70:
        parser.error("--cards must be 1–70 (the decoder scene budget is 5000 records)")
    nodes = scene(args.cards)
    chunks = [deflate(binary_schema()), deflate(encode({"type": "NODE_CHANGES", "nodeChanges": nodes}, "Message"))]
    binary = b"fig-kiwi" + struct.pack("<I", 101)
    for chunk in chunks:
        binary += struct.pack("<I", len(chunk)) + chunk
    metadata = base64.b64encode(json.dumps({"fileKey": "synthetic-lab-fixture", "pasteID": 1, "dataType": "scene"}, separators=(",", ":")).encode()).decode()
    html = f'<meta charset="utf-8"><span data-metadata="<!--(figmeta){metadata}(/figmeta)-->"></span><span data-buffer="<!--(figma){base64.b64encode(binary).decode()}(/figma)-->"></span>'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(html, encoding="utf-8")
    print(json.dumps({"output": str(args.output), "visible_source_nodes": args.cards * 60, "raw_records": len(nodes), "html_bytes": len(html.encode()), "codec": "raw-deflate", "synthetic": True}))


if __name__ == "__main__":
    main()
