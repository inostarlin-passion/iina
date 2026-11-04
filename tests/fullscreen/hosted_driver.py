"""Build and test a separate app identity, leaving the user's installed IINA untouched."""
import json
import pathlib
import plistlib
import shutil
import subprocess


def run(root: pathlib.Path, result_path: pathlib.Path, only_testing=()):
    build = root / 'build'
    output = build / 'fullscreen-regression'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'hosted.log').write_text('This run has not reached test execution. See hosted-build.log for build status.\n')
    base = ['xcodebuild', '-project', str(root / 'iina.xcodeproj'),
            '-scheme', 'IINAFullscreenRegression', '-configuration', 'Debug',
            '-destination', 'platform=macOS', '-derivedDataPath', str(build),
            'CODE_SIGNING_ALLOWED=NO']
    # An archive-based comparison can share dependency checkouts with the original workspace.
    packages = (root / 'deps').resolve().parent / 'build/SourcePackages'
    if packages.exists():
        base.extend(['-clonedSourcePackagesDirPath', str(packages)])
    with (output / 'hosted-build.log').open('w') as log:
        compiled = subprocess.run(base + ['build-for-testing'], cwd=root,
                                  stdout=log, stderr=subprocess.STDOUT, timeout=300)
    if compiled.returncode:
        print(f'Hosted build failed; no tests executed. Log: {output / "hosted-build.log"}')
        return compiled.returncode
    original = build / 'Build/Products/Debug/IINA.app'
    host = output / 'IINARegression.app'
    if host.exists():
        shutil.rmtree(host)
    subprocess.run(['ditto', str(original), str(host)], check=True)
    bundle_id = 'com.colliderli.iina.fullscreen-regression-host'
    info_path = host / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = bundle_id
    info_path.write_bytes(plistlib.dumps(info))
    for extension in (host / 'Contents/PlugIns').glob('*.appex'):
        path = extension / 'Contents/Info.plist'
        metadata = plistlib.loads(path.read_bytes())
        metadata['CFBundleIdentifier'] = bundle_id + '.' + extension.stem
        path.write_bytes(plistlib.dumps(metadata))
        subprocess.run(['codesign', '--force', '--sign', '-', str(extension)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(host)], check=True)
    specification_path = next((build / 'Build/Products').glob('IINAFullscreenRegression_*.xctestrun'))
    specification = plistlib.loads(specification_path.read_bytes())

    def configure(item):
        if isinstance(item, dict):
            if item.get('BlueprintName') == 'IINAFullscreenTests':
                item['TestHostPath'] = str(host)
                item['TestHostBundleIdentifier'] = bundle_id
                item.setdefault('CommandLineArguments', []).extend([
                    '-recordPlaybackHistory', 'NO', '-recordRecentFiles', 'NO', '-enablePluginSystem', 'NO'])
            for value in item.values():
                configure(value)
        elif isinstance(item, list):
            for value in item:
                configure(value)

    configure(specification)
    # Keep TESTROOT-relative XCTest framework/dependency paths in their original directory.
    isolated = specification_path.with_name('IINAFullscreenIsolated.xctestrun')
    isolated.write_bytes(plistlib.dumps(specification))
    with (output / 'hosted.log').open('w') as log:
        result = subprocess.run([
            'xcodebuild', '-xctestrun', str(isolated), '-destination', 'platform=macOS',
            '-resultBundlePath', str(result_path),
            *['-only-testing:' + name for name in only_testing], 'test-without-building'],
            cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if result.returncode:
        return result.returncode
    summary = json.loads(subprocess.check_output([
        'xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
        '--path', str(result_path), '--format', 'json'], text=True))
    expected = len(only_testing) if only_testing else 12
    if (summary.get('totalTestCount', 0) < expected or summary.get('skippedTests', 0)
            or summary.get('failedTests', 0)):
        print(f'Incomplete hosted test run: {summary.get("totalTestCount")} tests; '
              f'{summary.get("skippedTests")} skipped; {summary.get("failedTests")} failed')
        return 1
    print(f'Hosted XCTest: {summary["passedTests"]} passed, 0 skipped, 0 failed')
    return 0
