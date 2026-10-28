#!/usr/bin/env python3
"""Real packaged MCP language/paragraph workflow; disposable .local library only.

Creates source-preserving multilingual physical output. No external model/device calls.
The app must already be running against an isolated validation library.
"""
import copy
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
                fontSize=size,color='#24353D',typography=dict(fontName='Georgia',kerningMode='metrics') | typography)


def main():
    c=Client()
    try:
        status=c.call('form_status');library=pathlib.Path(status['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()),'Use a disposable validation library under .local.'
        project=c.call('form_create_project',{'name':'ORBITAL · Languages of form'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'ORBITAL / Multilingual field notes','parameters':{'width':160,'depth':210}})
        title=text(14,14,132,14,'ORBITAL / FIELD NOTES',23,fontName='HelveticaNeue-Medium')
        point=text(14,37,5,12,'istanbul I i ı İ',20,frameMode='point',caseTreatment='uppercase')
        german=text(14,71,48,42,'Donaudampfschifffahrtsgesellschaft\nAußergewöhnliche Konstruktionen verbinden Material und Licht.',14,language='de',hyphenation=1)
        rich=copy.deepcopy(german['typography']);rich['tracking']=0.4
        german['textRuns']=[dict(location=0,length=5,fontSize=16,color='#A55135',typography=rich)]
        area=text(82,71,64,42,'Extraordinary photographic observations illuminate the relationship between objects and light.',14,language='en',hyphenation=1)
        lithuanian=text(14,132,132,15,'I\u0301 J\u0301 Į\u0301 / ORIGINAL WORDS STAY EDITABLE',18,language='lt',caseTreatment='lowercase')
        greek=text(14,159,132,15,'ΟΣ ΟΣΑ — ΦΩΣ ΚΑΙ ΣΧΗΜΑ',18,language='el',caseTreatment='lowercase')
        footer=text(14,192,132,7,'FORM / PUBLICATION STUDIES · 160 × 210 MM',8,fontName='Menlo-Regular')
        elements=[title,point,german,area,lithuanian,greek,footer]
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#F5F1E6','bleed':0,'elements':elements}})
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def element(identifier):return next(e for e in art()['elements'] if e['id']==identifier)
        def language(value):c.call('form_edit_artwork',{'object_id':sheet['id'],'command':'language','language':value})
        area=element(area['id']);point=element(point['id']);german=element(german['id'])
        baseline=c.call('form_get_project')
        for code in ['tr','de_DE','en',None]:
            language(code);changed=art()
            expected='de-DE' if code=='de_DE' else code
            assert changed.get('language')==expected
            assert element(area['id'])==area,'Area dimensions/source must not change with document language.'
            assert element(point['id'])['text']==point['text']
            assert element(point['id'])['width']>5
            assert element(point['id'])['typography'].get('language') is None
            c.call('form_undo');assert c.call('form_get_project')==baseline
        language('tr')
        style=c.call('form_text_style',{'command':'create','name':'Field body / German','font_size':14,
            'typography':{'fontName':'Georgia','kerningMode':'metrics','language':'de','hyphenation':1,
                'hyphenationLimits':{'minimumWordLength':6,'minimumPrefix':2,'minimumSuffix':3}},
            'object_id':sheet['id'],'element_ids':[german['id']]})['style']['id']
        styled=c.call('form_get_project');styled_german=element(german['id'])
        first_length=len(german['text'].split('\n')[0].encode('utf-16-le'))//2
        c.call('form_edit_artwork',{'object_id':sheet['id'],'command':'paragraph','element_ids':[german['id']],
            'location':0,'length':first_length,'typography':{'language':'de-DE','direction':'rtl',
            'hyphenationLimits':{'minimumWordLength':8,'minimumPrefix':3,'minimumSuffix':4}}})
        c.call('form_text_style',{'command':'update','style_id':style,'typography':{'language':'fr','direction':'ltr',
            'hyphenationLimits':{'minimumWordLength':9,'minimumPrefix':2,'minimumSuffix':3}}})
        after=element(german['id']);assert after['text']==german['text']
        first=[r for r in after['textRuns'] if r['location']<first_length]
        second=[r for r in after['textRuns'] if r['location']>first_length]
        assert first and second
        assert all(r['typography']['language']=='de-DE' and r['typography']['direction']=='rtl' for r in first)
        assert all(r['typography']['language']=='fr' and r['typography']['direction']=='ltr' for r in second)
        assert first[0]['color']==styled_german['textRuns'][0]['color']
        c.call('form_undo');c.call('form_undo');assert c.call('form_get_project')==styled
        c.call('form_batch',{'operations':[
            {'name':'form_edit_artwork','arguments':{'object_id':sheet['id'],'command':'language','language':'en'}},
            {'name':'form_edit_artwork','arguments':{'object_id':sheet['id'],'command':'paragraph','element_ids':[german['id']],
             'typography':{'hyphenationLimits':{'minimumWordLength':5,'minimumPrefix':0,'minimumSuffix':2}}}}]},expect_error=True)
        assert c.call('form_get_project')==styled
        exports={}
        for fmt in ['svg','pdf','png']:
            path=OUTPUT/('publication-language.'+fmt)
            exports[fmt]=c.call('form_export_artwork',{'object_id':sheet['id'],'format':fmt,'dpi':150,'outline_text':False,'path':str(path)})
            assert path.stat().st_size>1000
        svg=ET.parse(OUTPUT/'publication-language.svg').getroot()
        assert svg.attrib['width']=='160.0mm' and svg.attrib['height']=='210.0mm'
        live=list(svg.iter('{http://www.w3.org/2000/svg}text'))
        assert any(e.attrib.get('{http://www.w3.org/XML/1998/namespace}lang')=='tr' for e in live)
        assert any('İSTANBUL' in ''.join(e.itertext()) for e in live)
        pdf=(OUTPUT/'publication-language.pdf').read_bytes()
        box=re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)',pdf);assert box
        assert abs(float(box[1])-160*72/25.4)<0.01 and abs(float(box[2])-210*72/25.4)<0.01
        c.call('form_convert_to_paths',{'object_id':sheet['id'],'element_ids':[german['id']]})
        recovered=element(german['id']);assert recovered['hidden'] and recovered['text']==german['text']
        c.call('form_undo');assert c.call('form_get_project')==styled
        c.call('form_open_project',{'project_id':project['id']});reopened=c.call('form_get_project')
        assert reopened['objects']==styled['objects'] and reopened['schemaVersion']==20
        package=library/(project['id']+'.form')
        for resource in package.rglob('*.json'):
            raw=resource.read_text()
            assert all(key not in raw for key in ['inheritedLanguage','studio.form.documentLanguage','studio.form.caseSource','sourceArchive'])
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id'],'element_ids':[point['id']]})
        timings=[]
        for i in range(20):
            start=time.perf_counter();language('en' if i%2==0 else 'tr');timings.append((time.perf_counter()-start)*1000)
        report=dict(project_id=project['id'],sheet_id=sheet['id'],point_id=point['id'],german_id=german['id'],
            style_id=style,exports=exports,status=c.call('form_status'),
            saved_edit_median_ms=round(statistics.median(timings),2),saved_edit_p95_ms=round(sorted(timings)[18],2),
            performance_scope='20 saved document-language edits on this seven-text-object page; status records the active Canvas viewport. This is not a long-story reflow benchmark.',
            checks='Packaged MCP; document tr/de/en/automatic; point/area sizing and exact Undo; paragraph language/direction/limits; rich source/style overrides; invalid batch rollback; physical SVG/PDF/PNG; recoverable outlines; save/reopen; no editing metadata in JSON')
        (OUTPUT/'paragraph-language-report.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ['exports','status']},indent=2))
    finally:c.close()


if __name__=='__main__':main()
