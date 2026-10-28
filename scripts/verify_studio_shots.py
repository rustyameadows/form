#!/usr/bin/env python3
"""Independent standard-library PNG/provenance pair verification; read only."""
import argparse
import hashlib
import json
import pathlib
import struct
import zlib


def verify(folder):
    folder=pathlib.Path(folder);record=json.loads((folder/'render.json').read_text());images=list(folder.glob('*.png'));assert len(images)==1
    data=images[0].read_bytes();assert data[:8]==b'\x89PNG\r\n\x1a\n';width,height=struct.unpack('>II',data[16:24]);assert [width,height]==[record['width'],record['height']]
    assert 64<=width<=8192 and 64<=height<=8192 and width*height<=16777216
    assert record['png_sha256']==hashlib.sha256(data).hexdigest();assert record['source_archived'] is False
    assert record['presentation_renderer_version']==1 and isinstance(record['os_version'],str)
    assert len(record['included_object_ids'])==len(set(record['included_object_ids']))
    assert record['shot']['lighting'] in ['classic-v1','soft-side-v1','rim-v1']
    aspect=width/height;factor=max(1,record['shot']['referenceAspect']/aspect)
    assert abs(record['effective_orthographic_scale']-record['shot']['camera']['distance']*.36*factor)<1e-9
    for resource in record['resources']:
        assert resource['id'].startswith(('asset:','font:'));assert len(resource['sha256'])==64
        assert not resource['id'].startswith(('asset:/','font:/'))
    at=8;chunks=[]
    while at<len(data):
        size=struct.unpack('>I',data[at:at+4])[0];kind=data[at+4:at+8];body=data[at+8:at+8+size];crc=struct.unpack('>I',data[at+8+size:at+12+size])[0]
        assert zlib.crc32(kind+body)&0xffffffff==crc
        chunks.append(kind.decode('ascii'));at+=12+size
    assert chunks[-1]=='IEND'
    return {'folder':folder.name,'pixels':[width,height],'sha256_verified':True,'png_chunk_crc_verified':True,'lighting':record['shot']['lighting'],'subjects':len(record['included_object_ids']),'resource_hashes':len(record['resources']),'source_archived':False,'pixel_cap_is_memory_cap':False}


def main():
    p=argparse.ArgumentParser();p.add_argument('folders',nargs='+');p.add_argument('--report');a=p.parse_args();result=[verify(x) for x in a.folders]
    text=json.dumps(result,indent=2)+'\n'
    if a.report:pathlib.Path(a.report).write_text(text)
    print(text,end='')

if __name__=='__main__':main()
