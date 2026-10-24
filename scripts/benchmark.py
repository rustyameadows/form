#!/usr/bin/env python3
"""Benchmark the running FORM app in a disposable development library."""
import json
from pathlib import Path
import statistics
import subprocess
import time

from smoke_mcp import Client, OUTPUT


def main():
    client = Client()
    try:
        client.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "FORM benchmark", "version": "1"}})
        project = client.call("form_create_project", {"name": "300 object performance validation"})
        objects = []
        for batch in range(3):
            operations = []
            for i in range(batch * 100, (batch + 1) * 100):
                operations.append({"name": "form_add_object", "arguments": {
                    "recipe_id": "box", "name": f"Volume {i + 1}",
                    "parameters": {"width": 90, "height": 60 + (i % 6) * 15, "depth": 90, "corner": 2},
                    "material_id": ["vermillion", "sage", "oak", "chalk", "aluminum"][i % 5],
                    "position": [(i % 20 - 9.5) * 145, 0, (i // 20 - 7) * 145],
                }})
            objects.extend(client.call("form_batch", {"operations": operations})["results"])
        target = objects[150]
        client.call("form_set_view", {"view": "fit", "object_id": target["id"]})
        time.sleep(0.2)
        before = client.call("form_status")["renderer"]
        client.call("form_update_object", {"object_id": target["id"], "position": [0, 0, 0]})
        time.sleep(0.1)
        transformed = client.call("form_status")["renderer"]
        assert transformed["geometry_builds"] == before["geometry_builds"], "Transforms must preserve existing render geometry"
        elapsed = []
        for height in range(100, 130):
            start = time.perf_counter()
            client.call("form_update_object", {"object_id": target["id"], "parameters": {"height": height}})
            elapsed.append((time.perf_counter() - start) * 1000)
        time.sleep(0.3)
        after = client.call("form_status")["renderer"]
        assert after["object_nodes"] == 300
        assert after["geometry_builds"] - transformed["geometry_builds"] <= 30, "Parameter edits must rebuild only the affected object"
        assert after["renders_continuously"] is False
        pid = subprocess.check_output(["pgrep", "-x", "FORM"], text=True).strip().splitlines()[0]

        def cpu_seconds():
            value = subprocess.check_output(["ps", "-p", pid, "-o", "time="], text=True).strip()
            minutes, seconds = value.split(":")
            return int(minutes) * 60 + float(seconds)

        # Allow the transient edit notification to disappear before sampling idle work.
        time.sleep(2.8)
        start_cpu = cpu_seconds()
        start = time.perf_counter()
        time.sleep(3)
        idle = (cpu_seconds() - start_cpu) / (time.perf_counter() - start) * 100
        rss = int(subprocess.check_output(["ps", "-p", pid, "-o", "rss="], text=True).strip()) / 1024
        report = {
            "objects": 300, "project_id": project["id"],
            "mcp_saved_edit_median_ms": round(statistics.median(elapsed), 2),
            "mcp_saved_edit_p95_ms": round(sorted(elapsed)[int(len(elapsed) * .95) - 1], 2),
            "idle_cpu_percent_over_3s": round(idle, 2), "resident_memory_mb": round(rss, 1),
            "transform_rebuilt_geometry": False, "initial_renderer": before, "final_renderer": after,
        }
        (OUTPUT / "performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
