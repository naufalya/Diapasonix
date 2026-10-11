#!/usr/bin/env python3
"""Offline preservation gates; no signature, driver or hardware operation."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json
import subprocess
import driver_reuse as d

class DriverReuseTests(unittest.TestCase):
    def test_build_contract_catches_per_file_flags_and_retargeting(self):
        repo=Path(__file__).resolve().parents[2]
        project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(repo/'Foundation/RewindDV.xcodeproj/project.pbxproj')]))
        names=subprocess.check_output(['git','-C',str(repo),'ls-tree','-r','--name-only','HEAD'])
        real=subprocess.check_output
        current=copy.deepcopy(project)
        def output(args,**kwargs):
            if args[0]=='git':
                if 'ls-tree' in args:return names.decode() if kwargs.get('text') else names
                if args[-1].endswith(':Foundation/RewindDV.xcodeproj/project.pbxproj'):return json.dumps(current).encode()
                return b'synthetic reviewed source'
            return real(args,**kwargs)
        with patch.object(d.subprocess,'check_output',side_effect=output):
            original=d.source_inputs(repo,'HEAD')['driver_build_contract']
            target=next(o for o in current['objects'].values() if o.get('isa')=='PBXNativeTarget' and o.get('name')=='RewindDVDriver')
            phase=next(current['objects'][i] for i in target['buildPhases'] if current['objects'][i]['isa']=='PBXSourcesBuildPhase')
            file=current['objects'][phase['files'][0]]
            file['settings']={'COMPILER_FLAGS':'-DCHANGED_DRIVER_SEMANTICS=1'}
            self.assertNotEqual(d.source_inputs(repo,'HEAD')['driver_build_contract'],original)
            current=copy.deepcopy(project)
            ref=current['objects'][file['fileRef']];ref['path']='../ASFWDriver/ASFWDriver.cpp'
            self.assertNotEqual(d.source_inputs(repo,'HEAD')['driver_build_contract'],original)
            current=copy.deepcopy(project)
            current['objects']['TEST_PHASE']={'isa':'PBXShellScriptBuildPhase','shellScript':'generate driver inputs','inputPaths':[]}
            target=next(o for o in current['objects'].values() if o.get('isa')=='PBXNativeTarget' and o.get('name')=='RewindDVDriver')
            target['buildPhases'].append('TEST_PHASE')
            self.assertNotEqual(d.source_inputs(repo,'HEAD')['driver_build_contract'],original)
    def test_manifest_catches_bytes_modes_and_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'driver.dext';root.mkdir();p=root/'binary';p.write_bytes(b'original');p.chmod(0o755)
            original=d.bundle_manifest_digest(root)
            p.write_bytes(b'changed');self.assertNotEqual(d.bundle_manifest_digest(root),original)
            p.write_bytes(b'original');self.assertEqual(d.bundle_manifest_digest(root),original)
            p.chmod(0o644);self.assertNotEqual(d.bundle_manifest_digest(root),original)
            (root/'link').symlink_to('../outside')
            with self.assertRaisesRegex(ValueError,'escapes'):d.bundle_manifest(root)
    def test_project_removes_only_driver_dependency_and_embed(self):
        project=Path(__file__).resolve().parents[1]/'RewindDV.xcodeproj/project.pbxproj'
        derived=d.app_only_project(project)
        host=next(o for o in derived['objects'].values() if o.get('isa')=='PBXNativeTarget' and o.get('name')=='RewindDV')
        self.assertEqual(host['dependencies'],[])
        self.assertFalse(any(derived['objects'][i].get('name')=='Embed Driver Extension' for i in host['buildPhases']))
        self.assertTrue(any(derived['objects'][i].get('isa')=='PBXSourcesBuildPhase' for i in host['buildPhases']))
        self.assertTrue(any(derived['objects'][i].get('isa')=='PBXResourcesBuildPhase' for i in host['buildPhases']))

if __name__=='__main__':unittest.main()
