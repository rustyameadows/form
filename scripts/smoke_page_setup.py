#!/usr/bin/env python3
"""Real packaged page setup/physical PDF acceptance in a disposable .local library.

No printing, font installation, external model calls or human clipboard access.
Visible native Apply/Save-panel/PDF-pan acceptance is a separate parent gate.
"""
import json
import pathlib
import uuid
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c=Client()
    try:
        library=pathlib.Path(c.call('form_status')['library_path']).resolve()
        assert library.is_relative_to((ROOT/'.local').resolve()), 'Use a disposable .local validation library.'
        tools=c.discover(['form_edit_artwork','form_export_artwork','form_get_artwork'])
        folder=OUTPUT/'page-setup49';folder.mkdir(exist_ok=True)
        old=folder/'retained-review.pdf';old.write_bytes(b'Previously captured review bytes');original_review=old.read_bytes()
        project=c.call('form_create_project',{'name':'PAGE / Trim, bleed and intent'})
        sheet=c.call('form_add_object',{'recipe_id':'artboard','name':'Physical page source','parameters':{'width':200,'depth':150}})
        title=dict(id=str(uuid.uuid4()).upper(),kind='text',x=18,y=18,width=165,height=16,text='FORM / PHYSICAL PAGE',fontSize=18,color='#243C3A')
        shape=dict(id=str(uuid.uuid4()).upper(),kind='rectangle',x=-4.25,y=30,width=31.25,height=80,text='',fontSize=14,color='#C45339')
        c.call('form_set_artwork',{'object_id':sheet['id'],'artwork':{'background':'#D8E6E0','elements':[shape,title],'bleed':3}})
        def get():return c.call('form_get_project')
        def art():return c.call('form_get_artwork',{'object_id':sheet['id']})
        def setup(**values):return c.call('form_edit_artwork',dict(object_id=sheet['id'],command='page_setup')|values)
        baseline=get();original=art()
        setup(bleed=4.25,safe_inset=7.125);after=get()
        assert after['schemaVersion']>=49 and art()['bleed']==4.25 and art()['safeInset']==7.125
        assert art()['elements']==original['elements'] and after['camera']==baseline['camera']
        c.call('form_undo');assert get()==baseline
        c.call('form_redo');assert get()==after
        for values in [{},{'bleed':True},{'safe_inset':True},{'safe_inset':75},{'safe_inset':-1},{'bleed':26},{'bleed':5,'element_ids':[]},{'extra':4}]:
            c.call('form_edit_artwork',dict(object_id=sheet['id'],command='page_setup')|values,expect_error=True);assert get()==after
        c.call('form_batch',{'operations':[
            {'name':'form_update_object','arguments':{'object_id':sheet['id'],'name':'Must roll back'}},
            {'name':'form_edit_artwork','arguments':dict(object_id=sheet['id'],command='page_setup',safe_inset=75)}
        ]},expect_error=True);assert get()==after
        c.call('form_update_object',{'object_id':sheet['id'],'parameters':{'depth':10}},expect_error=True);assert get()==after
        setup(safe_inset=None);assert art().get('safeInset') is None and art()['bleed']==4.25
        c.call('form_undo');assert get()==after
        options=dict(area='bleed',crop_marks=True,mark_gap_mm=1,mark_length_mm=3)
        preflight=c.call('form_export_artwork',{'object_id':sheet['id'],'format':'preflight','page_output':options})
        assert preflight['media_box_mm']==[0,0,218.5,168.5] and preflight['source_scale']==1
        assert preflight['appearance_validated'] is False and preflight['assets_validated'] is False and 'path' not in preflight
        assert len(preflight['crop_marks'])==8 and preflight['safe_guides_printed'] is False
        assert get()==after
        exports={}
        for area,marks in [('trim',False),('bleed',False),('bleed',True),('trim',True)]:
            name=area+('-crop' if marks else '')
            exports[name]=c.call('form_export_artwork',{'object_id':sheet['id'],'format':'pdf','path':str(folder/(name+'.pdf')),
                                'page_output':dict(options,area=area,crop_marks=marks)})
            assert exports[name]['safe_guides_printed'] is False and exports[name]['appearance_validated'] is True
        assert exports['trim']['included_bleed_mm']==0 and exports['trim']['bleed_box_mm']==exports['trim']['trim_box_mm']
        assert exports['trim-crop']['media_box_mm']==[0,0,210,160]
        exports['legacy']=c.call('form_export_artwork',{'object_id':sheet['id'],'format':'pdf','path':str(folder/'legacy.pdf')})
        assert exports['legacy']['width_mm']==200 and exports['legacy']['height_mm']==150
        sentinel=folder/'keep.pdf';sentinel.write_bytes(b'Approved existing destination')
        for extra in [{'format':'png'},{'element_ids':[]},{'roles':['print']},{'pattern_pieces':False},{'ink_output':'plates'},
                      {'page_output':dict(options,crop_marks=1)},{'page_output':dict(options,unknown=0)}]:
            args=dict(object_id=sheet['id'],format='pdf',path=str(sentinel),page_output=options)|extra
            c.call('form_export_artwork',args,expect_error=True);assert sentinel.read_bytes()==b'Approved existing destination' and get()==after
        assert old.read_bytes()==original_review
        c.call('form_open_project',{'project_id':project['id']});reopened=get()
        assert reopened['objects']==after['objects'] and reopened['camera']==after['camera'] and reopened['schemaVersion']>=49
        c.call('form_set_view',{'view':'artwork','object_id':sheet['id']})
        report=dict(project_id=project['id'],sheet_id=sheet['id'],tools=len(tools),preflight=preflight,exports=exports,
                    checks='Explicit page setup; exact one Undo/Redo; optional clear; source/camera/reopen; strict selectors and no clamping; source-only preflight; actual physical trim/bleed/crop PDFs; unchanged old default; preserved prior bytes and existing destination',
                    native_acceptance_pending=True,hardware_contacted=False,external_model_calls=False,human_clipboard_accessed=False)
        (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    finally:c.close()


if __name__=='__main__':main()
