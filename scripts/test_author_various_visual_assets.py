#!/usr/bin/env python3
"""Offline asset-author initialization checks; never contact or launch LAB."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from author_various_visual_assets import PublicationProof, VisualAssetAuthor


class VisualAssetOutputGuardTests(unittest.TestCase):
    def test_failed_nonempty_output_is_rejected_before_any_native_setup_without_replacing_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'failed-round';output.mkdir()
            retained={
                'visual-authoring-report.json':b'{"passed":false,"error":"retained native failure"}\n',
                'visual-assets.in-progress.json':b'{"state":"authoring","assets":{"original":"retained"}}\n',
                'authoring-plan.json':b'{"originals":"retained exact plan"}\n',
            }
            for name,data in retained.items():(output/name).write_bytes(data)
            self.assertFalse((output/'visual-assets.json').exists(), 'A failed round need not have a final manifest.')
            with patch.object(PublicationProof,'__init__') as native_setup:
                with self.assertRaisesRegex(AssertionError,'fresh empty portfolio output'):
                    VisualAssetAuthor(SimpleNamespace(output=output),{})
                native_setup.assert_not_called()
            self.assertEqual({p.name:p.read_bytes() for p in output.iterdir()},retained)

    def test_missing_or_empty_output_can_initialize_with_a_mocked_native_base(self):
        def offline_setup(author,args):
            author.output=args.output.resolve();author.output.mkdir(parents=True,exist_ok=True)
            author.report=dict(app='/offline/LAB.app',app_sha256='0'*64)
        with tempfile.TemporaryDirectory() as folder:
            for exists in (False,True):
                with self.subTest(existing_empty=exists):
                    output=Path(folder)/('empty' if exists else 'new')
                    if exists:output.mkdir()
                    with patch.object(PublicationProof,'__init__',new=offline_setup):
                        author=VisualAssetAuthor(SimpleNamespace(output=output),dict(editorial_sha256='a'*64))
                    self.assertEqual(author.manifest['state'],'authoring')
                    self.assertTrue((output/'visual-assets.in-progress.json').is_file())
                    self.assertEqual(set(p.name for p in output.iterdir()),{'visual-assets.in-progress.json'})

    def test_preexisting_file_is_rejected_without_replacing_it(self):
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'not-a-folder';output.write_bytes(b'retained source')
            with patch.object(PublicationProof,'__init__') as native_setup:
                with self.assertRaisesRegex(AssertionError,'fresh empty portfolio output'):
                    VisualAssetAuthor(SimpleNamespace(output=output),{})
                native_setup.assert_not_called()
            self.assertEqual(output.read_bytes(),b'retained source')


if __name__=='__main__':unittest.main()
