#!/usr/bin/env python3
"""Schema28 physical needle surface/process proof via packaged local MCP.
Uses an isolated library and Pyembroidery 1.5.1; sends no hardware commands.
"""
import copy
import json
import pathlib
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT
from smoke_embroidery import element, contour
from verify_embroidery_dst import verify


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call("form_status")["library_path"])
        assert library.resolve().is_relative_to((ROOT / ".local").resolve()), "Use an isolated .local validation library."
        c.discover(['form_export_artwork', 'form_update_object'])
        project = c.call("form_create_project", {"name":"ORBIT / Physical needle surfaces"})
        source = c.call("form_add_object", {"recipe_id":"artboard", "name":"Editable needle source", "parameters":{"width":80,"depth":60},"position":[110,0,0]})
        satin = element("line",8,12,40,0.1,"#C75332","Satin rail",productionRole="stitch")
        fill = element("path",0,0,80,60,"#285B8A","Fill with a real hole",productionRole="stitch",
            path=dict(width=80,height=60,evenOdd=True,contours=[contour([(45,22),(73,22),(73,52),(45,52)]),contour([(53,30),(64,30),(64,43),(53,43)])]))
        artwork = dict(background="#12E22A",bleed=0,elements=[satin,fill])
        c.call("form_set_artwork", {"object_id":source["id"],"artwork":artwork})
        patch = c.call("form_add_object", {"recipe_id":"textilePatch", "name":"ORBIT / Needle surface", "parameters":{"width":80,"depth":60,"corner":3},"position":[0,0,0]})
        c.call("form_link_artwork", {"object_id":patch["id"],"source_object_id":source["id"]})
        design = dict(hoopWidth=100,hoopHeight=100,margin=5,trimJumpThreshold=4,maximumStitches=100000,
            threads=[dict(name="Signal orange",color="#C75332"),dict(name="Orbital blue",color="#285B8A")],
            regions=[dict(id=str(uuid.uuid4()).upper(),elementIDs=[satin["id"]],method="satin",threadIndex=0,stitchLength=4,spacing=0.6,satinWidth=3),
                     dict(id=str(uuid.uuid4()).upper(),elementIDs=[fill["id"]],method="fill",threadIndex=1,stitchLength=2.5,spacing=0.65,angle=15)])
        def apply(value): c.call("form_update_object", {"object_id":patch["id"],"embroidery":value})
        apply(design)
        c.call("form_set_view", {"view":"table","object_id":patch["id"]})
        def renderer(predicate):
            for _ in range(60):
                status=c.call("form_status").get("renderer",{})
                if predicate(status): return status
                time.sleep(0.1)
            raise AssertionError(status)
        first=renderer(lambda r:patch["id"] in r.get("embroidery_sources",{}))
        assert first["embroidery_texture_max_edge"] == 1024
        baseline=c.call("form_get_project")
        configured=copy.deepcopy(design)
        configured["process"]=dict(threadDiameter=0.3,tieIn=True,tieOff=True,tieLength=0.7,tieRepeats=2)
        configured["regions"][0]["underlay"]=dict(method="centerWalk",stitchLength=2.5)
        configured["regions"][1]["underlay"]=dict(method="sparseFill",stitchLength=2.5,spacing=2,inset=0.4)
        apply(configured)
        processed=c.call("form_get_project");assert processed["schemaVersion"] == 28
        preflight=c.call("form_export_artwork", {"object_id":patch["id"],"format":"preflight"})
        assert all(preflight[k]>0 for k in ["underlay_stitches","tie_in_stitches","tie_off_stitches"])
        assert preflight["thread_diameter_mm"] == 0.3
        updated=renderer(lambda r:r.get("embroidery_sources",{}).get(patch["id"]) == preflight["source_digest"])
        assert updated["geometry_builds"] == first["geometry_builds"], "Process edit rebuilt patch construction."
        assert not updated["embroidery_issues"]
        c.call("form_undo");assert c.call("form_get_project") == baseline
        c.call("form_redo");assert c.call("form_get_project") == processed
        outputs={}
        for fmt in ["dst","json","svg"]:
            outputs[fmt]=c.call("form_export_artwork", {"object_id":patch["id"],"format":fmt,"embroidery_format":fmt,"path":str(OUTPUT/("embroidery-process."+fmt))})
        independent=verify(outputs["dst"]["path"],outputs["json"]["path"],outputs["dst"]["thread_sidecar_path"])
        program=json.loads(pathlib.Path(outputs["json"]["path"]).read_text())
        assert all(any(cmd.get("purpose")==purpose and cmd["action"]=="stitch" for cmd in program["commands"]) for purpose in ["underlay","tieIn","tieOff"])
        c.call("form_set_view", {"view":"isolate","object_id":patch["id"]})
        c.call("form_set_view", {"view":"focus","object_id":patch["id"]})
        c.call("form_export", {"format":"png","object_id":patch["id"],"path":str(OUTPUT/"embroidery-physical-surface.png")})
        before_source=renderer(lambda r:r.get("embroidery_sources",{}).get(patch["id"]) == preflight["source_digest"])
        c.call("form_edit_artwork", {"object_id":source["id"],"command":"transform","element_ids":[satin["id"]],"translate_x":1})
        changed=c.call("form_export_artwork", {"object_id":patch["id"],"format":"preflight"})
        assert changed["source_digest"] != preflight["source_digest"]
        source_updated=renderer(lambda r:r.get("embroidery_sources",{}).get(patch["id"]) == changed["source_digest"])
        # Both sources have stitch intent. They are excluded from the ordinary
        # printed frame, so this edit only refreshes the patch's needle material.
        assert source_updated["geometry_builds"] == before_source["geometry_builds"], (
            "Stitch-source edits should preserve both frame and patch geometry: "
            f"{before_source['geometry_builds']} -> {source_updated['geometry_builds']}")
        c.call("form_undo")
        renderer(lambda r:r.get("embroidery_sources",{}).get(patch["id"]) == preflight["source_digest"])
        invalid=copy.deepcopy(configured);invalid["regions"][0]["elementIDs"]=[str(uuid.uuid4()).upper()]
        apply(invalid)
        invalid_state=renderer(lambda r:patch["id"] in r.get("embroidery_issues",{}))
        assert patch["id"] not in invalid_state["embroidery_sources"]
        builds=invalid_state["embroidery_program_builds"]
        time.sleep(0.2);assert c.call("form_status")["renderer"]["embroidery_program_builds"] == builds
        c.call("form_undo")
        recovered=renderer(lambda r:r.get("embroidery_sources",{}).get(patch["id"]) == preflight["source_digest"])
        assert not recovered["embroidery_issues"]
        idle=(recovered["geometry_builds"],recovered["embroidery_program_builds"],recovered["embroidery_texture_builds"])
        for _ in range(3):
            status=c.call("form_status")["renderer"]
            assert (status["geometry_builds"],status["embroidery_program_builds"],status["embroidery_texture_builds"]) == idle
        c.call("form_open_project", {"project_id":project["id"]})
        reopened=c.call("form_export_artwork", {"object_id":patch["id"],"format":"preflight"})
        assert reopened["source_digest"] == preflight["source_digest"]
        report=dict(project_id=project["id"],object_id=patch["id"],preflight=preflight,independent_reader=independent,
                    geometry_builds_for_process=updated["geometry_builds"]-first["geometry_builds"],outputs=outputs)
        path=OUTPUT/"embroidery-surface-report.json";path.write_text(json.dumps(report,indent=2))
        print(json.dumps(dict(passed=True,report=str(path),**independent),indent=2))
    finally: c.close()

if __name__ == "__main__": main()
