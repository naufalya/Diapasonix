"""Exact signed-driver preservation and source-input gates for app-only builds."""
import hashlib
import json
import posixpath
from pathlib import Path
import plistlib
import stat
import subprocess

DRIVER_ID = 'net.rewinddigital.RewindDV.Driver'
DEXT = Path('Contents/Library/SystemExtensions') / (DRIVER_ID + '.dext')


def bundle_manifest(root):
    if not root.is_dir() or root.is_symlink():
        raise ValueError('Retained driver must be a real bundle directory')
    rows = {}
    for path in [root] + sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            target = path.readlink()
            if target.is_absolute() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('Retained driver symlink escapes bundle')
            row = {'link': str(target), 'mode': mode}
        elif path.is_file():
            row = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': mode}
        elif path.is_dir():
            row = {'directory': True, 'mode': mode}
        else:
            raise ValueError('Nonregular retained driver input')
        rows[name] = row
    return rows


def bundle_manifest_digest(root):
    return hashlib.sha256(json.dumps(bundle_manifest(root), sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def source_inputs(repo, revision):
    paths = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-r', '--name-only', revision], text=True).splitlines()
    def selected(p):
        return ((p.startswith(('ASFWDriver/', 'Foundation/DriverPolicy/')) and p.endswith(('.cpp', '.hpp', '.h', '.c', '.iig')))
                or p in {'Foundation/Config/DriverVersion.hpp', 'Foundation/Config/ProductIdentity.hpp',
                         'Foundation/Config/DriverInfo.plist', 'Foundation/Config/Driver.entitlements',
                         'Foundation/Config/Driver.Release.entitlements'})
    result = {}
    for p in paths:
        if selected(p):
            raw = subprocess.check_output(['git', '-C', str(repo), 'show', revision + ':' + p])
            result[p] = hashlib.sha256(raw).hexdigest()
    project = subprocess.check_output(['git', '-C', str(repo), 'show', revision + ':Foundation/RewindDV.xcodeproj/project.pbxproj'])
    objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', '--', '-'], input=project))['objects']
    targets = [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'RewindDVDriver']
    if len(targets) != 1:raise ValueError('Ambiguous retained driver build graph')
    target = targets[0]
    configs = objects[target['buildConfigurationList']]['buildConfigurations']
    phases = []
    inputs = {}
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        if phase.get('name') == 'Check Driver Product Identity':
            allowed = {'/usr/bin/python3 -B "$SRCROOT/Tools/product_identity.py" --check',
                       '/usr/bin/python3 -B "$SRCROOT/Tools/product_identity.py" --check --driver-build'}
            if phase.get('isa') != 'PBXShellScriptBuildPhase' or phase.get('shellScript') not in allowed:
                raise ValueError('Unexpected driver identity check implementation')
            continue
        resolved = dict(phase)
        resolved['resolved_files'] = []
        for build_id in phase.get('files', []):
            build_file = objects[build_id]
            ref_id = build_file.get('fileRef')
            if ref_id not in objects:raise ValueError('Unresolved driver compilation file')
            ref = objects[ref_id]
            if ref.get('sourceTree') != 'SOURCE_ROOT':
                raise ValueError('Unresolved driver compilation source root')
            source_path = posixpath.normpath('Foundation/' + ref.get('path', ''))
            if source_path not in paths or source_path.startswith('../'):
                raise ValueError('Driver compilation source missing from reviewed tree')
            source_bytes = subprocess.check_output(['git','-C',str(repo),'show',revision+':'+source_path])
            ancestry = []
            child = ref_id
            while True:
                parents = [(i,o) for i,o in objects.items() if o.get('isa') in {'PBXGroup','PBXVariantGroup'} and child in o.get('children',[])]
                if not parents:break
                if len(parents) != 1:raise ValueError('Ambiguous driver source group')
                child,parent = parents[0]
                ancestry.append({k:v for k,v in parent.items() if k != 'children'})
                if len(ancestry) > len(objects):raise ValueError('Cyclic driver source group')
            resolved['resolved_files'].append({'build_file':build_file,'file_reference':ref,'group_ancestry':ancestry,
                                               'source_sha256':hashlib.sha256(source_bytes).hexdigest()})
        for path in phase.get('inputPaths', []):
            if path.startswith('$(SRCROOT)/'):
                name = 'Foundation/' + path[len('$(SRCROOT)/'):]
                if name not in paths:raise ValueError('Driver generated-input source missing')
                raw=subprocess.check_output(['git','-C',str(repo),'show',revision+':'+name])
                inputs[name]=hashlib.sha256(raw).hexdigest()
            else:raise ValueError('Unresolved driver generated input')
        phases.append(resolved)
    project_settings = [o['buildSettings'] for o in objects.values() if o.get('isa') == 'XCBuildConfiguration'
                        and 'PRODUCT_BUNDLE_IDENTIFIER' not in o.get('buildSettings', {})]
    contract = {'configurations':[objects[i] for i in configs], 'phases':phases, 'generated_inputs':inputs,
                'project_settings':project_settings, 'build_rules':target['buildRules'], 'dependencies':target['dependencies']}
    result['driver_build_contract'] = hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    if not result:
        raise ValueError('Retained driver source inventory is empty')
    return result


def verify_retained(driver, identity, repo, receipt):
    binding = identity.get('driver_reuse')
    if not binding:
        raise ValueError('App-only packaging requires an explicit retained-driver identity')
    info = plistlib.loads((driver / 'Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != DRIVER_ID or info.get('CFBundleVersion') != str(identity['driver_build'])
        or info.get('CFBundleShortVersionString') != binding['product_version']
        or info.get('IOKitPersonalities', {}).get('RewindDVFoundationController', {}).get('FoundationBuildNumber') != str(identity['driver_build'])):
        raise ValueError('Retained driver identity mismatch')
    if bundle_manifest_digest(driver) != binding['bundle_manifest_sha256']:
        raise ValueError('Retained driver bundle differs from pinned full manifest')
    if receipt.get('source_revision') != binding['source_revision'] or receipt.get('bundle_manifest_sha256') != binding['bundle_manifest_sha256']:
        raise ValueError('Retained driver receipt differs from identity binding')
    expected = source_inputs(repo, binding['source_revision'])
    if receipt.get('source_inputs') != expected or source_inputs(repo, 'HEAD') != expected:
        raise ValueError('Driver implementation/entitlements changed; a new driver identity is required')
    subprocess.run(['codesign', '--verify', '--strict', str(driver)], check=True)
    return bundle_manifest(driver)


def app_only_project(project):
    """Derive a host-only build graph; never build or embed a driver target."""
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
    objects = data['objects']
    hosts = [o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'RewindDV']
    if len(hosts) != 1:
        raise ValueError('Ambiguous app target')
    host = hosts[0]
    dependencies = host.get('dependencies', [])
    if len(dependencies) != 1 or objects[dependencies[0]].get('isa') != 'PBXTargetDependency':
        raise ValueError('Unexpected app dependency graph')
    target = objects[objects[dependencies[0]]['target']]
    if target.get('name') != 'RewindDVDriver':
        raise ValueError('Unexpected dependency target')
    embed = [i for i in host['buildPhases'] if objects[i].get('name') == 'Embed Driver Extension']
    if len(embed) != 1:
        raise ValueError('Unexpected driver embed phase')
    host['dependencies'] = []
    host['buildPhases'].remove(embed[0])
    # Relative group/configuration references resolve from the project location,
    # even when SRCROOT is supplied. Root the derived group at the original tree.
    root = objects[objects[data['rootObject']]['mainGroup']]
    root['path'] = str(project.resolve().parent.parent)
    root['sourceTree'] = '<absolute>'
    source_root = project.resolve().parent.parent
    config_ids = {o['baseConfigurationReference'] for o in objects.values()
                  if o.get('isa') == 'XCBuildConfiguration' and 'baseConfigurationReference' in o}
    for ref_id, obj in objects.items():
        if (ref_id in config_ids or obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup'
            or (obj.get('isa') == 'PBXFileReference' and obj.get('sourceTree') == 'SOURCE_ROOT')):
            path = obj.get('path')
            if not path or Path(path).is_absolute():
                raise ValueError('Unexpected source path in app-only projection')
            obj['path'] = str((source_root / path).resolve())
            obj['sourceTree'] = '<absolute>'
    return data
