#!/usr/bin/env python3
"""Revision-linked Studio stock/jobs/packets through the packaged native MCP.
Uses an isolated .local library and the pinned Pyembroidery reader. No hardware calls.
"""
import copy
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import time
import uuid
import zipfile
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT
from smoke_embroidery import element
from verify_embroidery_dst import verify


def digest(data): return hashlib.sha256(data).hexdigest()


def check_packet(folder):
    manifest=json.loads((folder/"Manifest.json").read_text())
    assert manifest["machine_contacted"] is False and manifest["inventory_deducted"] is False
    assert manifest["automatically_verified_sew_out"] is False
    for name, metadata in manifest["files"].items():
        assert pathlib.PurePath(name).name == name
        data=(folder/name).read_bytes()
        assert digest(data) == metadata["sha256"] and len(data) == metadata["bytes"]
    canonical=dict(manifest);expected=canonical.pop("packet_digest")
    assert digest(json.dumps(canonical,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()) == expected
    revision=json.loads((folder/"Revision.json").read_text())
    program=json.loads((folder/"Program.json").read_text())
    assert digest((folder/"Revision.json").read_bytes()) == manifest["revision_digest"]
    assert digest((folder/"Program.json").read_bytes()) == manifest["program_digest"]
    assert revision["sourceDigest"] == program["sourceDigest"] == manifest["source_digest"]
    ordinary=(folder/"Artwork.svg").read_text()
    assert ordinary == revision["sourceArtworkSVG"]
    assert manifest["source_artwork_origin"] == "captured_in_revision"
    svg=ET.fromstring(ordinary)
    assert float(svg.attrib["width"].removesuffix("mm")) == revision["object"]["parameters"]["width"]
    assert float(svg.attrib["height"].removesuffix("mm")) == revision["object"]["parameters"]["depth"]
    for element in revision["object"]["artwork"]["elements"]:
        assert "layer-"+element["id"] in ordinary and element["color"] in ordinary
    assert (folder/"Artwork.svg").read_bytes() != (folder/"Needle.svg").read_bytes()
    independent=verify(folder/"Needle.dst",folder/"Program.json",folder/"Needle.threads.json")
    return manifest,revision,independent


def main():
    c=Client()
    try:
        library=pathlib.Path(c.call("form_status")["library_path"])
        assert library.resolve().is_relative_to((ROOT/".local").resolve()), "Use an isolated .local validation library."
        tools=c.rpc("tools/list")["tools"];names=[t["name"] for t in tools]
        assert len(names)>=55 and len(names)==len(set(names))
        assert {"form_textile_stock","form_production_job"}.issubset(names)
        p=c.call("form_create_project",{"name":"ORBIT / Revision-linked production"})
        source=c.call("form_add_object",{"recipe_id":"artboard","name":"Production source","parameters":{"width":80,"depth":60},"position":[150,0,0]})
        satin=element("line",8,12,40,0.1,"#C75332","Orange satin",productionRole="stitch")
        fill=element("rectangle",45,25,25,25,"#285B8A","Blue field",productionRole="stitch")
        c.call("form_set_artwork",{"object_id":source["id"],"artwork":{"background":"#FFFFFF","bleed":0,"elements":[satin,fill]}})
        patch=c.call("form_add_object",{"recipe_id":"textilePatch","name":"Mission patch / production","parameters":{"width":80,"depth":60,"corner":3},"material_id":"patch-twill"})
        c.call("form_link_artwork",{"object_id":patch["id"],"source_object_id":source["id"]})
        design=dict(hoopWidth=100,hoopHeight=100,margin=5,trimJumpThreshold=4,maximumStitches=100000,
            threads=[dict(name="Orange",color="#C75332"),dict(name="Blue",color="#285B8A")],
            regions=[dict(id=str(uuid.uuid4()).upper(),elementIDs=[satin["id"]],method="satin",threadIndex=0,stitchLength=4,spacing=0.7,satinWidth=3,underlay=dict(method="centerWalk",stitchLength=2.5)),
                     dict(id=str(uuid.uuid4()).upper(),elementIDs=[fill["id"]],method="fill",threadIndex=1,stitchLength=2.5,spacing=0.8)],
            process=dict(threadDiameter=0.3,tieIn=True,tieOff=True,tieLength=0.7,tieRepeats=2))
        c.call("form_update_object",{"object_id":patch["id"],"embroidery":design})
        c.call("form_set_view",{"view":"table","object_id":patch["id"]});time.sleep(0.2)
        original=c.call("form_get_project")
        stock=c.call("form_textile_stock",{"command":"save_thread","thread":{"name":"Recorded orange stock","color":"#C75332","brand":"Declared studio thread","sku":"OR-29","supplier":"Recorded supplier","availableMeters":10,"spoolMeters":1000,"spoolPrice":12,"currency":"USD"}})
        assert c.call("form_get_project") == original
        c.call("form_textile_stock",{"command":"assign_thread","object_id":patch["id"],"thread_index":0,"stock_id":stock["id"]})
        assigned=c.call("form_get_project");assert assigned["schemaVersion"] == 29
        c.call("form_undo");assert c.call("form_get_project") == original
        c.call("form_redo");assert c.call("form_get_project") == assigned
        c.call("form_update_object",{"object_id":patch["id"],"locked":True});locked=c.call("form_get_project")
        c.call("form_textile_stock",{"command":"assign_thread","object_id":patch["id"],"thread_index":0,"stock_id":stock["id"]},expect_error=True)
        assert c.call("form_get_project") == locked
        c.call("form_undo");assert c.call("form_get_project") == assigned
        equipment=c.call("form_textile_stock",{"command":"save_equipment","equipment":{"name":"Declared 100 mm embroidery profile","hoops":[{"name":"100 mm","width":100,"height":100}],"formats":["dst"],"needleCount":1}})
        assert c.call("form_get_project") == assigned
        assumptions=dict(upperThreadFactor=1.3,allowanceMetersPerThreadPerItem=0.02,baseUnitCost=2,baseCurrency="USD",laborMinutesPerItem=1,hourlyLaborRate=30,laborCurrency="USD",
            extraBOM=[dict(name="Stabilizer",quantityPerItem=1,unit="sheet",unitCost=0.2,currency="USD",supplier="Recorded supplier",sku="S-1")],notes="Explicit trial assumptions; bobbin and other materials remain excluded unless recorded.")
        result=c.call("form_production_job",{"command":"create","object_id":patch["id"],"name":"ORBIT / run 01","quantity":8,"outputs":["dst","svg","json"],"equipment_id":equipment["id"],"assumptions":assumptions})
        job=result["job"];revision=result["revision"];captured=c.call("form_get_project")
        assert captured["objects"] == assigned["objects"]
        assert revision["compatibility"]["status"] == "declaredCompatible"
        assert revision["equipment"]["declarationsVerified"] is False
        assert not revision["object"].get("artworkSourceID")
        assert revision["object"]["textile"]["embroidery"]["threads"][0]["stock"]["sku"] == "OR-29"
        assert result["estimate"].get("total") is None and result["estimate"]["knownSubtotals"]["USD"]>0
        c.call("form_undo");assert c.call("form_get_project") == assigned
        c.call("form_redo");assert c.call("form_get_project") == captured
        newer=copy.deepcopy(stock);newer["spoolPrice"]=99;newer["availableMeters"]=2
        c.call("form_textile_stock",{"command":"save_thread","thread":newer})
        assert c.call("form_get_project") == captured
        got=c.call("form_production_job",{"command":"get","job_id":job["id"]})
        assert got["current_source"] == "matches"
        assert got["revision"]["object"]["textile"]["embroidery"]["threads"][0]["stock"]["spoolPrice"] == 12
        record={"kind":"quality","notes":"User reports an acceptable trial on the stated sample fabric.","outcome":"pass","recordedBy":"Validation user","reportedMeters":1.5}
        c.call("form_production_job",{"command":"event","job_id":job["id"],"record":record})
        recorded=c.call("form_get_project")
        invalid=dict(record,sourceDigest="f"*64)
        c.call("form_production_job",{"command":"event","job_id":job["id"],"record":invalid},expect_error=True)
        assert c.call("form_get_project") == recorded
        c.call("form_production_job",{"command":"event","job_id":job["id"],"record":{"kind":"status","status":"approved","notes":"User approves this captured trial revision, not subsequent edits."}})
        c.call("form_edit_artwork",{"object_id":source["id"],"command":"transform","element_ids":[satin["id"]],"translate_x":1})
        stale=c.call("form_production_job",{"command":"get","job_id":job["id"]});assert stale["current_source"] == "changed"
        assert stale["job"]["programDigest"] == job["programDigest"]
        folder=OUTPUT/"production-job-packet"
        if folder.exists(): shutil.rmtree(folder)
        before_export=c.call("form_get_project")
        exported=c.call("form_production_job",{"command":"export","job_id":job["id"],"format":"folder","path":str(folder)})
        assert c.call("form_get_project") == before_export
        manifest,archived,independent=check_packet(folder)
        assert manifest["source_digest"] == job["sourceDigest"] and exported["packet_digest"] == manifest["packet_digest"]
        assert json.loads((folder/"Job.json").read_text())["records"][-1]["status"] == "approved"
        assert archived["object"]["textile"]["embroidery"]["threads"][0]["stock"]["availableMeters"] == 10
        info=subprocess.run(["pdfinfo",str(folder/"Review.pdf")],check=True,capture_output=True,text=True).stdout
        pages=int(re.search(r"Pages:\s+(\d+)",info).group(1));assert pages>=2
        physical=subprocess.run(["pdfinfo","-f",str(pages),"-l",str(pages),str(folder/"Review.pdf")],check=True,capture_output=True,text=True).stdout
        size=re.search(r"Page\s+\d+\s+size:\s+([\d.]+)\s+x\s+([\d.]+)",physical)
        assert size and all(abs(float(n)-132*72/25.4)<0.002 for n in size.groups())
        text=subprocess.run(["pdftotext",str(folder/"Review.pdf"),"-"],check=True,capture_output=True,text=True).stdout
        assert job["sourceDigest"] in text and "Unknown" in text and "User-reported result" in text
        c.call("form_textile_stock",{"command":"remove_thread","stock_id":stock["id"]})
        c.call("form_textile_stock",{"command":"remove_equipment","equipment_id":equipment["id"]})
        c.call("form_delete_objects",{"object_ids":[patch["id"],source["id"]]})
        c.call("form_open_project",{"project_id":p["id"]})
        missing=c.call("form_production_job",{"command":"get","job_id":job["id"]});assert missing["current_source"] == "missing"
        assert missing["revision"]["equipment"]["id"] == equipment["id"]
        archive=OUTPUT/"production-job-packet.zip"
        c.call("form_production_job",{"command":"export","job_id":job["id"],"format":"zip","path":str(archive)})
        unpacked=OUTPUT/"production-job-zip-check"
        if unpacked.exists(): shutil.rmtree(unpacked)
        with zipfile.ZipFile(archive) as z:
            assert z.testzip() is None
            expected={"Production/"+name for name in manifest["files"]}|{"Production/Manifest.json"}
            assert {n for n in z.namelist() if not n.endswith("/")} == expected
            assert all(".." not in pathlib.PurePosixPath(n).parts for n in z.namelist())
            z.extractall(unpacked)
        zip_manifest,_,zip_reader=check_packet(unpacked/"Production")
        assert zip_manifest["revision_digest"] == job["revisionDigest"]
        assert (unpacked/"Production"/"Needle.dst").read_bytes() == (folder/"Needle.dst").read_bytes()
        assert (unpacked/"Production"/"Artwork.svg").read_bytes() == (folder/"Artwork.svg").read_bytes()
        report=dict(project_id=p["id"],job_id=job["id"],source_digest=job["sourceDigest"],revision_digest=job["revisionDigest"],physical_hoop_page_mm=[132,132],independent_reader=independent,portable_zip_reader=zip_reader,packet=str(archive),studio_stock_deducted=False,machine_contacted=False)
        path=OUTPUT/"production-jobs-report.json";path.write_text(json.dumps(report,indent=2))
        print(json.dumps(dict(passed=True,report=str(path),**independent),indent=2))
    finally: c.close()

if __name__ == "__main__": main()
