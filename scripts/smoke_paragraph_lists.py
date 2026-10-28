#!/usr/bin/env python3
"""Real packaged MCP structured-list workflow; disposable .local library only."""
import json
import pathlib
import re
import statistics
import time
import uuid
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT


def text(x,y,w,h,value,size=14,**typography):
    return dict(id=str(uuid.uuid4()).upper(),kind='text',x=x,y=y,width=w,height=h,text=value,
                fontSize=size,color='#24353D',typography=dict(fontName='Georgia',kerningMode='metrics',leading=size*1.45) | typography)


def main():
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()),'Use a disposable validation library under .local.'
        project=c.call('form_create_project',{'name':'ORBITAL · Assembly notes'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'ORBITAL / Structured assembly guide','parameters':{'width':180,'depth':230}})
        checklist=text(14,44,152,46,'Inspect the fabric and lining\nConfirm the decoration placement\nCheck thread colors and backing\nKeep the original artwork editable')
        first=text(14,106,70,47,'Prepare the panels and marks\nPlace each patch against its registration guides')
        second=text(96,106,70,47,'Check dimensions at physical size\nSave the approved arrangement')
        restart=text(14,169,70,30,'Inspect the first sample\nRecord the final settings')
        rtl=text(96,169,70,30,'افحص المواد\nابدأ التجميع',direction='rtl')
        elements=[text(14,12,152,15,'ORBITAL / ASSEMBLY NOTES',23),text(14,34,152,8,'01 / PREPARATION',9),checklist,
            text(14,96,152,8,'02 / ASSEMBLY — CONTINUED ACROSS COLUMNS',9),first,second,
            text(14,159,152,8,'03 / FINAL CHECK — RESTART + RTL',9),restart,rtl,
            text(14,216,152,8,'FORM / INSTRUCTION STUDIES · 180 × 230 MM',8)]
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F5F1E6','bleed':0,'elements':elements}})
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def element(identifier):return next(e for e in art()['elements'] if e['id']==identifier)
        def edit(ids,**kwargs):
            return c.call('form_edit_artwork',{'object_id':sheet['id'],'command':'list','element_ids':ids,**kwargs})
        def export(label,fmt='png',**kwargs):
            path=OUTPUT/(label+'.'+fmt)
            result=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'path':str(path),'dpi':150,'outline_text':False,**kwargs})
            return path,result
        original=c.call('form_get_project')
        edit([checklist['id']],marker='bullet')
        bullet_ids=[i['id'] for i in element(checklist['id'])['listItems']]
        nested_location=len(checklist['text'].split('\n')[0])+1+len(checklist['text'].split('\n')[1])+1
        edit([checklist['id']],list_action='indent',location=nested_location,length=3)
        assert element(checklist['id'])['listItems'][2]['level']==1
        identity=str(uuid.uuid4()).upper()
        edit([first['id'],second['id']],marker='decimal',list_id=identity)
        edit([restart['id']],marker='decimal',list_id=identity,restart=1)
        edit([rtl['id']],marker='decimal')
        before_style=c.call('form_get_project')
        lists_before={e['id']:e.get('listItems') for e in art()['elements']}
        style=c.call('form_text_style',{'command':'create','name':'Assembly body','font_size':14,
            'typography':{'fontName':'Georgia','leading':21,'language':'en'},'object_id':sheet['id'],'element_ids':[first['id'],second['id']]})['style']['id']
        c.call('form_text_style',{'command':'update','style_id':style,'typography':{'tracking':0.2}})
        assert {e['id']:e.get('listItems') for e in art()['elements']}==lists_before
        c.call('form_undo');c.call('form_undo');assert c.call('form_get_project')==before_style
        baseline=c.call('form_get_project')
        assert element(checklist['id'])['text']==checklist['text']
        assert [i['id'] for i in element(checklist['id'])['listItems']]==bullet_ids
        c.call('form_batch',{'operations':[
            {'name':'form_edit_artwork','arguments':{'object_id':sheet['id'],'command':'list','element_ids':[first['id']],'list_action':'remove'}},
            {'name':'form_edit_artwork','arguments':{'object_id':sheet['id'],'command':'list','element_ids':[second['id']],'level':8}}]},expect_error=True)
        assert c.call('form_get_project')==baseline
        edit([second['id']],list_action='restart',location=0,length=2,restart=10)
        changed_path,_=export('publication-lists-restart10');changed_png=changed_path.read_bytes()
        c.call('form_undo');assert c.call('form_get_project')==baseline
        original_path,_=export('publication-lists');assert original_path.read_bytes()!=changed_png
        edit([second['id']],list_action='remove')
        assert not element(second['id']).get('listItems') and element(second['id'])['text']==second['text']
        c.call('form_undo');assert c.call('form_get_project')==baseline
        exports={}
        for fmt in ['svg','pdf','png']:
            path,exports[fmt]=export('publication-lists',fmt);assert path.stat().st_size>1000
        svg=ET.parse(OUTPUT/'publication-lists.svg').getroot()
        assert svg.attrib['width']=='180.0mm' and svg.attrib['height']=='230.0mm'
        assert exports['svg']['composed_text_outlined']>=5
        pdf=(OUTPUT/'publication-lists.pdf').read_bytes()
        box=re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)',pdf);assert box
        assert abs(float(box[1])-180*72/25.4)<0.01 and abs(float(box[2])-230*72/25.4)<0.01
        export('publication-lists-selection','svg',element_ids=[second['id']])
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[first['id'],second['id']]})
        for e in [first,second]:
            recovered=element(e['id']);assert recovered['hidden'] and recovered['text']==e['text'] and recovered['listItems']
        export('publication-lists-outlined')
        c.call('form_undo');assert c.call('form_get_project')==baseline
        c.call('form_open_project',{'project_id':project['id']});reopened=c.call('form_get_project')
        assert reopened['schemaVersion']==23 and reopened['objects']==baseline['objects']
        package=library/(project['id']+'.form')
        for resource in package.rglob('*.json'):
            assert all(key not in resource.read_text() for key in ['resolvedNumber','studio.form.paragraphList','NSTextList'])
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id'],'element_ids':[checklist['id']]})
        timings=[]
        for i in range(20):
            start=time.perf_counter();edit([checklist['id']],list_action='outdent' if i%2 else 'indent',location=nested_location,length=3)
            timings.append((time.perf_counter()-start)*1000)
        assert element(checklist['id'])['listItems'][2]['level']==1
        report=dict(project_id=project['id'],sheet_id=sheet['id'],checklist_id=checklist['id'],first_id=first['id'],second_id=second['id'],
            restart_id=restart['id'],rtl_id=rtl['id'],exports=exports,status=c.call('form_status'),
            saved_edit_median_ms=round(statistics.median(timings),2),saved_edit_p95_ms=round(sorted(timings)[18],2),
            performance_scope='20 saved nesting changes on this ten-text-object page; status records Canvas viewport. Not a long-story benchmark.',
            checks='Packaged MCP; stable source/item identities; bullets/nesting; numbered continuation/restart; RTL; style updates; invalid batch rollback; Undo; real physical SVG/PDF/PNG; recoverable outlines; selection export; schema23 reopen; transient metadata exclusion')
        (OUTPUT/'paragraph-lists-report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ['exports','status']},indent=2))
    finally:c.close()


if __name__=='__main__':main()
