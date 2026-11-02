import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid

import compact_project_package as subject


class CompactPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.source=self.root/'source.form'
        (self.source/'Objects').mkdir(parents=True);(self.source/'Assets/nested').mkdir(parents=True)
        identity=str(uuid.uuid4());data=b' { "id": "'+identity.encode()+b'", "custom": [1, 2, 3] }\n'
        self.name=identity+'-revision.json';(self.source/'Objects'/self.name).write_bytes(data)
        (self.source/'Objects/unreferenced.json').write_bytes(b'old immutable revision')
        (self.source/'Assets/nested/image.png').write_bytes(b'original asset bytes')
        (self.source/'Exports').mkdir();(self.source/'Exports/old.pdf').write_bytes(b'old export')
        manifest=dict(project=dict(id=str(uuid.uuid4()),name='Byte-preserved sample',schemaVersion=63,objects=[]),objects=[dict(id=identity,file=self.name)])
        self.raw=('  '+json.dumps(manifest,ensure_ascii=False)+'\n').encode();(self.source/'Manifest.json').write_bytes(self.raw)
        self.digest=hashlib.sha256(self.raw).hexdigest()
    def tearDown(self):self.temp.cleanup()
    def test_copies_only_active_revisions_and_all_assets_without_reserializing(self):
        destination=self.root/'copy.form';report=self.root/'copy-proof.json'
        proof=subject.copy_package(self.source,destination,self.digest,report)
        self.assertEqual((destination/'Manifest.json').read_bytes(),self.raw)
        self.assertEqual((destination/'Objects'/self.name).read_bytes(),(self.source/'Objects'/self.name).read_bytes())
        self.assertEqual((destination/'Assets/nested/image.png').read_bytes(),b'original asset bytes')
        self.assertFalse((destination/'Objects/unreferenced.json').exists());self.assertFalse((destination/'Exports').exists())
        self.assertEqual(proof['object_count'],1);self.assertTrue(proof['source_bytes_unchanged'])
        subject.verify_files(destination,json.loads(report.read_text()))
        (destination/'Assets/nested/image.png').write_bytes(b'changed')
        with self.assertRaises(ValueError):subject.verify_files(destination,proof)
    def test_hash_path_and_overwrite_guards_never_mutate_source_or_existing_target(self):
        destination=self.root/'copy.form';report=self.root/'copy-proof.json'
        with self.assertRaises(ValueError):subject.copy_package(self.source,destination,'0'*64,report)
        self.assertFalse(destination.exists());self.assertEqual((self.source/'Manifest.json').read_bytes(),self.raw)
        destination.mkdir();(destination/'keep').write_bytes(b'keep')
        with self.assertRaises(ValueError):subject.copy_package(self.source,destination,self.digest,report)
        self.assertEqual((destination/'keep').read_bytes(),b'keep')
        data=json.loads(self.raw);data['objects'][0]['file']='../escape.json';(self.source/'Manifest.json').write_text(json.dumps(data))
        with self.assertRaises(ValueError):subject.inventory(self.source)
    def test_asset_symlinks_are_rejected_instead_of_following_external_files(self):
        outside=self.root/'outside';outside.write_bytes(b'not a project asset')
        (self.source/'Assets/link').symlink_to(outside)
        with self.assertRaises(ValueError):subject.inventory(self.source)
        self.assertEqual(outside.read_bytes(),b'not a project asset')


if __name__=='__main__':unittest.main()
