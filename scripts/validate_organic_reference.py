#!/usr/bin/env python3
"""Evaluate ordinary authored model data and render its three reference views.

This is a concrete visual acceptance fixture, not an app feature registration.
Every run uses a new private library/socket. The reference image is immutable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"scripts"))
from smoke_mcp import Client


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app",type=Path,default=ROOT/"build/LAB.app")
    parser.add_argument("--model",type=Path,default=ROOT/"examples/agent-modeling/organic-bud-vase/model.json")
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--keep-app",action="store_true")
    parser.add_argument("--quality",choices=["preview","inspection","fabrication"],default="inspection")
    args=parser.parse_args()
    output=args.output.resolve()
    assert output.is_relative_to((ROOT/".local").resolve())
    output.mkdir(parents=True,exist_ok=False)
    library=output/"Library";library.mkdir()
    socket="/tmp/lab-organic-"+uuid.uuid4().hex[:16]+".sock"
    app=args.app.resolve();helper=app/"Contents/MacOS/lab-mcp"
    os.environ.update(LAB_LIBRARY_PATH=str(library),FORM_LIBRARY_PATH=str(library),
        LAB_SOCKET_PATH=socket,FORM_SOCKET_PATH=socket,LAB_MCP_PATH=str(helper))
    reference=ROOT/"examples/agent-modeling/organic-bud-vase/reference-manifest.json"
    manifest=json.loads(reference.read_text())
    assert hashlib.sha256((reference.parent/manifest["image"]).read_bytes()).hexdigest()==manifest["sha256"]
    report=dict(app=str(app),app_sha256=hashlib.sha256((app/"Contents/MacOS/LAB").read_bytes()).hexdigest(),
        helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(),
        model=str(args.model.resolve()),model_sha256=hashlib.sha256(args.model.read_bytes()).hexdigest(),
        reference_manifest=str(reference),reference_sha256=manifest["sha256"],
        library=str(library),socket=socket,quality=args.quality,iterations=[])
    process=None;client=None;successful=False
    def save(): (output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    started=time.monotonic()
    try:
        with (output/"app.log").open("w") as log:
            process=subprocess.Popen([str(app/"Contents/MacOS/LAB")],env=os.environ,stdout=log,stderr=log,
                                     start_new_session=args.keep_app)
            report["app_pid"]=process.pid
            save()
            deadline=time.monotonic()+30
            while not Path(socket).exists():
                assert process.poll() is None,"Native app exited before its isolated bridge."
                assert time.monotonic()<deadline,"Native bridge startup timeout."
                time.sleep(.1)
            client=Client()
            assert Path(client.call("form_status")["library_path"]).resolve()==library
            project=client.call("form_create_project",{"name":"Organic / frozen-reference bud vase","template":"blank"})
            report["project_id"]=project["id"];save()
            definition=json.loads(args.model.read_text())
            def cad(command,**values):return client.call("form_cad",dict(command=command,**values))
            def wait_job(job):
                deadline=time.monotonic()+600
                last=None
                while job["state"] in ("preparing","publishing"):
                    assert process.poll() is None,"Native app exited during evaluation."
                    assert time.monotonic()<deadline,"Model evaluation exceeded600 seconds."
                    time.sleep(.1)
                    job=cad("status",job_id=job["job_id"])
                    if job["state"]!=last:
                        print(json.dumps(dict(state=job["state"],elapsed_seconds=round(time.monotonic()-started,2))),flush=True)
                        last=job["state"]
                report["job"]=job;save()
                assert job["state"] in ("ready","committed"),job.get("diagnostic",job)
                return job
            job=wait_job(cad("create",definition=definition,quality=args.quality))
            report["evaluated_seconds"]=round(time.monotonic()-started,3)
            job=wait_job(cad("commit",job_id=job["job_id"]))
            object_id=job["result"]["object_id"];report["object_id"]=object_id
            client.call("form_update_object",{"object_id":object_id,"color":"#E5DFD2"})
            job=wait_job(cad("evaluate",object_id=object_id,quality=args.quality))
            report["job_id"]=job["job_id"]
            request=cad("evidence",job_id=job["job_id"],requests=[
                dict(kind="render",view=view,width=1000,height=1000,transparent=False,path=str(output/(view+".png")))
                for view in ("front","top","perspective")]+[dict(kind="summary")])
            deadline=time.monotonic()+180
            while request["state"]=="pending":
                assert time.monotonic()<deadline,"Reference evidence exceeded180 seconds."
                time.sleep(.1);request=cad("evidence_status",request_id=request["request_id"])
            report["evidence"]=request
            assert request["state"]=="complete",request
            assert all(item.get("success",True) is not False and item.get("error") is None for item in request["results"]),request
            report["images"]={view:str(output/(view+".png")) for view in ("front","top","perspective")}
            # Saved Studio shots reproduce the selected side-lighted comparison
            # through the same public capture/export path used by the app.
            before=client.call("form_get_project")
            original=next(item for item in before["objects"] if item["id"]==object_id)
            component=original["cadRepresentation"]["components"][0]
            position=original["position"]
            minimum,maximum=component["minimum"],component["maximum"]
            target={axis:(position[axis]+(minimum[axis]+maximum[axis])/2)/100
                    for axis in ("x","y","z")}
            shots=[]
            for view,azimuth,elevation in (("front",0,.08),("top",0,1.5707963267948966),
                                          ("three-quarter",.55,.45)):
                camera=dict(azimuth=azimuth,elevation=elevation,distance=3.2,
                            target=target,projection="orthographic",viewportAspect=1)
                shot=client.call("form_set_view",dict(view="studio",studio_command="capture",
                    name="Organic reference / "+view,camera=camera,reference_aspect=1,
                    lighting="soft-side-v1",surface="Daylight",
                    visibility=dict(mode="objects",objectIDs=[object_id]),width=1000,height=1000))
                rendered=client.call("form_export",dict(format="png",shot_id=shot["id"],
                    path=str(output/(view+"-studio.render"))))
                path=Path(rendered["path"]);data=path.read_bytes()
                assert data[:8]==b"\x89PNG\r\n\x1a\n"
                dimensions=struct.unpack(">II",data[16:24])
                assert dimensions==(1000,1000),dimensions
                shots.append(dict(view=view,shot=shot,export=rendered,
                                  sha256=hashlib.sha256(data).hexdigest(),
                                  width=dimensions[0],height=dimensions[1]))
                report["studio_comparison"]=shots;save()
            after=client.call("form_get_project")
            final=next(item for item in after["objects"] if item["id"]==object_id)
            assert final["cadModel"]==original["cadModel"]
            assert final["cadRepresentation"]==original["cadRepresentation"]
            report["presentation_preserved_model_and_representation"]=True
            report["duration_seconds"]=round(time.monotonic()-started,3)
            report["visual_acceptance"]="Pending human/image comparison; a valid solid alone does not pass."
            report["geometry_ready"]=True
            save();successful=True
            print(json.dumps(dict(output=str(output),object_id=object_id,job_id=job["job_id"],images=report["images"],app_pid=process.pid,keep_app=args.keep_app),indent=2))
    except Exception as error:
        report["error"]=str(error);save();raise
    finally:
        if client:client.close()
        if process and (not args.keep_app or not successful) and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
        if not args.keep_app or not successful:Path(socket).unlink(missing_ok=True)


if __name__=="__main__":main()
