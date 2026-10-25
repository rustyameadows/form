#!/usr/bin/env python3
"""Exercise the real stdio MCP server against an open FORM app; no model/API calls.

Writes a new validation project and exports to .local/validation. Run against a
disposable FORM_LIBRARY_PATH during development. Existing projects are untouched.
"""
import json
import pathlib
import re
import select
import statistics
import struct
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".local" / "validation"
OUTPUT.mkdir(parents=True, exist_ok=True)


class Client:
    def __init__(self):
        self.sequence = 0
        self.process = subprocess.Popen(
            [str(ROOT / "build/FORM.app/Contents/MacOS/form-mcp")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )

    def rpc(self, method, params=None):
        self.sequence += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        ready, _, _ = select.select([self.process.stdout], [], [], 40)
        assert ready, f"Timed out waiting for {method}"
        response = json.loads(self.process.stdout.readline())
        assert response.get("id") == self.sequence and "error" not in response, response
        return response["result"]

    def call(self, name, arguments=None, expect_error=False):
        response = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if expect_error:
            assert response.get("isError"), response
            return response
        assert not response.get("isError"), response
        return response["structuredContent"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)


def main():
    client = Client()
    try:
        initialize = client.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "FORM smoke test", "version": "1"}})
        assert initialize["protocolVersion"] == "2025-11-25"
        client.process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        client.process.stdin.flush()
        tools = client.rpc("tools/list")["tools"]
        assert len(tools) == 45
        assert len({tool["name"] for tool in tools}) == len(tools)
        project = client.call("form_create_project", {"name": "MCP validation", "template": "cyanotype", "conversation_reference": "FORM local integration test"})
        sleeve = next(obj for obj in project["objects"] if obj["recipeID"] == "sleeve")
        paper = next(obj for obj in project["objects"] if obj["recipeID"] == "paperStack")
        client.call("form_update_object", {"object_id": paper["id"], "parameters": {"sheets": 24}})
        client.call("form_update_object", {"object_id": paper["id"], "parameters": {"sheets": -1}}, expect_error=True)
        assert next(obj for obj in client.call("form_get_project")["objects"] if obj["id"] == paper["id"])["parameters"]["sheets"] == 24
        variant = client.call("form_duplicate_object", {"object_id": sleeve["id"], "mode": "variant", "material_id": "sage"})
        iteration = client.call("form_duplicate_object", {"object_id": sleeve["id"], "mode": "iteration"})
        client.call("form_update_object", {"object_id": sleeve["id"], "parameters": {"width": 220}})
        current = client.call("form_get_project")
        by_id = {obj["id"]: obj for obj in current["objects"]}
        assert by_id[variant["id"]]["parameters"]["width"] == 220
        assert by_id[iteration["id"]]["parameters"]["width"] == 216
        art = sleeve["artwork"]
        art["elements"].append({"id": str(uuid.uuid4()), "kind": "text", "x": 18, "y": 256, "width": 185, "height": 15, "text": "MADE WITH CODEX + FORM", "color": "#E4D8A9", "fontSize": 8})
        client.call("form_set_artwork", {"object_id": sleeve["id"], "artwork": art})
        recipe = {
            "id": "conversationLamp", "name": "Conversation lamp", "symbol": "lamp.desk", "summary": "An agent-defined lamp with native editable controls.",
            "parameters": [
                {"id": "height", "name": "Height", "value": 350, "minimum": 200, "maximum": 650},
                {"id": "shade", "name": "Shade diameter", "value": 220, "minimum": 100, "maximum": 360},
                {"id": "base", "name": "Base diameter", "value": 150, "minimum": 80, "maximum": 280},
            ],
            "parts": [
                {"kind": "cylinder", "values": {"radius": "base/2", "height": "12", "y": "6"}},
                {"kind": "cylinder", "values": {"radius": "7", "height": "height-100", "y": "(height-100)/2+12"}},
                {"kind": "cone", "values": {"bottomRadius": "shade/2", "topRadius": "shade/5", "height": "120", "y": "height-60"}},
            ],
        }
        client.call("form_create_recipe", {"recipe": recipe})
        lamp = client.call("form_add_object", {"recipe_id": "conversationLamp", "name": "A lamp from a conversation", "material_id": "vermillion", "position": [-500, 0, -100]})
        before = len(client.call("form_get_project")["objects"])
        client.call("form_batch", {"operations": [
            {"name": "form_add_object", "arguments": {"recipe_id": "box"}},
            {"name": "form_add_object", "arguments": {"recipe_id": "missing"}},
        ]}, expect_error=True)
        assert len(client.call("form_get_project")["objects"]) == before
        client.call("form_add_note", {"text": "Custom lamp recipe created over the real MCP stdio transport."})
        client.call("form_set_view", {"view": "isolate", "object_id": sleeve["id"]})
        client.call("form_set_view", {"view": "studio"})
        exports = {}
        for fmt in ("png", "pdf", "svg", "json"):
            path = OUTPUT / f"cyanotype.{fmt}"
            exports[fmt] = client.call("form_export", {"format": fmt, "object_id": sleeve["id"], "path": str(path)})
            assert path.stat().st_size > 100
        png = (OUTPUT / "cyanotype.png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">II", png[16:24]) == (3000, 2000)
        pdf = (OUTPUT / "cyanotype.pdf").read_bytes()
        assert pdf.startswith(b"%PDF")
        box = re.search(rb"/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)", pdf)
        assert box, "PDF must declare physical page dimensions"
        assert abs(float(box[1]) - (220 + 6) * 72 / 25.4) < 0.1
        svg = ET.parse(OUTPUT / "cyanotype.svg").getroot()
        assert svg.attrib["width"] == "488.0mm"
        scores = [e for e in svg.iter() if e.attrib.get("stroke") == "#4589B0"]
        cuts = [e for e in svg.iter() if e.attrib.get("stroke") == "#D45A37"]
        assert len(scores) == 4 and len(cuts) == 1, "Never duplicate fabrication cut/score passes"
        assert json.loads((OUTPUT / "cyanotype.json").read_text())["units"] == "mm"
        times = []
        for height in range(350, 370):
            start = time.perf_counter()
            client.call("form_update_object", {"object_id": lamp["id"], "parameters": {"height": height}})
            times.append((time.perf_counter() - start) * 1000)
        client.call("form_open_project", {"project_id": project["id"]})
        reopened = client.call("form_get_project")
        assert next(obj for obj in reopened["objects"] if obj["id"] == lamp["id"])["parameters"]["height"] == 369
        assert reopened["recipes"][0]["id"] == "conversationLamp"
        report = {"project_id": project["id"], "sleeve_id": sleeve["id"], "lamp_id": lamp["id"], "tools": len(tools), "checks": "initialize, discovery, invalid input, linked variants, independent iterations, artwork, custom recipes, batch rollback, all exports, save/reopen", "mcp_edit_median_ms": round(statistics.median(times), 2), "mcp_edit_p95_ms": round(sorted(times)[int(len(times)*.95)-1], 2), "exports": exports, "status": client.call("form_status")}
        (OUTPUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
