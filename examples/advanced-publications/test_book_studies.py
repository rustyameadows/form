"""Offline protocol/data checks. Native visual/physics acceptance is separate."""
import ast
import copy
import importlib.util
import math
import re
from pathlib import Path
import unittest
import uuid

spec=importlib.util.spec_from_file_location('advanced_book_studies',Path(__file__).with_name('book_studies.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)


def number(value,variables):
    if isinstance(value,(int,float)):
        return float(value)
    def read(node):
        if isinstance(node,ast.Constant) and isinstance(node.value,(int,float)):
            return float(node.value)
        if isinstance(node,ast.Name):
            return math.pi if node.id=='pi' else variables[node.id]
        if isinstance(node,ast.BinOp):
            left,right=read(node.left),read(node.right)
            if isinstance(node.op,ast.Add):return left+right
            if isinstance(node.op,ast.Sub):return left-right
            if isinstance(node.op,ast.Mult):return left*right
            if isinstance(node.op,ast.Div):return left/right
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.USub):return -read(node.operand)
        if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in ('sin','cos','max','min','abs'):
            return dict(sin=math.sin,cos=math.cos,max=max,min=min,abs=abs)[node.func.id](*(read(arg) for arg in node.args))
        raise ValueError(ast.dump(node))
    return read(ast.parse(value,mode='eval').body)


def resolved_values(kind,size,degrees=0,trim=(140,210),controls=None):
    values={**(b.control_values(kind) if controls is None else controls),**dict(width=trim[0],height=trim[1],stackThickness=size['stack'],spineThickness=size['stack']+size['allowance'],bindingAllowance=size['allowance'],openingDegrees=degrees,bindingFlexWidth=b.binding(kind)['flexWidthMM'])}
    pending=dict(b.cover_derived(kind))
    while pending:
        progress=False
        for key,expression in list(pending.items()):
            try:value=number(expression,values)
            except KeyError:continue
            values[key]=value;pending.pop(key);progress=True
        if not progress:raise AssertionError('Cyclic/unknown authored alias: '+str(pending))
    return values


def neutral_curve(points,target):
    def sample(t,p):
        z=1-t
        return tuple(p[0][j]*z**3+3*p[1][j]*z*z*t+3*p[2][j]*z*t*t+p[3][j]*t**3 for j in (0,1))
    def fitted(factor):
        p=[tuple(q) for q in points];p[1]=(points[1][0]*factor,points[1][1]);p[2]=(points[2][0]*factor,points[2][1])
        poly=[sample(i/512,p) for i in range(513)]
        length=sum(math.dist(a,c) for a,c in zip(poly,poly[1:]))
        return length,poly
    low,high=0,100
    if not fitted(low)[0]<=target<=fitted(high)[0]:raise ValueError('No bounded positive curve fit.')
    for _ in range(35):
        middle=(low+high)/2
        if fitted(middle)[0]<target:low=middle
        else:high=middle
    return fitted((low+high)/2)


def document(count=128):
    return dict(id=b.uid('offline/document/'+str(count)),name='Offline logical document',
                pages=[dict(id=b.uid('offline/page/'+str(i)),objectID=b.uid('offline/object/'+str(i))) for i in range(count)])


class Protocol:
    """A recorder of public request shapes, not a replacement geometry engine."""
    def __init__(self):
        self.project=dict(id=b.uid('offline/project'),objects=[],recipes=[],publications=[])
        self.calls=[];self.counter=0
    def call(self,tool,args):
        self.calls.append((tool,copy.deepcopy(args)));self.counter+=1
        if tool=='form_get_project':return copy.deepcopy(self.project)
        if tool=='form_batch':return dict(results=[self.call(operation['name'],operation['arguments']) for operation in args['operations']])
        if tool=='form_create_recipe':
            index=next((i for i,r in enumerate(self.project['recipes']) if r['id']==args['recipe']['id']),None)
            if index is not None:self.project['recipes'][index]=copy.deepcopy(args['recipe'])
            else:self.project['recipes'].append(copy.deepcopy(args['recipe']))
            return args['recipe']
        if tool=='form_add_object':
            recipe=next(r for r in self.project['recipes'] if r['id']==args['recipe_id'])
            obj=dict(id=b.uid('offline/added/'+str(self.counter)),recipeID=recipe['id'],name=args['name'],parameters={p['id']:p['value'] for p in recipe['parameters']})
            self.project['objects'].append(obj);return copy.deepcopy(obj)
        if tool=='form_set_artwork':
            next(obj for obj in self.project['objects'] if obj['id']==args['object_id'])['artwork']=copy.deepcopy(args['artwork']);return dict(updated=args['object_id'])
        if tool=='form_update_object':
            obj=next(obj for obj in self.project['objects'] if obj['id']==args['object_id'])
            obj.setdefault('parameters',{}).update(args.get('parameters',{}))
            for key,field in [('dimension_bindings','dimensionBindings'),('artwork_regions','artworkRegions'),('canvas_source_only','canvasSourceOnly')]:
                if key in args:obj[field]=copy.deepcopy(args[key])
            return dict(updated=obj['id'])
        if tool=='form_publication':
            command=args['command']
            if command=='create':
                doc=dict(id=b.uid('offline/publication/'+str(self.counter)),name=args['name'],pages=[],layout=args['layout'])
                self.project['publications'].append(doc);return dict(publication_id=doc['id'])
            doc=next((p for p in self.project['publications'] if p['id']==args.get('publication_id')),None)
            if command=='create_pages':
                for i in range(args['count']):
                    obj=dict(id=b.uid(doc['id']+'/object/'+str(i)),recipeID='artboard',name='Page',parameters=dict(width=args['width'],depth=args['height']))
                    if args.get('canvas_source_only'):obj['canvasSourceOnly']=True
                    self.project['objects'].append(obj);doc['pages'].append(dict(id=b.uid(doc['id']+'/entry/'+str(i)),objectID=obj['id']))
                return dict(page_ids=[p['objectID'] for p in doc['pages']])
            if command=='get':return copy.deepcopy(doc)
            if command=='sheet_assembly_create':
                recipe=next(r for r in self.project['recipes'] if r['id']==args['recipe_id'])
                obj=dict(id=b.uid('offline/assembly/'+str(self.counter)),name=args['name'],recipeID=recipe['id'],parameters={p['id']:p['value'] for p in recipe['parameters']},sheetAssembly=copy.deepcopy(args['definition']))
                self.project['objects'].append(obj);return dict(object_id=obj['id'])
            if command=='sheet_assembly_configure':
                next(o for o in self.project['objects'] if o['id']==args['object_id'])['sheetAssembly']=copy.deepcopy(args['definition']);return dict(object_id=args['object_id'])
        if tool=='form_construction':
            if args['command']=='create':
                obj=dict(id=b.uid('offline/jacket/'+str(self.counter)),name=args['name'],parameters={p['name']:p['value'] for p in args['definition']['parameters']},paperConstruction=dict(authored=copy.deepcopy(args['definition'])))
                self.project['objects'].append(obj);return dict(object_id=obj['id'])
            return dict(updated=True)
        if tool=='form_link_artwork':
            obj=next(o for o in self.project['objects'] if o['id']==args['object_id'])
            obj['artworkSourceID']=args['source_object_id'];obj['artworkFit']=args['fit'];return dict(updated=True)
        if tool=='form_paper':return dict(updated=True)
        raise AssertionError((tool,args))


class BookStudiesTests(unittest.TestCase):
    def test_independent_signature_nesting_is_complete_and_preserves_reader_order_and_stock(self):
        for kind,count,groups in [('hardcover',128,8),('softcover',96,6)]:
            doc=document(count);plan=b.signature_plan(doc,kind)
            self.assertEqual(len(plan['signatures']),groups)
            self.assertEqual(len(plan['parent_sheets']),count//4)
            order=[]
            for signature in plan['signatures']:
                parents=[p for p in plan['parent_sheets'] if p['id'] in signature['parentSheetIDs']]
                for parent in parents:order += [parent['frontPageIDs'][1],parent['backPageIDs'][0]]
                for parent in reversed(parents):order += [parent['backPageIDs'][1],parent['frontPageIDs'][0]]
            self.assertEqual(order,[p['id'] for p in doc['pages']])
            self.assertEqual(len({p['stock']['profile']['color'] for p in plan['parent_sheets']}),2)
            self.assertAlmostEqual(plan['text_block_thickness_mm'],sum(p['stock']['thicknessMM']*2 for p in plan['parent_sheets']))
    def test_cover_regions_keep_one_canonical_layer_and_all_crops_include_real_wrap_margin(self):
        for kind in ('hardcover','softcover'):
            body=b.signature_plan(document(128 if kind=='hardcover' else 96),kind)['text_block_thickness_mm']
            sizes=b.dimensions(kind,body);art,regions,names=b.cover_art(b.uid('project'),kind,sizes)
            ids=[element_id for region in regions for anchor in region.get('anchors',[]) for element_id in anchor['elementIDs']]
            self.assertEqual(len(ids),len(set(ids)))
            self.assertEqual(set(ids),{v['id'] for v in art['elements']})
            self.assertEqual(art['backgroundOpacity'],0)
            variables=resolved_values(kind,sizes)
            for plane in b.cover_planes(kind,'SOURCE',names,'PHOTO' if kind=='hardcover' else None):
                width,height=(number(plane['size'][k],variables) for k in ('x','y'))
                origin=plane['front']['sourceOriginMM']
                x,y=(number(origin[k],variables) for k in ('x','y'))
                margin=number(plane.get('features',{}).get('stockThickness',plane['stock']['thicknessMM']),variables)+number(plane['features']['wrap']['turnInMM'],variables) if 'wrap' in plane.get('features',{}) else 0
                self.assertGreaterEqual(x-margin,-1e-6);self.assertGreaterEqual(y-margin,-1e-6)
                self.assertLessEqual(x+width+margin,sizes['width']+1e-6);self.assertLessEqual(y+height+margin,sizes['depth']+1e-6)
    def test_semantic_cover_anchors_preserve_left_text_bottom_furniture_and_centered_graphics(self):
        for kind in ('hardcover','softcover'):
            sizes=b.dimensions(kind,7);art,regions,names=b.cover_art(b.uid('project'),kind,sizes)
            intent={identifier:(anchor['horizontal'],anchor['vertical']) for region in regions for anchor in region.get('anchors',[]) for identifier in anchor['elementIDs']}
            expected={name:(0,0) for name in ('front-series','front-title','back-heading','back-copy')}
            expected.update({'front-footer':(0,1),'back-colophon':(0,1),'blind-mark':(.5,1),'spine-title':(.5,.5)})
            if kind=='softcover':expected.update({'front-diagram':(.5,.5),'front-band':(.5,.5),'back-flap':(0,0),'front-flap':(0,0)})
            self.assertEqual(intent,{names[name]:position for name,position in expected.items()})
            moved=copy.deepcopy(art)
            for item in moved['elements']:
                h,v=intent[item['id']];item['x']+=20*h;item['y']+=30*v
            report=b.verify_artwork_translation(art,moved)
            self.assertNotEqual(report['before_artwork_sha256'],report['after_artwork_sha256'])
            self.assertEqual(report['content_style_topology_sha256'],b.digest(b.artwork_translation_invariants(art)))
            self.assertEqual(next(e for e in moved['elements'] if e['name']=='front-title'),next(e for e in art['elements'] if e['name']=='front-title'))
            self.assertEqual(next(e for e in moved['elements'] if e['name']=='front-footer')['y'],next(e for e in art['elements'] if e['name']=='front-footer')['y']+30)
            self.assertEqual(next(e for e in moved['elements'] if e['name']=='blind-mark')['x'],next(e for e in art['elements'] if e['name']=='blind-mark')['x']+10)
            for field,replacement in [('width',91),('fontSize',12),('text','Altered source'),('parentID',b.uid('other parent'))]:
                invalid=copy.deepcopy(moved);invalid['elements'][0][field]=replacement
                with self.assertRaises(ValueError):b.verify_artwork_translation(art,invalid)

    def test_each_visible_default_control_changes_an_actual_physical_field(self):
        paths={'hardcover':dict(boardMM=('front-board','features','stockThickness'),wrapMM=('front-board','features','wrap','stockThickness'),
            overhangMM=('front-board','size','x'),jointMM=('hollowback-bridge','size','x'),clearanceMM=('front-board','size','x'),
            turnInMM=('front-board','features','wrap','turnInMM'),spineBoardMM=('hollowback-bridge','features','stockThickness'),
            insetWidthMM=('front-board','features','recesses',0,'size','x'),insetHeightMM=('front-board','features','recesses',0,'size','y'),
            insetDepthMM=('front-board','features','recesses',0,'depthMM')),
            'softcover':dict(boardMM=('front-cover','features','stockThickness'),overhangMM=('front-cover','size','x'),flapMM=('front-flap','size','x'))}
        for kind in ('hardcover','softcover'):
            controls=b.control_values(kind);size=b.dimensions(kind,7,controls=controls)
            _,_,names=b.cover_art(b.uid('project'),kind,size);planes={p['id']:p for p in b.cover_planes(kind,'SOURCE',names,'PHOTO')}
            base=resolved_values(kind,size,controls=controls)
            self.assertEqual(set(paths[kind]),set(controls))
            for key,path in paths[kind].items():
                changed=dict(controls);changed[key]+=.05
                values=resolved_values(kind,b.dimensions(kind,7,controls=changed),controls=changed)
                scalar=planes
                for part in path:scalar=scalar[part]
                self.assertNotAlmostEqual(number(scalar,base),number(scalar,values),places=10,msg=key+' must affect an actual physical declaration')
            if kind=='hardcover':
                backing,cloth=planes['hollowback-bridge']['stock']['plies']
                self.assertEqual(backing['profile']['texture'],'cotton');self.assertEqual(cloth['profile']['texture'],'linen')
    def test_flexible_hollowback_preserves_constant_length_board_sizes_and_registered_endpoints(self):
        for count,trim in [(64,(140,210)),(128,(150,210)),(192,(155,215))]:
            kind='hardcover';controls=b.control_values(kind)
            if count==192:controls['clearanceMM']=3.5
            body=b.signature_plan(document(count),kind,page_count=count,trim_mm=trim)['text_block_thickness_mm'];size=b.dimensions(kind,body,controls=controls,trim_mm=trim)
            _,_,names=b.cover_art(b.uid('project'),kind,size)
            planes={p['id']:p for p in b.cover_planes(kind,'SOURCE',names,'PHOTO')}
            for degrees in (0,15,45,95,135,150,180):
                values=resolved_values(kind,size,degrees,trim,controls)
                bridge,front,back=(planes[k] for k in ('hollowback-bridge','front-board','back-board'))
                theta=math.radians(degrees);H=values['bindingFlexWidth'];a=max(theta,.000001)
                pw=number(front['size']['x'],values)
                self.assertAlmostEqual(pw,size['panelWidth'],places=9,msg='Rigid board dimensions must not animate with opening.')
                front_pos=tuple(number(front['positionMM'][axis],values) for axis in ('x','y'))
                page_free=(H*math.sin(a)/a+(trim[0]-H)*math.cos(theta),values['caseBase']+H*(1-math.cos(a))/a+(trim[0]-H)*math.sin(theta))
                board_free=(front_pos[0]+pw*math.cos(theta),front_pos[1]+pw*math.sin(theta))
                tangent_overhang=(board_free[0]-page_free[0])*math.cos(theta)+(board_free[1]-page_free[1])*math.sin(theta)
                self.assertAlmostEqual(tangent_overhang,values['overhangMM'],places=8)
                points=[tuple(number(q[axis],values) for axis in ('x','y')) for q in bridge['features']['flex']['curve']['points']]
                target=number(bridge['size']['x'],values);length,curve=neutral_curve(points,target)
                self.assertAlmostEqual(length,target,places=7)
                self.assertGreaterEqual(min(p[1] for p in curve),-1e-9,'The neutral cloth must not hang below the back-board outerface.')
                self.assertAlmostEqual(target,2*values['jointMM']+values['caseSpineLength'],places=9)
                world_end=(curve[-1][0]+values['caseBackX'],curve[-1][1]+values['caseBackY'])
                self.assertAlmostEqual(world_end[0],values['caseWrapX'],places=9);self.assertAlmostEqual(world_end[1],values['caseWrapY'],places=9)
                self.assertAlmostEqual(number(back['positionMM']['x'],values)-pw,values['caseBackX'],places=9)
                self.assertEqual(bridge['front']['sourceObjectID'],'SOURCE')
                self.assertEqual(bridge['stock']['thicknessMM'],.35)
    def test_public_protocol_creates_two_documents_without_app_calls_or_source_copy(self):
        protocol=Protocol();original=copy.deepcopy(protocol.project)
        result=b.build_book_studies(protocol.call,original,include_dust_jackets=True)
        self.assertEqual(original,dict(id=protocol.project['id'],objects=[],recipes=[],publications=[]))
        self.assertEqual(result['hardcover']['page_count'],128);self.assertEqual(result['softcover']['page_count'],96)
        self.assertEqual(len(protocol.project['publications']),2)
        self.assertNotEqual(result['hardcover']['cover_source_id'],result['softcover']['cover_source_id'])
        self.assertIn('Replace vector inset with an actual imported photo',result['hardcover']['acceptance_pending'])
        self.assertTrue(any(tool=='form_link_artwork' and args['fit']=='actual' for tool,args in protocol.calls))
        for record in (result['hardcover'],result['softcover']):
            create_index=next(i for i,(tool,args) in enumerate(protocol.calls) if tool=='form_publication' and args.get('command')=='sheet_assembly_create' and args['definition']['publicationID']==record['publication_id'])
            first_paint=next(i for i,(tool,args) in enumerate(protocol.calls) if tool=='form_set_artwork' and args['object_id'] in record['page_object_ids'])
            self.assertLess(create_index,first_paint)
            self.assertTrue(all(obj.get('canvasSourceOnly') for obj in protocol.project['objects'] if obj['id'] in record['page_object_ids']))
        self.assertFalse(any(tool in ('form_create_project','form_open_project','form_export','form_delete_objects','form_undo') for tool,_ in protocol.calls))
        mutations_before=len(protocol.calls)
        with self.assertRaises(ValueError):b.build_book_study(protocol.call,protocol.project,kind='hardcover')
        self.assertEqual(len(protocol.calls),mutations_before+1,'Only the read-only active-project guard may run on duplicate authoring.')
    def test_all_exported_artwork_payload_kinds_match_actual_app_validation_contract(self):
        # Read the production acceptance list independently of builder helpers.
        # This catches wire-invalid fixture data even when our protocol recorder
        # can transport dictionaries without understanding native Artwork.
        source=(Path(__file__).resolve().parents[2]/'Sources/FormCore/Operations.swift').read_text()
        validation=source[source.index('public func validateArtwork('):]
        actual=ast.literal_eval(re.search(r'\["text",\s*"rectangle"[^\]]*\]',validation).group())
        protocol=Protocol()
        b.build_book_studies(protocol.call,protocol.project,include_dust_jackets=True)
        payloads=[args['artwork'] for tool,args in protocol.calls if tool=='form_set_artwork']
        self.assertGreaterEqual(len(payloads),128+96+4)
        exported=[item for art in payloads for item in art['elements']]
        self.assertTrue(exported)
        self.assertEqual(set(b.ARTWORK_KINDS),set(actual))
        self.assertEqual({item['kind'] for item in exported}-set(actual),set())
        self.assertIn('rectangle',{item['kind'] for item in exported})
        with self.assertRaises(ValueError):
            b.element('invalid shorthand','rect',0,0,10,10)

    def test_all_emitted_scalars_match_actual_native_budget_and_spine_wrap_fits_narrow_panel(self):
        source=(Path(__file__).resolve().parents[2]/'Sources/FormCADModel/CADExpression.swift').read_text()
        actual_limit=int(re.search(r'expression\.utf8\.count\s*<=\s*(\d+)',source).group(1))
        self.assertEqual(actual_limit,256)
        protocol=Protocol();b.build_book_studies(protocol.call,protocol.project,include_dust_jackets=True)
        for _,args in protocol.calls:b.validate_expression_limits(args)
        for count,trim in [(64,(140,210)),(128,(150,210)),(192,(155,215))]:
            plan=b.signature_plan(document(count),'hardcover',page_count=count,trim_mm=trim)
            dims=b.dimensions('hardcover',plan['text_block_thickness_mm'],trim_mm=trim)
            _,_,names=b.cover_art(b.uid('project'),'hardcover',dims)
            variables=resolved_values('hardcover',dims,trim=trim)
            for plane in b.cover_planes('hardcover','SOURCE',names,'PHOTO'):
                b.validate_expression_limits(plane)
                wrap=plane.get('features',{}).get('wrap')
                if wrap:
                    smaller=min(number(v,variables) for v in plane['size'].values())
                    self.assertLessEqual(number(wrap['turnInMM'],variables),smaller/2)
                    self.assertLessEqual(number(wrap['cornerRadiusMM'],variables),smaller/2)
        with self.assertRaises(ValueError):b.validate_expression_limits(dict(positionMM=dict(x='x'*257)))

    def test_three_sewn_volume_variants_have_distinct_canonical_controls_art_and_actual_parent_sizes(self):
        protocol=Protocol();records=[]
        for count,trim in [(64,(140,210)),(128,(150,210)),(192,(155,215))]:
            records.append(b.build_book_study(protocol.call,protocol.project,kind='hardcover',page_count=count,
                                             name=f'Gathered observations / {count}',identity_seed=f'case-volume-{count}',trim_mm=trim))
        self.assertEqual([r['page_count'] for r in records],[64,128,192])
        self.assertEqual([r['parameters']['clearanceMM'] for r in records],[2,2,3.5])
        self.assertEqual([next(p['value'] for p in r['control_recipe']['parameters'] if p['id']=='clearanceMM') for r in records],[2,2,3.5])
        for r in records:
            sizes=b.dimensions('hardcover',r['parent_plan']['text_block_thickness_mm'],controls=r['parameters'],trim_mm=tuple(r['trim_mm']))
            self.assertEqual(r['cover_source']['parameters']['panelWidth'],sizes['panelWidth'])
        self.assertEqual([len(r['definition']['signatures']) for r in records],[4,8,12])
        self.assertEqual([r['trim_mm'] for r in records],[[140,210],[150,210],[155,215]])
        self.assertEqual([r['parent_plan']['parent_sheets'][0]['sizeMM'] for r in records],[dict(x=280,y=210),dict(x=300,y=210),dict(x=310,y=215)])
        recipe_ids=[recipe['id'] for recipe in protocol.project['recipes']]
        self.assertEqual(len(recipe_ids),len(set(recipe_ids)))
        self.assertTrue(all(re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_]{0,63}',key) for key in recipe_ids))
        cover_ids=[r['cover_source_id'] for r in records];self.assertEqual(len(set(cover_ids)),3)
        element_ids=[e['id'] for obj in protocol.project['objects'] for e in obj.get('artwork',{}).get('elements',[])]
        self.assertEqual(len(element_ids),len(set(element_ids)))
        self.assertEqual([r['name'] for r in records],[f'Gathered observations / {n}' for n in (64,128,192)])
        self.assertEqual(len(protocol.project['publications']),3)
        self.assertEqual([r['parent_plan']['text_block_thickness_mm'] for r in records],sorted(r['parent_plan']['text_block_thickness_mm'] for r in records))

    def test_explicit_default_count_and_trim_preserve_original_default_request_payloads(self):
        for kind,count in [('hardcover',128),('softcover',96)]:
            implicit,explicit=Protocol(),Protocol()
            b.build_book_study(implicit.call,implicit.project,kind=kind)
            b.build_book_study(explicit.call,explicit.project,kind=kind,page_count=count,trim_mm=(140,210))
            self.assertEqual(implicit.calls,explicit.calls)
        protocol=Protocol()
        for kwargs in [dict(page_count=190),dict(page_count=True),dict(trim_mm=(139,210)),dict(identity_seed='')]:
            with self.assertRaises(ValueError):b.build_book_study(protocol.call,protocol.project,**kwargs)
        self.assertEqual(protocol.calls,[])

    def test_jacket_fit_repair_is_read_only_preserves_sources_and_uses_actual_closed_measurements(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project,include_dust_jacket=True)
        jacket_id=record['dust_jacket']['object_id'];book_id=record['object_id']
        jacket=next(o for o in protocol.project['objects'] if o['id']==jacket_id)
        book=next(o for o in protocol.project['objects'] if o['id']==book_id)
        source=next(o for o in protocol.project['objects'] if o['id']==jacket['artworkSourceID'])
        # Reproduce an existing, upright source with retained numeric dimensions.
        old=jacket['paperConstruction']['authored'];old.pop('components')
        old['parameters']=[p for p in old['parameters'] if p['name'] not in ('bookFore','bookFloor','boardCore','coverSkin')]
        for panel in old['panels']:panel.pop('features',None)
        for hinge in old['hinges']:
            if hinge['id'] in ('front-turn','back-turn'):hinge.update(angleDegrees=180,layerOffsetMM='paperMM')
        jacket['parameters'].pop('bookFore');jacket['parameters'].pop('bookFloor')
        jacket['parameters']['panelWidth']=157;old['parameters'][0]['value']=147
        jacket['paperConstruction']['finishes']=[dict(id=b.uid('foil'),kind='foil',heightMM=.008,elementIDs=[source['artwork']['elements'][1]['id']])]
        book['parameters']['wrapMM']=.13
        before=copy.deepcopy(protocol.project);patch=b.jacket_fit_operations(before,jacket_id,book_id)
        self.assertEqual(before,protocol.project)
        self.assertEqual(patch['reviewed_project_sha256'],b.digest(before))
        self.assertEqual(patch['source_artwork_sha256'],b.digest(source['artwork']))
        self.assertEqual(patch['jacket_finishes_sha256'],b.digest(jacket['paperConstruction']['finishes']))
        self.assertEqual([op['name'] for op in patch['operations']],['form_construction','form_update_object'])
        proposed=patch['operations'][0]['arguments']['definition']
        for panel,previous in zip(proposed['panels'],old['panels']):
            self.assertEqual(panel['id'],previous['id']);self.assertEqual(panel['polygon'],previous['polygon'])
            if panel['id'] not in ('front-flap','back-flap'):self.assertEqual(panel,previous)
        for hinge,previous in zip(proposed['hinges'],old['hinges']):
            if hinge['id'] not in ('front-turn','back-turn'):self.assertEqual(hinge,previous)
            else:
                self.assertEqual(hinge['angleDegrees'],0);self.assertEqual(hinge['layerOffsetMM'],0)
                self.assertEqual({k:v for k,v in hinge.items() if k not in ('angleDegrees','layerOffsetMM')},
                                 {k:v for k,v in previous.items() if k not in ('angleDegrees','layerOffsetMM')})
        self.assertEqual(proposed['components'],[b.jacket_fit_component()])
        values={p['name']:p['value'] for p in proposed['parameters']}
        self.assertEqual(values['panelWidth'],157,'Add pose controls before resizing the linked canonical atlas.')
        self.assertAlmostEqual(values['bookFore'],143.13)
        self.assertAlmostEqual(values['bookFloor'],-2.705)
        self.assertAlmostEqual(values['boardCore'],2.4);self.assertAlmostEqual(values['coverSkin'],.13)
        for side,edge in [('front','left'),('back','right')]:
            panel=next(p for p in proposed['panels'] if p['id']==side+'-flap')
            flex=panel['features']['flex']
            self.assertEqual(flex['edge'],edge);self.assertEqual(flex['angleDegrees'],-180)
            arc=number(flex['widthMM'],values);radius=arc/math.pi
            self.assertAlmostEqual(2*radius,2.4+2*.13+.18+.5)
            self.assertGreater(arc,0);self.assertLess(arc,values['flapWidth'])
            self.assertEqual(values['flapWidth'],55,'Finite bend consumes neutral source width, never stretches it.')
        self.assertLess(next(p['minimum'] for p in proposed['parameters'] if p['name']=='bookFloor'),-2.705)
        actual={'closedWidth':147.4114,'closedHeight':216.26,'closedThickness':12.830004,'trimWidth':140}
        results={}
        for rel in patch['operations'][1]['arguments']['dimension_bindings']:
            variables={name:(book['parameters'][ref['parameter']] if ref['measurement']=='parameter' else actual[ref['measurement']]) for name,ref in rel['inputs'].items()}
            results[rel['parameter']]=number(rel['expression'],variables)
        self.assertAlmostEqual(results['panelWidth'],148.4114)
        self.assertAlmostEqual(results['panelHeight'],217.26)
        self.assertAlmostEqual(results['spineWidth'],13.430004)
        self.assertAlmostEqual(results['bookFore'],143.13);self.assertAlmostEqual(results['bookFloor'],-2.705)
        self.assertTrue(all('artwork' not in operation['arguments'] for operation in patch['operations']))
        self.assertEqual(source['id'],patch['source_object_id'])
        # The same relationships follow materially different trim and calipers.
        actual.update(closedWidth=157.8,closedHeight=226.5,closedThickness=16.7,trimWidth=150)
        self.assertAlmostEqual(number(b.jacket_fit_bindings(book_id,'hardcover')[0]['expression'],{'book':actual['closedWidth']}),158.8)
        self.assertEqual(protocol.project,before)

    def test_jacket_native_registration_compensates_actual_common_grounding_without_mesh_estimates(self):
        values=dict(bookFore=143.13,panelWidth=148.4114,bookFloor=-2.705,panelHeight=217.26,fold=100)
        # The native root pose is already centered/grounded. Its actual anchor
        # may include layer offsets; do not substitute a guessed half-width.
        actual=[-74.2057,.09,0]
        matrix=[0,0,-1,actual[0],1,0,0,actual[1],0,-1,0,actual[2],0,0,0,1]
        inspection=dict(object_id=b.uid('jacket'),revision='native-revision',parameters=values,
                        definition=dict(components=[b.jacket_fit_component()]),
                        components=[dict(id='jacket-fit',localToWorld=matrix)])
        report=b.jacket_scene_registration(inspection,book_position=(10,20,30))
        desired=[values['bookFore']-values['panelWidth'],values['bookFloor']-.3,values['panelHeight']/2]
        for axis in range(3):
            self.assertAlmostEqual(report['position_mm'][axis]+actual[axis],(10,20,30)[axis]+desired[axis])
        self.assertEqual(report['inspection_revision'],'native-revision')
        decoded=copy.deepcopy(inspection)
        decoded['definition']['components'][0]['rotationDegrees']=dict(x='-90.0',y='0.0',z='90.0')
        self.assertEqual(b.jacket_scene_registration(decoded,book_position=(10,20,30)),report)
        self.assertEqual(b.jacket_fit_component()['rotationDegrees'],dict(x=-90,y=0,z=90))
        # Rz(90)*Rx(-90) maps flat source X to world thickness Y,
        # source -Y to world height Z, and panel normal to world -X.
        self.assertEqual([matrix[i] for i in (0,4,8)],[0,1,0])
        self.assertEqual([matrix[i] for i in (2,6,10)],[-1,0,0])
        for change in [dict(parameters=dict(values,fold=50)),dict(components=[]),dict(definition=dict(components=[]))]:
            with self.assertRaises(ValueError):b.jacket_scene_registration(dict(inspection,**change))

    def test_jacket_fit_rejects_unreviewed_source_or_shared_construction_without_mutating_data(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project,kind='softcover',include_dust_jacket=True)
        jacket_id=record['dust_jacket']['object_id'];book_id=record['object_id']
        original=copy.deepcopy(protocol.project)
        patch=b.jacket_fit_operations(original,jacket_id,book_id)
        self.assertAlmostEqual(patch['registration_parameters']['bookFore'],140)
        self.assertAlmostEqual(patch['registration_parameters']['bookFloor'],-.32)
        for mode in ('locked','another-component','other-book-binding','shared-design','missing-atlas'):
            changed=copy.deepcopy(original);jacket=next(o for o in changed['objects'] if o['id']==jacket_id)
            if mode=='locked':jacket['locked']=True
            elif mode=='another-component':jacket['paperConstruction']['authored']['components'][0]['rotationDegrees']['x']=0
            elif mode=='other-book-binding':jacket['dimensionBindings'][0]['inputs']['book']['sourceObjectID']=b.uid('another-book')
            elif mode=='shared-design':
                jacket['designID']=b.uid('design');other=copy.deepcopy(jacket);other['id']=b.uid('second-jacket');changed['objects'].append(other)
            else:jacket.pop('artworkSourceID')
            baseline=copy.deepcopy(changed)
            with self.assertRaises(ValueError,msg=mode):b.jacket_fit_operations(changed,jacket_id,book_id)
            self.assertEqual(changed,baseline)

    def test_guarded_native_repair_requests_keep_source_and_asset_ids_and_preserve_material_edits(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project)
        before=copy.deepcopy(protocol.project)
        owner=next(o for o in protocol.project['objects'] if o['id']==record['object_id'])
        owner['sheetAssembly']['derived']['customIndependentAlias']='2+3'
        front=next(p for p in owner['sheetAssembly']['enclosure'] if p['id']=='front-board')
        front['stock']['name']='Reviewed existing board stock'
        front['features']['wrap']['stock']['profile']['color']='#355844'
        front['features']['wrap']['stock']['profile']['textureDepthMM']=.02
        front['finishes'][0]['roughness']=.11
        unchanged=copy.deepcopy(protocol.project)
        patch=b.hollowback_repair_operations(protocol.project,record['object_id'])
        self.assertEqual(protocol.project,unchanged,'Preparing a public repair must be read-only.')
        self.assertEqual([op['name'] for op in patch['operations']],['form_update_object','form_create_recipe','form_update_object','form_publication','form_update_object'])
        self.assertFalse(any(op['name'] in ('form_set_artwork','form_import_image','form_delete_objects') for op in patch['operations']))
        definition=patch['operations'][3]['arguments']['definition']
        result_front=next(p for p in definition['enclosure'] if p['id']=='front-board')
        self.assertEqual(result_front['stock'],front['stock'])
        self.assertEqual(result_front['features'],front['features'])
        self.assertEqual(result_front['finishes'],front['finishes'])
        self.assertEqual(definition['derived']['customIndependentAlias'],'2+3')
        self.assertEqual(definition['parentSheets'],owner['sheetAssembly']['parentSheets'])
        self.assertEqual(definition['signatures'],owner['sheetAssembly']['signatures'])
        self.assertEqual(patch['cover_source_id'],record['cover_source_id'])
        self.assertEqual(patch['inset_source_id'],record['inset_source_id'])
        self.assertEqual(patch['source_artwork_sha256'],b.digest(next(o for o in protocol.project['objects'] if o['id']==record['cover_source_id'])['artwork']))
        self.assertEqual(patch['source_regions_sha256'],b.digest(next(o for o in protocol.project['objects'] if o['id']==record['cover_source_id'])['artworkRegions']))
        self.assertTrue(all('artwork_regions' not in op['arguments'] for op in patch['operations']),'Existing declared guide intents must not change during physical repair.')
        # Clearances and wrapping thickness are explicit parameter updates after
        # replacement adds the declarations; merge semantics cannot discard them.
        self.assertEqual(patch['operations'][2]['arguments']['parameters']['clearanceMM'],2)
        self.assertEqual(patch['operations'][2]['arguments']['parameters']['wrapMM'],.12)
        for args in (dict(clearance_mm=math.nan),dict(clearance_mm=True),dict(clearance_mm=5),dict(reinforced_mm=.1),dict(joint_mm=5)):
            with self.assertRaises(ValueError):b.hollowback_repair_operations(protocol.project,record['object_id'],**args)
        self.assertEqual(protocol.project,unchanged)

    def test_softcover_cleanup_prunes_only_unused_controls_after_replacing_their_references(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project,kind='softcover')
        owner=next(o for o in protocol.project['objects'] if o['id']==record['object_id'])
        recipe=next(r for r in protocol.project['recipes'] if r['id']==owner['recipeID'])
        recipe['parameters'] += [b.parameter(k,k,v,0,24) for k,v in dict(wrapMM=.12,turnInMM=14,spineBoardMM=.32,insetWidthMM=12).items()]
        owner['parameters'].update(wrapMM=.12,turnInMM=14,spineBoardMM=.32,insetWidthMM=12)
        owner['sheetAssembly']['derived']['independentSavedAlias']='2+3'
        before=copy.deepcopy(protocol.project);patch=b.softcover_repair_operations(protocol.project,record['object_id'])
        self.assertEqual(protocol.project,before)
        self.assertEqual([op['name'] for op in patch['operations']],['form_publication','form_update_object','form_create_recipe'])
        definition=patch['operations'][0]['arguments']['definition']
        self.assertEqual(definition['derived']['independentSavedAlias'],'2+3')
        for key in ('stock','binding','parentSheets','signatures','auxiliaryLeaves'):
            self.assertEqual(definition[key],owner['sheetAssembly'][key])
        proposed_recipe=patch['operations'][2]['arguments']['recipe']
        self.assertEqual([p['id'] for p in proposed_recipe['parameters']],['boardMM','overhangMM','flapMM'])
        self.assertEqual(patch['cover_source_id'],record['cover_source_id'])
        bindings=patch['operations'][1]['arguments']['dimension_bindings']
        self.assertFalse(any(reference.get('parameter') in ('wrapMM','turnInMM','spineBoardMM','insetWidthMM') for relationship in bindings for reference in relationship['inputs'].values()))
        self.assertFalse(any(op['name'] in ('form_set_artwork','form_import_image') for op in patch['operations']))

    def test_old_recognized_photo_seat_tracks_corrected_board_without_changing_photo_crop_or_other_features(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project)
        owner=next(o for o in protocol.project['objects'] if o['id']==record['object_id'])
        front=next(p for p in owner['sheetAssembly']['enclosure'] if p['id']=='front-board')
        seat=front['features']['recesses'][0];seat['origin']['x']='((width+2*overhangMM)-insetWidthMM)/2'
        original=copy.deepcopy(seat)
        patch=b.hollowback_repair_operations(protocol.project,record['object_id'])
        fixed=next(p for p in patch['operations'][3]['arguments']['definition']['enclosure'] if p['id']=='front-board')['features']['recesses'][0]
        expected=copy.deepcopy(original);expected['origin']['x']='(casePanelWidth-insetWidthMM)/2'
        self.assertEqual(fixed,expected)
        self.assertEqual(len(patch['physical_feature_adjustments']),1)
        self.assertEqual(patch['physical_feature_adjustments'][0]['before'],original['origin']['x'])
        self.assertEqual(patch['physical_feature_adjustments'][0]['after'],fixed['origin']['x'])
        self.assertTrue(all('artwork' not in op['arguments'] and 'artwork_regions' not in op['arguments'] for op in patch['operations']))

    def test_missing_photo_rejects_before_first_public_request(self):
        protocol=Protocol()
        with self.assertRaises(FileNotFoundError):b.build_book_study(protocol.call,protocol.project,photo_path='/private/tmp/no-such-original-inset-asset-99102.png')
        self.assertEqual(protocol.calls,[])

    def test_explicit_bare_softcover_finish_reuses_all_pages_and_keeps_nonempty_figure_sources(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project,kind='softcover')
        owner=next(o for o in protocol.project['objects'] if o['id']==record['object_id'])
        source=next(o for o in protocol.project['objects'] if o['id']==record['cover_source_id'])
        protocol.project['objects'].remove(source);protocol.project['recipes']=[r for r in protocol.project['recipes'] if r['id']!=source['recipeID']]
        for key in ('enclosure','auxiliaryLeaves','derived'):owner['sheetAssembly'].pop(key,None)
        pages=[next(o for o in protocol.project['objects'] if o['id']==identifier) for identifier in record['page_object_ids']]
        pages[0]['artwork']['elements'][0]['text']='KEEP THIS EXISTING FIGURE PLATE'
        pages[1]['artwork']=None;pages[95]['artwork']=dict(elements=[])
        before=copy.deepcopy(protocol.project);start=len(protocol.calls)
        result=b.finish_bare_softcover_study(protocol.call,before,object_id=owner['id'],publication_id=record['publication_id'],
            expected_project_id=before['id'],expected_snapshot_sha256=b.digest(before))
        new_calls=protocol.calls[start:]
        self.assertEqual(result['authored_missing_page_ids'],[pages[1]['id'],pages[95]['id']])
        self.assertEqual(len(result['retained_page_ids']),94)
        for identifier in result['retained_page_ids']:
            self.assertEqual(next(o for o in protocol.project['objects'] if o['id']==identifier),next(o for o in before['objects'] if o['id']==identifier))
        self.assertEqual(sum(tool=='form_add_object' for tool,_ in new_calls),1)
        self.assertFalse(any(tool=='form_publication' and args.get('command') in ('create','create_pages','sheet_assembly_create') for tool,args in new_calls))
        painted={args['object_id'] for tool,args in new_calls if tool=='form_set_artwork'}
        self.assertEqual(painted,{pages[1]['id'],pages[95]['id'],result['cover_source_id']})
        self.assertEqual(protocol.project['publications'],before['publications'])
        self.assertEqual(len(next(o for o in protocol.project['objects'] if o['id']==owner['id'])['sheetAssembly']['enclosure']),5)
        self.assertEqual(result['final_operations'][-1]['arguments']['recipe']['parameters'],next(r for r in before['recipes'] if r['id']==owner['recipeID'])['parameters'])
        with self.assertRaises(ValueError):b.finish_bare_softcover_study(protocol.call,protocol.project,object_id=owner['id'],publication_id=record['publication_id'],expected_project_id=before['id'],expected_snapshot_sha256=b.digest(protocol.project))

    def test_bare_finish_rechecks_live_snapshot_before_any_mutation_including_late_completed_page_art(self):
        protocol=Protocol();record=b.build_book_study(protocol.call,protocol.project,kind='softcover')
        owner=next(o for o in protocol.project['objects'] if o['id']==record['object_id'])
        source=next(o for o in protocol.project['objects'] if o['id']==record['cover_source_id'])
        protocol.project['objects'].remove(source);protocol.project['recipes']=[r for r in protocol.project['recipes'] if r['id']!=source['recipeID']]
        for key in ('enclosure','auxiliaryLeaves','derived'):owner['sheetAssembly'].pop(key,None)
        before=copy.deepcopy(protocol.project)
        protocol.project['objects'][0]['artwork']['elements'][0]['text']='A previous native batch completed after review.'
        start=len(protocol.calls)
        with self.assertRaises(ValueError):b.finish_bare_softcover_study(protocol.call,before,object_id=owner['id'],publication_id=record['publication_id'],expected_project_id=before['id'],expected_snapshot_sha256=b.digest(before))
        self.assertEqual([tool for tool,_ in protocol.calls[start:]],['form_get_project'])


if __name__=='__main__':unittest.main()
