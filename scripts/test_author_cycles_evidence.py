import copy
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parent))
import author_cycles_materials as author
from author_cycles_details import Details
from author_cycles_optics import Optics


class AuthorBuildEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='author-build-evidence-')
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.app=self.root/'Ordinary.app'
        (self.app/'Contents').mkdir(parents=True)
        with (self.app/'Contents/Info.plist').open('wb') as stream:plistlib.dump({'CFBundleExecutable':'NativeApp'},stream)
        self.fixture_files={
            'Contents/MacOS/NativeApp':b'native executable bytes',
            'Contents/MacOS/lab-mcp':b'MCP executable bytes',
            'Contents/Helpers/lab-cycles-render':b'renderer helper bytes',
            'Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json':json.dumps({'source_commit':'source-revision','source_archive_sha256':'archive-digest','display_transform':'test-transform'}).encode()}
        for relative,data in self.fixture_files.items():
            path=self.app/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        folder=self.root/'Study.form/Exports/test.render';folder.mkdir(parents=True)
        self.result={key:str(folder/name) for key,name in [('png','result.png'),('exr','result.exr'),('record','render.json')]}
        for path in self.result.values():Path(path).write_bytes(b'isolated fake tool output')
        self.historic={'view':'whole','attempt':1,'state':'failed','failure':'preserved historical failure'}

    def instance(self,kind=author.Author):
        output=self.root/kind.__name__;output.mkdir(exist_ok=True)
        state={'version':1,'project_id':'project','textures':{},'cases':{'case':{'render_attempts':[copy.deepcopy(self.historic)]}},
               'diagnostics':{'control':{'render_attempts':[copy.deepcopy(self.historic)]}}}
        (output/'state.json').write_text(json.dumps(state))
        args=SimpleNamespace(app=self.app,output=output,samples=64,denoise=True,width=1200,height=900)
        result=kind(args,{'cases':[]});result.notes=[]
        def call(name,arguments=None):
            if name=='form_set_view':return [] if arguments.get('studio_command')=='list' else {'id':'shot'}
            if name=='form_render':return {'job_id':'job','state':'completed'} if arguments['command']=='start' else dict(self.result)
            if name=='form_add_note':result.notes.append(arguments['text']);return {}
            raise AssertionError('Unexpected fake operation: '+name)
        result.call=call
        return result

    def testExactInstalledFileHashesIncludeIndependentHelperAndEngineProvenance(self):
        identity=author.capture_build_identity(self.app)
        self.assertEqual(set(identity['files']),{'app_executable','lab_mcp','renderer_helper','engine_provenance'})
        for entry in identity['files'].values():
            data=self.fixture_files[entry['path']]
            self.assertEqual(entry['sha256'],hashlib.sha256(data).hexdigest())
            self.assertEqual(entry['size_bytes'],len(data))
        self.assertEqual(identity['engine']['source_commit'],'source-revision')
        (self.app/'Contents/Helpers/lab-cycles-render').unlink()
        with self.assertRaises(RuntimeError):author.capture_build_identity(self.app)

    def testHashesCapturedOnceAndOnlyNewMainAttemptsAndNotesReceiveIdentity(self):
        run=self.instance()
        with patch.object(author,'capture_build_identity',wraps=author.capture_build_identity) as capture:
            run.begin_author_run();run.render_shot('case','whole','shot');run.render_shot('case','whole','shot')
            self.assertEqual(capture.call_count,1)
        entries=run.state['cases']['case']['render_attempts']
        self.assertEqual(entries[0],self.historic)
        self.assertEqual(entries[1]['build_identity'],entries[2]['build_identity'])
        self.assertEqual(len(run.state['author_runs']),1)
        for note in run.notes:
            self.assertIn(entries[1]['build_identity']['files']['renderer_helper']['sha256'],note)
            self.assertLessEqual(len(note),4000)

    def testOpticsAndDetailsInheritIdentityWithoutBackfillingHistory(self):
        for kind in (Optics,Details):
            with self.subTest(kind=kind.__name__):
                run=self.instance(kind)
                run.shot('control','whole',['object'],{}, {})
                entries=run.state['diagnostics']['control']['render_attempts']
                self.assertEqual(entries[0],self.historic)
                self.assertEqual(entries[1]['build_identity']['files']['lab_mcp']['sha256'],hashlib.sha256(b'MCP executable bytes').hexdigest())
                self.assertIn(entries[1]['build_identity']['run_id'],run.notes[0])

    def testFailedNewAttemptRetainsItsObservedBuildInProjectNote(self):
        run=self.instance();ordinary_call=run.call
        def failing(name,args=None):
            if name=='form_render':return {'job_id':'failed-job','state':'failed','error':'controlled test failure'}
            return ordinary_call(name,args)
        run.call=failing
        with self.assertRaisesRegex(RuntimeError,'controlled test failure'):run.render_shot('case','close','shot')
        failed=run.state['cases']['case']['render_attempts'][-1]
        self.assertEqual(failed['state'],'failed')
        self.assertIn('build_identity',failed)
        self.assertIn(failed['build_identity']['run_id'],run.notes[0])
        self.assertEqual(run.state['cases']['case']['render_attempts'][0],self.historic)

    def testProjectReadLogKeepsExactDigestAndCompletenessWhileMutationsStayComplete(self):
        payload=dict(view='scoped',revision='session:1',project={'id':'project','name':'Study'},
                     sections={'objects':[{'id':'object','dense_data':'x'*10000}]},
                     pages={'objects':{'offset':0,'returned':1,'total':2,'next_offset':1,'complete':False}},response_complete=False)
        response={'content':[{'type':'text','text':json.dumps(payload)}]}
        logged=author.operation_record('form_get_project',{'view':'scoped'},.1,response)
        expected=json.dumps(response,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
        self.assertEqual(logged['response_digest']['sha256'],hashlib.sha256(expected).hexdigest())
        self.assertEqual(logged['response_digest']['bytes'],len(expected))
        self.assertEqual(logged['read_metadata']['pages'],payload['pages'])
        self.assertNotIn('response',logged)
        for name,value in [('form_cloth',response),('form_render',response),('form_open_project',response),('form_get_project',{'isError':True,'content':[{'type':'text','text':'Failure'}]})]:
            with self.subTest(name=name):
                self.assertEqual(author.operation_record(name,{},0,value)['response'],value)


if __name__=='__main__':unittest.main()
