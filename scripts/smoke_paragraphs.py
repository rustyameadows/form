#!/usr/bin/env python3
"""LEDGER: native tab columns and genuine hyphenated composition.

Use an isolated FORM_LIBRARY_PATH. No printer or external model calls.
"""
import json
import pathlib
import statistics
import time
import uuid
from smoke_mcp import Client, OUTPUT


def text(x,y,w,h,value,size=12,font='Georgia',name=None,**typography):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=x,y=y,width=w,height=h,
        text=value,fontSize=size,color='#243846',name=name or value,
        typography=dict(fontName=font,kerningMode='metrics',**typography))


def main():
    c=Client()
    try:
        status=c.call('form_status');assert pathlib.Path(status['library_path']).resolve().is_relative_to(pathlib.Path('.local').resolve())
        p=c.call('form_create_project',{'name':'LEDGER · Material matters'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'LEDGER / Material inventory','parameters':{'width':180,'depth':220}})
        tabs=[dict(location=300,alignment='center'),dict(location=400,alignment='decimal')]
        table=text(16,105,148,44,'Natural linen\t4\t18.50\nBrushed aluminum\t12\t6.25\nPale oak\t2\t120.00\nUnglazed clay\t8\t9.75',13,
            name='Materials table',tabStops=tabs,defaultTabInterval=0,leading=22)
        note=text(16,166,46,43,'Extraordinary photographic observations illuminate the relationship between objects and light.',16,
            name='Observation',hyphenation=1)
        heading=text(14,33,150,46,'Material\nmatters.',40,font='Baskerville',name='Inventory title',leading=43)
        header=text(16,94,148,7,'MATERIAL\tQTY\tUNIT / USD',8,font='Menlo-Regular',tabStops=[dict(location=300,alignment='center'),dict(location=400,alignment='right')])
        caption=text(16,13,148,7,'LEDGER / AN INVENTORY OF USEFUL THINGS',8,font='Menlo-Regular')
        intro=text(16,83,148,7,'A collection starts with paying attention.',11)
        label=text(16,155,65,7,'NOTES / OBSERVATION',8,font='Menlo-Regular')
        detail=text(95,166,69,36,'Every material has a character. Keep a sample, record its dimensions, and look again in a different light.\n\nGood decisions leave a trace.',11,leading=15)
        footer=text(16,212,148,6,'FORM / STUDIO NOTES                                      VOL. 01',8,font='Menlo-Regular')
        rule=dict(id=str(uuid.uuid4()).upper(),kind='line',x=16,y=148,width=148,height=.1,text='',fontSize=14,color='#243846',stroke={'width':.25,'color':'#243846'})
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F1F0E8','bleed':0,'elements':[caption,heading,intro,header,table,rule,label,note,detail,footer]}})
        style=c.call('form_text_style',{'command':'create','name':'Inventory columns','font_size':13,'typography':table['typography'],
            'object_id':sheet['id'],'element_ids':[table['id']]})['style']['id']
        boxes=[]
        for x,material in [(-230,'oak'),(230,'graphite')]:
            box=c.call('form_add_object',{'recipe_id':'box','name':'LEDGER / '+material.title(),'parameters':{'width':180,'depth':220,'height':12,'corner':2},'material_id':material,'position':[x,0,0]})
            c.call('form_link_artwork',{'object_id':box['id'],'source_object_id':sheet['id']});boxes.append(box)
        package=pathlib.Path(status['library_path'])/(p['id']+'.form')
        def files():return {o['id']:o['file'] for o in json.loads((package/'Manifest.json').read_text())['objects']}
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def element(id):return next(e for e in art()['elements'] if e['id']==id)
        def paragraph(id,patch,**range):
            return c.call('form_edit_artwork',{'command':'paragraph','object_id':boxes[0]['id'],'element_ids':[id],'typography':patch,**range})
        def export(name,fmt='png',**args):
            path=OUTPUT/(name+'.'+fmt)
            result=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'dpi':150,'path':str(path),**args})
            return path.read_bytes(),result
        baseline=c.call('form_get_project');old=files();initial,_=export('ledger-sheet')
        paragraph(table['id'],{'tabStops':[dict(location=280,alignment='right'),dict(location=380,alignment='decimal')]},location=0,length=7)
        assert {id for id in old if files()[id]!=old[id]}=={sheet['id']}
        runs=element(table['id'])['textRuns'];assert runs[0]['typography']['tabStops'][0]['location']==280
        assert runs[-1]['typography']['tabStops'][0]['location']==300
        assert runs[0]['textStyle']['overrides']==['tabStops']
        c.call('form_text_style',{'command':'update','style_id':style,'typography':{'tabStops':[dict(location=290,alignment='center'),dict(location=390,alignment='decimal')]}})
        assert element(table['id'])['textRuns'][0]['typography']['tabStops'][0]['location']==280
        c.call('form_text_style',{'command':'reset','object_id':sheet['id'],'element_ids':[table['id']]})
        assert all(r['typography']['tabStops'][0]['location']==290 for r in element(table['id'])['textRuns'])
        for _ in range(3):c.call('form_undo')
        assert c.call('form_get_project')==baseline
        paragraph(note['id'],{'hyphenation':0});plain,_=export('ledger-no-hyphenation');assert plain!=initial
        c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_batch',{'operations':[
            {'name':'form_edit_artwork','arguments':{'command':'paragraph','object_id':sheet['id'],'element_ids':[table['id']],'typography':{'defaultTabInterval':24}}},
            {'name':'form_edit_artwork','arguments':{'command':'paragraph','object_id':sheet['id'],'element_ids':[table['id']],'typography':{'tabStops':[dict(location=-1,alignment='left')]}}}]},expect_error=True)
        assert c.call('form_get_project')==baseline
        for fmt in ['svg','pdf','jpeg']:export('ledger-sheet',fmt)
        live,report=export('ledger-live','svg',outline_text=False);assert report['composed_text_outlined']==3
        assert '<text ' in live.decode() and '<path' in live.decode()
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[note['id']]})
        assert element(note['id'])['hidden'] and element(note['id'])['text']==note['text']
        export('ledger-outlined');c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_open_project',{'project_id':p['id']});assert c.call('form_get_project')['schemaVersion']==14
        perf=c.call('form_add_object',{'recipe_id':'artboard','name':'Paragraph performance','parameters':{'width':600,'depth':1000}})
        specimens=[text(10+(i%8)*73,10+(i//8)*38,70,36,'Materials\t12.50\nPhotographic observations reward careful attention.',10,
            tabStops=[dict(location=120,alignment='decimal')],hyphenation=1) for i in range(200)]
        c.call('form_set_artwork',{'object_id':perf['id'],'artwork':{'background':'#F1F0E8','bleed':0,'elements':specimens}})
        c.call('form_set_view',{'view':'artwork','object_id':perf['id']})
        times=[]
        for i in range(20):
            start=time.perf_counter();c.call('form_edit_artwork',{'command':'paragraph','object_id':perf['id'],
                'element_ids':[s['id'] for s in specimens],'typography':{'defaultTabInterval':24+i}})
            times.append((time.perf_counter()-start)*1000)
        sampled=c.call('form_status');c.call('form_delete_objects',{'object_ids':[perf['id']]})
        c.call('form_set_view',{'view':'artwork','object_id':boxes[0]['id'],'element_ids':[table['id']]})
        report=dict(project_id=p['id'],sheet_id=sheet['id'],box_ids=[b['id'] for b in boxes],table_id=table['id'],note_id=note['id'],style_id=style,
            saved_edit_median_ms=round(statistics.median(times),2),saved_edit_p95_ms=round(sorted(times)[18],2),performance_status=sampled,
            checks='Saved tab columns; selected-paragraph edits and styles; source-only files; real hyphenated output; invalid batch rollback; composed SVG metadata; recoverable outlines; physical exports; schema 14; 200-paragraph edits')
        (OUTPUT/'paragraph-report.json').write_text(json.dumps(report,indent=2)+'\n')
        (OUTPUT/'paragraph-baseline.json').write_text(json.dumps(c.call('form_get_project'),indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
