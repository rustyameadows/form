#!/usr/bin/env python3
"""Byte-copy a saved LAB package without rewriting project or artwork data.

Copy the exact current Manifest.json, only its referenced immutable Objects,
and the complete Assets tree. No app launch, build, API or project save occurs.
The certificate verifies storage bytes, not native model/render correctness.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import uuid


def require(value,message):
    if not value:raise ValueError(message)


def sha(path):
    result=hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()


def regular(path):
    require(stat.S_ISREG(path.lstat().st_mode),'Expected an ordinary file, not a link/device: '+str(path))


def inventory(source,expected_manifest_sha256=None):
    source=Path(source).absolute()
    require(source.suffix=='.form' and source.is_dir() and not source.is_symlink(),'Source must be an ordinary saved .form package directory.')
    source=source.resolve(strict=True);manifest=source/'Manifest.json';regular(manifest)
    require(manifest.stat().st_size<=64*1024*1024,'Manifest exceeds the bounded metadata inspection size.')
    checksum=sha(manifest)
    if expected_manifest_sha256:require(checksum==expected_manifest_sha256,'Source Manifest changed; no copy was attempted.')
    data=json.loads(manifest.read_bytes());project=data['project'];uuid.UUID(project['id'])
    require(isinstance(data['objects'],list),'Manifest objects must be a reference list.')
    files=['Manifest.json'];seen=set();names=set()
    if data['objects']:
        require((source/'Objects').is_dir() and not (source/'Objects').is_symlink(),'Objects must be an ordinary package directory.')
    for reference in data['objects']:
        identity=str(uuid.UUID(reference['id']));name=reference['file']
        require(isinstance(name,str) and name not in ('.','..') and '/' not in name and '\\' not in name and name.endswith('.json'),'Unsafe immutable object reference.')
        require(identity not in seen and name not in names,'Duplicate immutable object identity/reference.')
        seen.add(identity);names.add(name);path=source/'Objects'/name;regular(path)
        require(path.stat().st_size<=512*1024*1024,'Object exceeds the bounded identity inspection size.')
        require(str(uuid.UUID(json.loads(path.read_bytes())['id']))==identity,'Immutable object identity differs from its Manifest reference.')
        files.append('Objects/'+name)
    directories={'Objects','Assets'}
    assets=source/'Assets'
    if assets.exists():
        require(assets.is_dir() and not assets.is_symlink(),'Assets must be an ordinary directory.')
        for path in sorted(assets.rglob('*')):
            require(not path.is_symlink(),'Asset links are not portable package bytes: '+str(path))
            relative=path.relative_to(source).as_posix()
            if path.is_dir():directories.add(relative)
            else:regular(path);files.append(relative)
    require(len(files)<=100000,'Package file count exceeds the inspection budget.')
    records=[dict(path=name,bytes=(source/name).stat().st_size,sha256=sha(source/name)) for name in sorted(files)]
    require(sha(manifest)==checksum,'Source Manifest changed while reading its references; retry after the project is stable.')
    return dict(version=1,source=str(source),project_id=project['id'],project_name=project.get('name'),schema_version=project.get('schemaVersion'),
        manifest_sha256=checksum,object_count=len(seen),asset_file_count=sum(row['path'].startswith('Assets/') for row in records),
        total_bytes=sum(row['bytes'] for row in records),directories=sorted(directories),files=records,
        scope='Exact Manifest bytes; referenced immutable object files only; complete Assets tree. No history, cache, preview or export folders.',
        native_validation_required='Open the copied package in the same verified ordinary LAB, then inspect page/scene counts, source artwork, stock and native output. Byte checks do not establish native load/render acceptance.')


def verify_files(root,record):
    root=Path(root).resolve(strict=True)
    for row in record['files']:
        name=Path(row['path'])
        require(not name.is_absolute() and '..' not in name.parts,'Unsafe certificate path.')
        path=root/name;regular(path)
        require(path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],'Copied bytes differ: '+str(name))
    require(sha(root/'Manifest.json')==record['manifest_sha256'],'Copied Manifest differs.')


def copy_package(source,destination,expected_manifest_sha256,report):
    require(len(expected_manifest_sha256)==64 and all(c in '0123456789abcdef' for c in expected_manifest_sha256),'An exact lowercase source Manifest SHA256 is required.')
    record=inventory(source,expected_manifest_sha256)
    destination=Path(destination).absolute();report=Path(report).absolute()
    require(destination.suffix=='.form' and not destination.exists(),'Choose a new .form destination; existing packages are never replaced.')
    destination=destination.parent.resolve(strict=True)/destination.name
    source=Path(record['source'])
    require(source!=destination and source not in destination.parents,'Never copy into the source package.')
    require(not report.exists() and report.parent.is_dir(),'Choose a new certificate file in an existing directory.')
    require(destination not in report.parents and source not in report.parents,'Keep the certificate outside source and destination packages.')
    # Exclusive creation prevents replacement. Publish the untouched Manifest
    # last, matching the repository's immutable-objects-first storage contract.
    destination.mkdir(exist_ok=False)
    try:
        for name in record['directories']:(destination/name).mkdir(parents=True,exist_ok=True)
        ordered=sorted(record['files'],key=lambda row:row['path']=='Manifest.json')
        for row in ordered:shutil.copyfile(source/row['path'],destination/row['path'])
        verify_files(destination,record);verify_files(source,record)
        record.update(destination=str(destination),copy_verified=True,source_bytes_unchanged=True)
        with report.open('x') as output:json.dump(record,output,indent=2);output.write('\n')
    except Exception:
        shutil.rmtree(destination)
        raise
    return record


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path);parser.add_argument('--destination',type=Path)
    parser.add_argument('--expected-manifest-sha256');parser.add_argument('--report',type=Path)
    parser.add_argument('--plan-only',action='store_true',help='Read/hash only; do not create any package or certificate.')
    parser.add_argument('--verify-report',type=Path,help='Recheck the exact copied file bytes against a prior certificate; no app call.')
    args=parser.parse_args()
    if args.verify_report:
        require(not any((args.source,args.destination,args.report,args.expected_manifest_sha256,args.plan_only)),'Certificate verification is a separate read-only action.')
        record=json.loads(args.verify_report.read_text());verify_files(record['destination'],record)
        print(json.dumps(dict(copy_verified=True,destination=record['destination'],manifest_sha256=record['manifest_sha256']),indent=2));return
    require(args.source is not None,'--source is required.')
    if args.plan_only:record=inventory(args.source,args.expected_manifest_sha256)
    else:
        require(args.destination is not None and args.report is not None and args.expected_manifest_sha256,'Copy requires destination, expected Manifest SHA256 and certificate report.')
        record=copy_package(args.source,args.destination,args.expected_manifest_sha256,args.report)
    print(json.dumps(record,indent=2))


if __name__=='__main__':main()
