#!/usr/bin/env python3
"""QUILL: real font glyphs, editable source, shared wordmark and 100 mm dial.

Run against an isolated FORM_LIBRARY_PATH inside .local. No printer/model calls.
"""
import copy
import json
import math
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def text(x,y,w,h,value,size=12,font='HoeflerText-Regular',name=None,color='#203D34',**style):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=x,y=y,width=w,height=h,text=value,fontSize=size,
        color=color,name=name or value,typography=dict(fontName=font,kerningMode='metrics',**style))


def shape(kind,x,y,w,h,color,**kwargs):
    return dict(id=str(uuid.uuid4()).upper(),kind=kind,x=x,y=y,width=w,height=h,color=color,text="",fontSize=14,**kwargs)


def main():
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path'])
        assert library.resolve().is_relative_to((ROOT/'.local').resolve()), 'Use a disposable validation library.'
        c.discover(['form_font_features', 'form_edit_artwork'])
        options=c.call('form_font_features',{'font_name':'HoeflerText-Regular','command':'alternates','text':'Quill','location':0,'length':1,'typography':{'fontName':'HoeflerText-Regular','caseTreatment':'uppercase'}})['glyphs']
        alternate=next(o['glyph'] for o in options if o['glyph'].get('glyphName')=='Q.alt')
        repertoire=c.call('form_font_features',{'font_name':'HoeflerText-Regular','command':'glyphs','query':'Q.engraved','limit':8})
        engraved=next(o['glyph'] for o in repertoire['glyphs'] if o['glyph'].get('glyphName')=='Q.engraved')
        p=c.call('form_create_project',{'name':'QUILL · Time, by design'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'QUILL / Wordmark specimen','parameters':{'width':200,'depth':185},'position':[-150,0,-200]})
        word=text(16,54,168,40,'Quill',68,name='Editable wordmark',caseTreatment='uppercase',tracking=0.4,pairKerning={0:-1.2})
        word['textRuns']=[dict(location=0,length=1,fontSize=68,color='#A35F3C',typography=copy.deepcopy(word['typography']))]
        sample=text(16,117,42,25,'Q',40,name='Original Q')
        alternate_sample=text(75,117,42,25,'Q',40,name='Alternate Q')
        engraved_sample=text(134,117,42,25,'Q',40,name='Engraved Q')
        elements=[text(16,12,168,6,'Q / TYPOGRAPHIC ATELIER',8,font='Menlo-Regular',tracking=1.2),
            text(16,29,168,12,'Time, by design.',22),
            shape('rectangle',16,47,168,0.25,'#A35F3C'),word,
            text(16,97,168,7,'ONE WORD. ANOTHER FORM.',7,font='Menlo-Regular',tracking=1.1),
            sample,alternate_sample,engraved_sample,
            text(16,145,45,5,'01 / FONT SHAPING',6.5,font='Menlo-Regular'),
            text(75,145,45,5,'02 / Q.ALT',6.5,font='Menlo-Regular'),
            text(134,145,50,5,'03 / ENGRAVED',6.5,font='Menlo-Regular'),
            text(16,158,130,14,'A chosen curve, a familiar letter. Original words stay editable as their forms evolve.',10,leading=14),
            text(16,176,130,5,'FORM / TYPE STUDIES',6.5,font='Menlo-Regular'),
            text(174,176,10,5,'03',6.5,font='Menlo-Regular',alignment='right')]
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F4F0E5','bleed':0,'elements':elements}})
        dial=c.call('form_add_object',{'recipe_id':'artboard','name':'QUILL / 100 mm dial','parameters':{'width':100,'depth':100},'position':[150,0,-170]})
        marks=[shape('ellipse',1,1,98,98,'#F4F0E5',stroke={'width':0.25,'color':'#203D34'})]
        for i in range(60):
            a=math.radians(i*6);hour=i%5==0;w,h=(0.45,3.8) if hour else (0.18,1.5)
            r=45.5
            marks.append(shape('rectangle',50+math.sin(a)*r-w/2,50-math.cos(a)*r-h/2,w,h,'#A35F3C' if hour else '#6B7C70',rotation=i*6))
        for i in range(1,13):
            a=math.radians(i*30)
            marks.append(text(50+math.sin(a)*36-4.5,50-math.cos(a)*36-4.5,9,9,str(i),15,alignment='center',verticalAlignment='middle',features={21:1}))
        dialword=text(38,30,24,9,'Quill',14,name='Dial wordmark',caseTreatment='uppercase',alignment='center',tracking=0.3)
        marks += [dialword,text(30,63,40,6,'TIME / WELL SPENT',5.5,font='Menlo-Regular',alignment='center',tracking=0.3),
            text(30,70,40,6,'100 mm · No. 01',7,alignment='center'),shape('ellipse',48,48,4,4,'#FFFFFF')]
        c.call('form_set_artwork',{'object_id':dial['id'],'artwork':{'background':'#F4F0E5','bleed':0,'elements':marks}})
        box=c.call('form_add_object',{'recipe_id':'box','name':'QUILL / Oak edition','parameters':{'width':200,'depth':185,'height':12,'corner':2},'material_id':'oak','position':[-150,0,100]})
        clock=c.call('form_add_object',{'recipe_id':'clock','name':'QUILL / 100 mm clock','parameters':{'diameter':100,'thickness':6,'bore':4,'hour':10,'minute':8},'material_id':'oak','position':[150,0,100]})
        c.call('form_link_artwork',{'object_id':box['id'],'source_object_id':sheet['id']})
        c.call('form_link_artwork',{'object_id':clock['id'],'source_object_id':dial['id'],'fit':'actual'})
        if clock.get('artworkSourceID'):
            c.call('form_delete_objects',{'object_ids':[clock['artworkSourceID']]})
        package=library/(p['id']+'.form')
        def files():return {o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        old=files()
        for owner,e,glyph in [(box,word,alternate),(sheet,alternate_sample,alternate),(sheet,engraved_sample,engraved),(clock,dialword,alternate)]:
            c.call('form_edit_artwork',{'command':'glyph','object_id':owner['id'],'element_ids':[e['id']],'location':0,'length':1,'glyph':glyph})
        assert {k for k in old if files()[k]!=old[k]}=={sheet['id'],dial['id']}
        baseline=c.call('form_get_project');assert baseline['schemaVersion']==15
        original=next(o for o in baseline['objects'] if o['id']==sheet['id'])['artwork']
        assert next(e for e in original['elements'] if e['id']==word['id'])['text']=='Quill'
        assert all(not o.get('artwork') for o in baseline['objects'] if o['id'] in [box['id'],clock['id']])
        bad=dict(alternate,glyphName='FORM.missing.glyph')
        c.call('form_batch',{'operations':[
            {'name':'form_edit_artwork','arguments':{'command':'glyph','object_id':sheet['id'],'element_ids':[word['id']],'glyph':None}},
            {'name':'form_edit_artwork','arguments':{'command':'glyph','object_id':sheet['id'],'element_ids':[word['id']],'location':0,'length':1,'glyph':bad}}]},expect_error=True)
        assert c.call('form_get_project')==baseline
        c.call('form_edit_artwork',{'command':'glyph','object_id':box['id'],'element_ids':[word['id']],'location':0,'length':1,'glyph':None})
        c.call('form_undo');assert c.call('form_get_project')==baseline
        exports={}
        for owner,label in [(sheet,'quill-sheet'),(clock,'quill-dial')]:
            for fmt in ['svg','pdf','png','jpeg']:
                exports[label+'-'+fmt]=c.call('form_export_artwork',{'object_id':owner['id'],'format':fmt,'dpi':150,'path':str(OUTPUT/(label+'.'+fmt))})
        live=c.call('form_export_artwork',{'object_id':sheet['id'],'format':'svg','outline_text':False,'path':str(OUTPUT/'quill-live.svg')})
        assert live['composed_text_outlined']==3
        conversion=c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[word['id']]})
        converted=c.call('form_get_artwork',{'object_id':sheet['id']})
        recovery=next(e for e in converted['elements'] if e['id']==word['id']);assert recovery['hidden'] and recovery['text']=='Quill' and recovery['glyphOverrides']
        c.call('form_export_artwork',{'object_id':sheet['id'],'format':'png','dpi':150,'path':str(OUTPUT/'quill-outlines.png')})
        outline=next(e for e in conversion['elements'] if e['kind']=='path')
        node=outline['path']['contours'][0]['nodes'][0]
        c.call('form_edit_path',{'object_id':sheet['id'],'element_id':outline['id'],'node_ids':[node['id']],'operation':'transform','matrix':{'a':1,'d':1,'tx':0.2}})
        changed=c.call('form_get_artwork',{'object_id':sheet['id']})
        assert next(e for e in changed['elements'] if e['id']==outline['id'])['path']!=outline['path']
        assert next(e for e in changed['elements'] if e['id']==word['id'])['text']=='Quill'
        c.call('form_undo');c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_open_project' ,{'project_id':p['id']});assert c.call('form_get_project')['objects']==baseline['objects']
        for resource in package.rglob('*.json'):
            for key in ['studio.form.glyphOverride','studio.form.glyphRender','NSGlyphInfo','studio.form.caseSource']:assert key not in resource.read_text()
        perf=c.call('form_add_object',{'recipe_id':'artboard','name':'Glyph performance','parameters':{'width':600,'depth':1000}})
        repeated=[]
        for i in range(200):
            e=text(10+i%8*73,10+i//8*36,70,30,'Quill',22,caseTreatment='uppercase')
            e['glyphOverrides']=[dict(id=str(uuid.uuid4()).upper(),location=0,sourceText='Q',glyph=alternate)];repeated.append(e)
        c.call('form_set_artwork',{'object_id':perf['id'],'artwork':{'background':'#F4F0E5','bleed':0,'elements':repeated}})
        style=c.call('form_text_style',{'command':'create','name':'Glyph performance','typography':repeated[0]['typography'],'font_size':22,'object_id':perf['id'],'element_ids':[e['id'] for e in repeated]})['style']['id']
        c.call('form_set_view',{'view':'artwork','object_id':perf['id']});times=[]
        for i in range(20):
            start=time.perf_counter();c.call('form_text_style',{'command':'update','style_id':style,'typography':{'tracking':0.3 if i%2==0 else 1.2}});times.append((time.perf_counter()-start)*1000)
        sampled=c.call('form_status')
        c.call('form_delete_objects',{'object_ids':[perf['id']]});c.call('form_text_style',{'command':'delete','style_id':style})
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id'],'element_ids':[word['id']]})
        report=dict(project_id=p['id'],sheet_id=sheet['id'],dial_id=dial['id'],box_id=box['id'],clock_id=clock['id'],word_id=word['id'],alternate_sample_id=alternate_sample['id'],engraved_sample_id=engraved_sample['id'],alternate=alternate,
            saved_edit_median_ms=round(statistics.median(times),2),saved_edit_p95_ms=round(sorted(times)[18],2),performance_status=sampled,exports=exports)
        (OUTPUT/'glyph-report.json').write_text(json.dumps(report,indent=2));(OUTPUT/'glyph-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2))
        print(json.dumps({k:v for k,v in report.items() if k not in ['performance_status','exports']},indent=2))
    finally:c.close()


if __name__=='__main__':main()
