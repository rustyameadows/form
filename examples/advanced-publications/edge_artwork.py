"""Editable, registered interior-page edge inks, authored only through public MCP.

The caller supplies the ordinary app connection; importing this module performs
no I/O. Endpapers keep their own stock. All ink sources remain canonical Canvas
artwork at physical millimeter size, separate from page-face printing.
"""
import copy
import uuid


def build_edge_artwork(call, project_state, book_id, *, image_path=None):
    owner=next(o for o in project_state['objects'] if o['id']==book_id)
    if not owner.get('sheetAssembly'):
        raise ValueError('Choose an existing physical sheet assembly.')
    report=call('form_publication',{'command':'sheet_assembly_inspect','object_id':book_id})
    measures=report['resolved'];thickness=measures['text_block_thickness_mm']
    definition=copy.deepcopy(owner['sheetAssembly']);faces={};sources={}
    for edge,measurement,width in [('head','trimWidth',measures['trim_width_mm']),('tail','trimWidth',measures['trim_width_mm']),('foreEdge','trimHeight',measures['trim_height_mm'])]:
        source=call('form_add_object',{'recipe_id':'artboard','name':owner['name']+' / '+edge+' edge ink','parameters':{'width':width,'depth':thickness}})
        source_id=source['id'];background_id=str(uuid.uuid4()).upper();type_id=str(uuid.uuid4()).upper()
        background={'id':background_id,'kind':'rectangle','x':0,'y':0,'width':width,'height':thickness,'text':'','color':'#345B4B' if edge!='tail' else '#B58C51','fontSize':14}
        title={'id':type_id,'kind':'text','x':7,'y':max(0,(thickness-3)/2),'width':max(1,width-14),'height':3,'text':'INTERVAL / FIELD STUDIES' if edge=='foreEdge' else 'FIELD / 01','color':'#F3E6A4' if edge!='tail' else '#243B35','fontSize':7,'typography':{'fontName':'HelveticaNeue','leading':8.5}}
        artwork={'background':'#FFFFFF','backgroundOpacity':0,'bleed':0,'unit':'mm','elements':[background,title]}
        call('form_set_artwork',{'object_id':source_id,'artwork':artwork})
        if edge=='head' and image_path:
            call('form_import_image',{'object_id':source_id,'path':str(image_path),'x':width*.50,'y':0,'width':width*.50,'height':thickness,'name':'Original portfolio image / head-edge registration'})
        inputs={'long':{'sourceObjectID':book_id,'measurement':measurement},'block':{'sourceObjectID':book_id,'measurement':'textBlockThickness'}}
        bindings=[{'parameter':'width','expression':'long','inputs':inputs},{'parameter':'depth','expression':'block','inputs':inputs}]
        artwork_bindings=[{'id':'edge-ink-width','elementID':background_id,'property':'width','value':'width'},
                          {'id':'edge-ink-depth','elementID':background_id,'property':'height','value':'depth'}]
        region={'id':'edge','name':'Interior page-block / '+edge,'origin':{'x':0,'y':0},'size':{'x':'width','y':'depth'},'anchors':[{'elementIDs':[type_id],'horizontal':0,'vertical':.5}]}
        call('form_update_object',{'object_id':source_id,'canvas_source_only':True,'dimension_bindings':bindings,'artwork_parameter_bindings':artwork_bindings,'artwork_regions':[region]})
        faces[edge]={'sourceObjectID':source_id,'sourceSide':'outside'}
        sources[edge]={'object_id':source_id,'width_mm':width,'depth_mm':thickness,'bindings':bindings}
    definition['edgeArtwork']=faces
    call('form_publication',{'command':'sheet_assembly_configure','object_id':book_id,'definition':definition})
    return {'book_id':book_id,'sources':sources,'edge_artwork':faces,'registration':'Closed interior block; canonical ink is sampled onto the corresponding leaf edges before opening/fanning. Endpaper stocks remain unprinted.'}
