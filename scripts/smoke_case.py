#!/usr/bin/env python3
"""VERSO: non-destructive Unicode case, rich text, and linked physical faces."""
import json
import pathlib
import statistics
import time
import uuid
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT


def text(x,y,w,h,value,size=12,font='Georgia',name=None,**typography):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=x,y=y,width=w,height=h,text=value,fontSize=size,color='#243846',name=name or value,
        typography=dict(fontName=font,kerningMode='metrics',**typography))


def main():
    c=Client()
    try:
        status=c.call('form_status');assert pathlib.Path(status['library_path']).resolve().is_relative_to(pathlib.Path('.local').resolve())
        p=c.call('form_create_project',{'name':'VERSO · The shape of a word'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'VERSO / Case specimen','parameters':{'width':200,'depth':180}})
        word=text(16,62,168,25,'Straße',46,font='Baskerville',name='Source word',caseTreatment='uppercase')
        mixed=text(16,110,168,13,'Straße / İSTANBUL',23,name='Mixed source')
        mixed['textRuns']=[dict(location=0,length=6,typography=dict(mixed['typography'],caseTreatment='uppercase'),fontSize=23,color='#243846'),
            dict(location=9,length=8,typography=dict(mixed['typography'],caseTreatment='lowercase'),fontSize=23,color='#A65032')]
        labels=[text(16,12,168,6,'VERSO / STUDIES IN LETTERS',8,font='Menlo-Regular'),
            text(15,28,170,26,'The shape of a word.',30,font='Baskerville'),
            text(16,56,168,5,'01 / UPPERCASE, ORIGINAL WORD RETAINED',7,font='Menlo-Regular'),
            text(16,100,168,5,'02 / INDEPENDENT CASE, ONE TEXT OBJECT',7,font='Menlo-Regular'),
            text(16,137,110,20,'Case changes the way a word appears. The original letters stay with it, ready to return.',11,leading=15),
            text(148,137,36,16,'ΟΣ / İ / 𐐀',14,caseTreatment='lowercase'),
            text(16,170,168,5,'FORM / TYPOGRAPHIC STUDIES                                    VOL. 02',7,font='Menlo-Regular')]
        elements=[*labels,word,mixed]
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F1F0E8','bleed':0,'elements':elements}})
        boxes=[]
        for x,material in [(-245,'oak'),(245,'graphite')]:
            box=c.call('form_add_object',{'recipe_id':'box','name':'VERSO / '+material.title(),'parameters':{'width':200,'depth':180,'height':12,'corner':2},'material_id':material,'position':[x,0,0]})
            c.call('form_link_artwork',{'object_id':box['id'],'source_object_id':sheet['id']});boxes.append(box)
        baseline=c.call('form_get_project')
        package=pathlib.Path(status['library_path'])/(p['id']+'.form')
        def files():return {o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        old_files=files()
        def export(name,fmt='png',**args):
            path=OUTPUT/(name+'.'+fmt)
            result=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'path':str(path),'dpi':150,**args})
            return path.read_bytes(),result
        original,_=export('verso-sheet')
        explicit=dict(word,text='STRASSE',typography=dict(word['typography'],caseTreatment='original'))
        c.call('form_edit_artwork',{'command':'replace','object_id':boxes[0]['id'],'elements':[explicit]})
        visible,_=export('verso-explicit');assert original==visible
        assert {id for id in old_files if files()[id]!=old_files[id]}=={sheet['id']}
        c.call('form_undo');assert c.call('form_get_project')==baseline
        for fmt in ['svg','pdf','jpeg']:export('verso-sheet',fmt)
        live,_=export('verso-live','svg',outline_text=False)
        live_text=''.join(ET.fromstring(live).itertext());assert 'STRASSE' in live_text and 'i̇stanbul' in live_text
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[word['id']]})
        art=c.call('form_get_artwork',{'object_id':sheet['id']});source=next(e for e in art['elements'] if e['id']==word['id'])
        assert source['hidden'] and source['text']=='Straße'
        c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_open_project',{'project_id':p['id']})
        restored=c.call('form_get_project');assert restored['objects']==baseline['objects']
        assert 'studio.form.caseSource' not in json.dumps(restored)
        for resource in package.rglob('*.json'):assert 'studio.form.caseSource' not in resource.read_text()
        perf=c.call('form_add_object',{'recipe_id':'artboard','name':'Case performance','parameters':{'width':600,'depth':1000}})
        specimens=[text(10+(i%8)*73,10+(i//8)*38,70,36,'Straße / İSTANBUL / ΟΣ',11,caseTreatment='uppercase') for i in range(200)]
        c.call('form_set_artwork',{'object_id':perf['id'],'artwork':{'background':'#F1F0E8','bleed':0,'elements':specimens}})
        style=c.call('form_text_style',{'command':'create','name':'Case performance','typography':specimens[0]['typography'],'font_size':11,'object_id':perf['id'],'element_ids':[e['id'] for e in specimens]})['style']['id']
        c.call('form_set_view',{'view':'artwork','object_id':perf['id']})
        times=[]
        for i in range(20):
            start=time.perf_counter();c.call('form_text_style',{'command':'update','style_id':style,'typography':{'caseTreatment':'lowercase' if i%2==0 else 'uppercase'}});times.append((time.perf_counter()-start)*1000)
        sampled=c.call('form_status');c.call('form_delete_objects',{'object_ids':[perf['id']]});c.call('form_text_style',{'command':'delete','style_id':style})
        c.call('form_set_view',{'view':'artwork','object_id':boxes[0]['id'],'element_ids':[word['id']]})
        report=dict(project_id=p['id'],sheet_id=sheet['id'],box_ids=[b['id'] for b in boxes],word_id=word['id'],mixed_id=mixed['id'],
            saved_edit_median_ms=round(statistics.median(times),2),saved_edit_p95_ms=round(sorted(times)[18],2),performance_status=sampled,
            checks='Rich independent case; source-only resources; ephemeral records excluded; source Unicode retained; pixel-identical explicit uppercase; recoverable glyph paths; physical exports; reopen; 200-text saved style updates')
        (OUTPUT/'case-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (OUTPUT/'case-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
