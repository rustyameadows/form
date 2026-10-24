#!/usr/bin/env python3
"""Measure the real native artwork canvas in a disposable FORM library."""
import json
import statistics
import subprocess
import time
import uuid

from smoke_mcp import Client, OUTPUT


def main():
    client = Client()
    try:
        project = client.call("form_create_project", {"name": "600 element artwork performance"})
        frame = client.call("form_add_object", {"recipe_id": "artboard", "parameters": {"width": 600, "depth": 500}})
        elements = []
        for i in range(300):
            x, y = 8 + (i % 15) * 39, 8 + (i // 15) * 24
            elements.append({"id": str(uuid.uuid4()), "kind": "text", "x": x, "y": y,
                             "width": 36, "height": 12, "fontSize": 11,
                             "text": f"Form / {i + 1:03}", "color": "#292D2C",
                             "typography": {"fontName": "HelveticaNeue-Medium", "tracking": 0.3}})
            elements.append({"id": str(uuid.uuid4()), "kind": "ellipse", "x": x, "y": y + 10,
                             "width": 5, "height": 5, "fontSize": 14, "text": "", "color": "#849381"})
        client.call("form_set_artwork", {"object_id": frame["id"], "artwork": {
            "background": "#F2EDE1", "bleed": 3, "elements": elements}})
        client.call("form_set_view", {"view": "artwork", "object_id": frame["id"]})
        time.sleep(1)
        before = client.call("form_status")["artwork_renderer"]
        assert before["frames"] == 1
        target = elements[300]
        elapsed = []
        for i in range(20):
            start = time.perf_counter()
            client.call("form_edit_artwork", {"object_id": frame["id"], "command": "replace",
                        "elements": [{**target, "x": target["x"] + i * 0.2}]})
            elapsed.append((time.perf_counter() - start) * 1000)
        time.sleep(0.5)
        after = client.call("form_status")["artwork_renderer"]
        assert after["layout_builds"] == before["layout_builds"], "Placement must reuse existing text layouts"
        accessibility_updates = after["accessibility_updates"] - before["accessibility_updates"]
        assert accessibility_updates <= 60, "Moving one element must not rewrite every accessible canvas item"
        assert after["renders_continuously"] is False
        pid = subprocess.check_output(["pgrep", "-x", "FORM"], text=True).strip().splitlines()[0]

        def cpu_seconds():
            value = subprocess.check_output(["ps", "-p", pid, "-o", "time="], text=True).strip()
            minutes, seconds = value.split(":")
            return int(minutes) * 60 + float(seconds)

        time.sleep(2.8)
        settled = client.call("form_status")["artwork_renderer"]
        start_cpu = cpu_seconds()
        start = time.perf_counter()
        time.sleep(3)
        idle = (cpu_seconds() - start_cpu) / (time.perf_counter() - start) * 100
        final = client.call("form_status")["artwork_renderer"]
        assert final["draw_count"] == settled["draw_count"], "Idle canvas must not redraw"
        report = {"elements": 600, "text_objects": 300, "project_id": project["id"],
                  "live_preview": final.get("live_preview"),
                  "saved_edit_median_ms": round(statistics.median(elapsed), 2),
                  "saved_edit_p95_ms": round(sorted(elapsed)[18], 2),
                  "text_layouts_rebuilt_for_placement": after["layout_builds"] - before["layout_builds"],
                  "accessibility_items_updated_for_20_edits": accessibility_updates,
                  "idle_cpu_percent_over_3s": round(idle, 2), "idle_redraws": 0,
                  "resident_memory_mb": round(int(subprocess.check_output(["ps", "-p", pid, "-o", "rss="], text=True).strip()) / 1024, 1),
                  "renderer": final}
        (OUTPUT / "artwork-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
