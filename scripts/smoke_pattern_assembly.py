#!/usr/bin/env python3
"""Packaged source-linked assembly workflow. Requires an isolated .local library.
No printer connection, slicing or machine command is issued.
"""
import copy
import hashlib
import json
import math
import pathlib
from smoke_mcp import Client, OUTPUT, ROOT, camera_pose, project_source
from verify_assembly_mesh import verify


def main():
    client=Client()
    try:
        status=client.call("form_status")
        assert pathlib.Path(status["library_path"]).resolve().is_relative_to((ROOT/".local").resolve()), "Refusing an ordinary project library."
        client.discover(["form_cloth","form_set_artwork","form_undo","form_open_print"])
        created=client.call("form_create_project",{"name":"NASA / Original curved pouch assembly","template":"pouchAssembly"})
        project=client.call("form_get_project")
        assert project["schemaVersion"]>=36
        assembly=next(o for o in project["objects"] if o.get("patternAssembly"))
        source=next(o for o in project["objects"] if o["id"]==assembly["patternAssembly"]["sourceObjectID"])
        assert assembly.get("cloth") is None
        client.call("form_set_view",{"view":"table","object_id":assembly["id"]})

        def cloth(command, object_id=assembly["id"], **fields):
            return client.call("form_cloth",dict(command=command,object_id=object_id,**fields))

        initial=cloth("get")
        assert initial["derived_mesh_persisted"] is False
        proof={"definition":initial["assembly"],"study":initial["definition"],
               "panel_records":initial["assembly_panels"],"material_points_mm":initial["material_points_mm"],
               "seam_samples":initial["seam_samples"],"source_artwork":source["artwork"],"source_digest":initial["source_digest"]}
        proof_path=OUTPUT/"pattern-assembly-source.json"
        proof_path.write_text(json.dumps(proof,indent=2))
        independent=verify(proof_path)
        baseline=client.call("form_get_project")
        before=cloth("snapshot")["mesh"]
        # Preparation is an explicit numerical stage, with no physical time.
        preparation_batches=[]
        for batch in range(1024):
            state=cloth("get")["diagnostics"]
            if state.get("preparation",{}).get("status")=="ready": break
            assert state["completedFrames"]==0 and state["elapsedSeconds"]==0
            progressed=cloth("step",frames=1)
            preparation_batches.append(progressed["diagnostics"]["preparation"])
            if batch==0:
                pending=cloth("snapshot")["mesh"]
                assert pending["positionsMm"]==before["positionsMm"]
                assert pending.get("preparation_candidate_positions_mm")
        else: raise AssertionError("Preparation did not finish within1024 bounded batches.")
        preparation=cloth("get")["diagnostics"]["preparation"]
        assert preparation["maximumRelativeError"]<=0.05 and preparation["p95RelativeError"]<=0.01
        assert preparation["evaluations"]<=preparation["maximumEvaluations"]
        # Exercise the complete declared run, not only early seam closure.
        # Independently recompute structural strain from actual snapshot positions.
        structural=[link for link in initial["definition"]["mesh"]["links"] if link["kind"] in ("warp","weft","shear")]
        def strains(mesh):
            positions=mesh["positionsMm"]
            lengths=[math.dist(tuple(positions[link["a"]][k] for k in "xyz"),tuple(positions[link["b"]][k] for k in "xyz")) for link in structural]
            ratios=sorted(length/link["restLengthMm"] for length,link in zip(lengths,structural))
            return {"minimum":ratios[0],"maximum":ratios[-1],"p95":ratios[int((len(ratios)-1)*0.95)],
                    "maximum_absolute_error_mm":max(abs(length-link["restLengthMm"]) for length,link in zip(lengths,structural))}
        samples=[];worst=1.0
        for frame in range(1,241):
            progressed=cloth("step",frames=1)
            worst=max(worst,progressed["diagnostics"]["maximumStretchRatio"])
            if frame==1 or frame%30==0:
                actual=strains(cloth("snapshot")["mesh"])
                assert abs(actual["maximum"]-progressed["diagnostics"]["maximumStretchRatio"])<1e-8
                samples.append(dict(frame=frame,**actual))
        after=cloth("snapshot")["mesh"]
        # Preserve the completed physical proof before any later document/camera
        # assertion, including when a person interacts with the native window.
        (OUTPUT/"pattern-assembly-frame240.json").write_text(json.dumps({
            "mesh":after,"definition":initial["definition"],"assembly":initial["assembly"],
            "material_points_mm":initial["material_points_mm"],"diagnostics":progressed["diagnostics"],
            "preparation":preparation,"structural_samples":samples,"worst_transient":worst,
            "baseline_project":baseline},indent=2))
        final=strains(after)
        assert final["minimum"]>=0.90 and final["maximum"]<=1.05 and final["p95"]<=1.01 and worst<=1.15, {"final":final,"worst_transient":worst,"samples":samples}
        assert after["positionsMm"] != before["positionsMm"]
        assert after["uv"]==before["uv"] and after["triangles"]==before["triangles"]
        assert progressed["diagnostics"]["maximumSeamGapMm"]<3
        assert project_source(client.call("form_get_project"))==project_source(baseline), "Runtime mutated the saved source/history or camera pose."
        for pin in initial["definition"]["mesh"]["pins"]:
            actual=after["positionsMm"][pin["vertex"]]
            assert max(abs(actual[k]-pin["targetMm"][k]) for k in ("x","y","z"))<1e-7
        assert all(math.isfinite(p[k]) for p in after["positionsMm"] for k in ("x","y","z"))
        path=OUTPUT/"pattern-assembly-current.json"
        output=cloth("snapshot",path=str(path))
        assert output["bytes"]==path.stat().st_size
        assert output["sha256"]==hashlib.sha256(path.read_bytes()).hexdigest()
        saved=json.loads(path.read_text())
        assert saved["assembly"]==initial["assembly"] and saved["material_points_mm"]==initial["material_points_mm"]
        cloth("reset");assert cloth("snapshot")["mesh"]["positionsMm"]==before["positionsMm"]

        label=client.call("form_add_object",{"recipe_id":"textileLabel","name":"Physical material label","parameters":{"width":40,"depth":18}})
        panel=next(p for p in initial["assembly_panels"] if p["materialSizeMm"]["y"]>100)
        attached=cloth("attach",object_id=label["id"],surface_object_id=assembly["id"],panel=panel["panelIndex"],material_x_mm=130,material_y_mm=80,offset_mm=2)
        anchor=attached["assembly_attachment"]["anchor"]
        declaration=copy.deepcopy(initial["assembly"]);declaration["maximumEdgeMm"]=26
        preconfigure=client.call("form_get_project")
        cloth("configure",assembly=declaration)
        assert cloth("get",object_id=label["id"])["assembly_attachment"]["anchor"]==anchor
        client.call("form_undo");assert project_source(client.call("form_get_project"))==project_source(preconfigure)

        # Change original cubic handles, retaining both actual counterpart lengths.
        revised=copy.deepcopy(source["artwork"])
        main=next(e for e in revised["elements"] if e.get("sewingPiece",{}).get("name")=="Rounded pouch main panel")
        main["path"]["contours"][0]["nodes"][2]["outgoing"]["y"]+=3
        main["path"]["contours"][0]["nodes"][5]["incoming"]["y"]+=3
        preshape=client.call("form_get_project")
        client.call("form_set_artwork",{"object_id":source["id"],"artwork":revised})
        assert cloth("get")["source_digest"]!=initial["source_digest"]
        client.call("form_undo");assert project_source(client.call("form_get_project"))==project_source(preshape)

        # A broken original edge is explicit and cannot show or advance old cloth.
        broken=copy.deepcopy(source["artwork"])
        main=next(e for e in broken["elements"] if e.get("sewingPiece",{}).get("name")=="Rounded pouch main panel")
        main["path"]["contours"][0]["nodes"][2]["outgoing"]["y"]+=5
        client.call("form_set_artwork",{"object_id":source["id"],"artwork":broken})
        assert cloth("get").get("issue")
        client.call("form_cloth",{"command":"step","object_id":assembly["id"]},expect_error=True)
        client.call("form_undo");assert project_source(client.call("form_get_project"))==project_source(preshape)
        client.call("form_open_project",{"project_id":created["id"]})
        assert cloth("get")["diagnostics"]["completedFrames"]==0
        reopened_camera=client.call("form_get_project")["camera"]
        assert camera_pose(reopened_camera)==camera_pose(preshape["camera"]),(preshape["camera"],reopened_camera)
        gate=client.call("form_open_print",{"object_id":assembly["id"]})
        assert "open flexible surface" in (gate.get("validation_error") or "")
        assert gate["print_commands_enabled"] is False
        report={"passed":True,"project_id":created["id"],"independent_geometry":independent,
                "computed_diagnostics":progressed["diagnostics"],"preparation":preparation,"initial_join":progressed["diagnostics"].get("initialJoin"),"structural_strain":{"final":final,"worst_transient":worst,"samples":samples},"physical_anchor":anchor,
                "camera_reopen":{"before":preshape["camera"],"after":reopened_camera,"saved_pose_unchanged":True},
                "derived_mesh_saved":False,"runtime_saved":False,"hardware_calls":0}
        result=OUTPUT/"pattern-assembly-report.json";result.write_text(json.dumps(report,indent=2))
        print(json.dumps({"passed":True,"report":str(result),"independent_geometry":independent},indent=2))
    finally:
        client.close()


if __name__=="__main__":
    main()
