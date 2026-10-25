#!/usr/bin/env python3
"""AVENUE: actual font metrics, independent spacing, linked physical faces.

Use an isolated FORM_LIBRARY_PATH. No printer or external model calls.
"""
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def text(x, y, w, h, value, size=12, mode='metrics', font='Baskerville', color='#202B28', name=None):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=x,y=y,width=w,height=h,
        text=value,fontSize=size,color=color,name=name or value,
        typography=dict(fontName=font,kerningMode=mode))


def main():
    c=Client()
    try:
        status=c.call('form_status');assert pathlib.Path(status['library_path']).resolve().is_relative_to(pathlib.Path('.local').resolve())
        assert len(c.rpc('tools/list')['tools'])==50
        p=c.call('form_create_project',{'name':'AVENUE · The space between'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'AVENUE / Type & space','parameters':{'width':200,'depth':160}})
        word=text(14,34,172,48,'AVENUE',112,name='AVENUE wordmark')
        metrics=text(16,108,78,19,'AVATAR',32,name='Font metrics specimen')
        none=text(110,108,78,19,'AVATAR',32,mode='none',name='Unkerned specimen')
        captions=[text(16,13,168,8,'A / A STUDY IN RELATIONSHIPS',9,font='Menlo-Regular'),
            text(16,89,168,7,'OBJECTS, TYPE & THE SPACE BETWEEN.',10,font='Menlo-Regular'),
            text(16,101,78,6,'01 / FONT METRICS',8,font='Menlo-Regular'),
            text(110,101,78,6,'02 / KERNING NONE',8,font='Menlo-Regular'),
            text(16,142,168,7,'FORM  /  TYPE STUDY 03                                      200 × 160 MM',8,font='Menlo-Regular')]
        rule=dict(id=str(uuid.uuid4()).upper(),kind='line',x=16,y=133,width=168,height=.1,
            text='',fontSize=14,color='#202B28',stroke={'width':.25,'color':'#202B28'})
        chip=dict(id=str(uuid.uuid4()).upper(),kind='rectangle',x=167,y=15,width=17,height=3,
            text='',fontSize=14,color='#D4E46A')
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F0EDE4','bleed':0,'elements':[*captions,chip,word,metrics,none,rule]}})
        style=c.call('form_text_style',{'command':'create','name':'Wordmark','font_size':112,
            'typography':word['typography'],'object_id':sheet['id'],'element_ids':[word['id']]})['style']['id']
        boxes=[]
        for x,material in [(-260,'oak'),(260,'graphite')]:
            box=c.call('form_add_object',{'recipe_id':'box','name':'AVENUE / '+material.title(),
                'parameters':{'width':200,'depth':160,'height':12,'corner':2},'material_id':material,'position':[x,0,0]})
            c.call('form_link_artwork',{'object_id':box['id'],'source_object_id':sheet['id']});boxes.append(box)
        package=pathlib.Path(status['library_path'])/(p['id']+'.form')
        def files():return {o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def element(id):return next(e for e in art()['elements'] if e['id']==id)
        def export(name,fmt='png',**args):
            path=OUTPUT/(name+'.'+fmt)
            c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'dpi':150,'path':str(path),**args})
            return path.read_bytes()
        baseline=c.call('form_get_project');old=files()
        original=export('avenue-sheet')
        c.call('form_text_style',{'command':'update','style_id':style,'typography':{'kerningMode':'none'}})
        assert {id for id in old if files()[id]!=old[id]}=={sheet['id']}
        assert export('avenue-none')!=original
        c.call('form_undo');assert c.call('form_get_project')==baseline
        # Local spacing mode overrides survive source changes and reset explicitly.
        edited=element(word['id']);edited['typography']['kerningMode']='none'
        c.call('form_edit_artwork',{'object_id':boxes[0]['id'],'command':'replace','elements':[edited]})
        assert element(word['id'])['textStyle']['overrides']==['kerningMode']
        c.call('form_text_style',{'command':'update','style_id':style,'typography':{'tracking':.25}})
        assert element(word['id'])['typography']['kerningMode']=='none'
        c.call('form_text_style',{'command':'reset','object_id':sheet['id'],'element_ids':[word['id']]})
        assert element(word['id'])['typography']['kerningMode']=='metrics'
        for _ in range(3):c.call('form_undo')
        assert c.call('form_get_project')==baseline
        c.call('form_batch',{'operations':[
            {'name':'form_text_style','arguments':{'command':'update','style_id':style,'typography':{'kerningMode':'none'}}},
            {'name':'form_text_style','arguments':{'command':'update','style_id':style,'typography':{'kerningMode':'optical'}}}]},expect_error=True)
        assert c.call('form_get_project')==baseline
        for fmt in ['svg','pdf','jpeg']:export('avenue-sheet',fmt)
        live=export('avenue-live','svg',outline_text=False).decode()
        assert 'font-kerning="normal"' in live and 'font-kerning="none"' in live
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[word['id']]})
        assert element(word['id'])['hidden'] and element(word['id'])['typography']['kerningMode']=='metrics'
        export('avenue-outlined','svg');c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_open_project',{'project_id':p['id']});assert c.call('form_get_project')['schemaVersion']==13
        perf=c.call('form_add_object',{'recipe_id':'artboard','name':'Kerning performance','parameters':{'width':500,'depth':500}})
        specimens=[text(10+(i%10)*49,10+(i//10)*24,47,20,'AVATAR '+str(i),size=18) for i in range(200)]
        c.call('form_set_artwork',{'object_id':perf['id'],'artwork':{'background':'#F0EDE4','bleed':0,'elements':specimens}})
        perfstyle=c.call('form_text_style',{'command':'create','name':'Specimen','font_size':18,
            'typography':specimens[0]['typography'],'object_id':perf['id'],'element_ids':[e['id'] for e in specimens]})['style']['id']
        c.call('form_set_view',{'view':'artwork','object_id':perf['id']})
        times=[]
        for i in range(20):
            start=time.perf_counter();c.call('form_text_style',{'command':'update','style_id':perfstyle,
                'typography':{'kerningMode':'none' if i%2==0 else 'metrics'}})
            times.append((time.perf_counter()-start)*1000)
        sampled=c.call('form_status')
        c.call('form_delete_objects',{'object_ids':[perf['id']]});c.call('form_text_style',{'command':'delete','style_id':perfstyle})
        c.call('form_set_view',{'view':'artwork','object_id':boxes[0]['id'],'element_ids':[word['id']]})
        report=dict(project_id=p['id'],sheet_id=sheet['id'],wordmark_id=word['id'],metrics_id=metrics['id'],none_id=none['id'],
            box_ids=[b['id'] for b in boxes],style_id=style,tools=50,
            saved_edit_median_ms=round(statistics.median(times),2),saved_edit_p95_ms=round(sorted(times)[18],2),performance_status=sampled,
            checks='Actual metrics and None PNGs differ; explicit live SVG; styled source-only resources; persistent local override/reset; invalid batch rollback; recoverable outlines; physical outputs; schema-13 reopen; 200-text mode edits')
        (OUTPUT/'kerning-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (OUTPUT/'kerning-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
