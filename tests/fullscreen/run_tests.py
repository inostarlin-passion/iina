#!/usr/bin/env python3
"""Compile the full production layer on macOS; run static contracts and dynamic probes."""
import argparse
import pathlib
import shutil
import time
from hosted_driver import run as run_hosted
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--integration', action='store_true', help='Run real IINA fullscreen and screen-cursor tests')
parser.add_argument('--only-testing', action='append', default=[], help='Select a hosted XCTest method')
args = parser.parse_args()
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('test_hosted_driver.py'))], check=True)

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build/fullscreen-regression'
BUILD.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'iina/ViewLayer.swift').read_text()
controller = (ROOT / 'iina/MainWindowController.swift').read_text()

def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[opening + 1:end - 1]

checks = {}
display = method(source, 'override func display()')
checks['S01 main-thread dispatch before render lock'] = (
    'if Thread.isMainThread' in display
    and display.index('if Thread.isMainThread') < display.index('displayLock.lock()')
    and 'update(force: true)' in display[:display.index('displayLock.lock()')]
    and 'return' in display[:display.index('displayLock.lock()')])
checks['S02 recursive display lock retained'] = 'displayLock = NSRecursiveLock()' in source
checks['S03 explicit transaction retained'] = all(s in display for s in [
    'CATransaction.begin()', 'super.display()', 'CATransaction.commit()']) and (
    display.index('CATransaction.begin()') < display.index('super.display()')
    < display.index('CATransaction.commit()'))
checks['S04 transaction flush retained'] = 'CATransaction.flush()' in display
checks['S05 skip-render path retained'] = 'MPV_RENDER_PARAM_SKIP_RENDERING' in display
checks['S06 no disabled presentation timing'] = 'MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME' not in source
checks['S07 GL lock before lifecycle lock'] = (
    display.index('lockAndSetOpenGLContext()') < display.index('videoView.$isUninited.withReadLock()'))
for number, name in enumerate(['windowWillEnterFullScreen', 'windowWillExitFullScreen'], 8):
    checks[f'S{number:02} {name} activates display link'] = 'videoView.displayActive()' in method(controller, f'func {name}(')
for number, name in enumerate(['windowDidEnterFullScreen', 'windowDidExitFullScreen'], 10):
    checks[f'S{number:02} {name} retains idle handling'] = 'videoView.displayIdle()' in method(controller, f'func {name}(')
checks['S12 legacy fullscreen shares callbacks'] = all(s in controller for s in [
    'windowWillEnterFullScreen(Notification(name: .iinaLegacyFullScreen))',
    'windowDidEnterFullScreen(Notification(name: .iinaLegacyFullScreen))',
    'windowWillExitFullScreen(Notification(name: .iinaLegacyFullScreen))',
    'windowDidExitFullScreen(Notification(name: .iinaLegacyFullScreen))'])
for label, passed in checks.items():
    print(f'{"PASS" if passed else "FAIL"} {label}', flush=True)

bridge = BUILD / 'bridge.h'
bridge.write_text('#include <mpv/render_gl.h>\nint iina_test_render_calls(void);\n')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', 'macosx', 'clang',
                str(ROOT / 'tests/fullscreen/LegacyFramebufferCheck.c'), '-framework', 'OpenGL',
                '-o', str(BUILD / 'legacy-fbo-check')], check=True)
legacy = subprocess.run([str(BUILD / 'legacy-fbo-check')], timeout=10)
if legacy.returncode not in (0, 2):
    sys.exit(legacy.returncode)
subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-Wno-deprecated-declarations',
                '-I', str(ROOT / 'deps/include'), '-c',
                str(ROOT / 'tests/fullscreen/MPVRenderStub.c'),
                '-o', str(BUILD / 'render-stub.o')], check=True)
command = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
           '-import-objc-header', str(bridge), '-I', str(ROOT / 'deps/include'),
           '-framework', 'Cocoa', '-framework', 'OpenGL',
           '-framework', 'QuartzCore', '-framework', 'CoreVideo',
           str(ROOT / 'tests/fullscreen/Dependencies.swift'),
           *[str(ROOT / 'iina' / name) for name in ['Lock.swift', 'Atomic.swift',
             'ReadWriteLock.swift', 'ReadWriteAtomic.swift', 'ViewLayer.swift']],
           str(ROOT / 'tests/fullscreen/main.swift'), str(BUILD / 'render-stub.o'),
           str(ROOT / 'deps/lib/libmpv.2.dylib'),
           '-Xlinker', '-rpath', '-Xlinker', str(ROOT / 'deps/lib'),
           '-o', str(BUILD / 'regression-tests')]
subprocess.run(command, cwd=ROOT, check=True, stdout=(BUILD / 'compile.log').open('w'),
               stderr=subprocess.STDOUT)
result = subprocess.run([str(BUILD / 'regression-tests')], cwd=ROOT, timeout=30)
if result.returncode != 0 or not all(checks.values()):
    sys.exit(1)
if args.integration:
    probe = BUILD / 'cursor-capture'
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library',
                    str(ROOT / 'tests/fullscreen/CursorCapture.swift'), '-o', str(probe)],
                   cwd=ROOT, check=True)
    subprocess.run([str(probe), '--self-test'], cwd=ROOT, check=True)
    subprocess.run([str(probe), '--preflight'], cwd=ROOT, check=True)
    directory = ROOT / 'build/fullscreen-cursor-probe'
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    result_path = BUILD / ('hosted-' + time.strftime('%Y%m%d-%H%M%S') + '.xcresult')
    with (BUILD / 'cursor-capture.log').open('w') as capture_log:
        helper = subprocess.Popen([str(probe), str(directory)], cwd=ROOT,
                                  stdout=capture_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not (directory / 'available.json').exists():
                if helper.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Cursor sampler did not start; see cursor-capture.log')
                time.sleep(0.05)
            status = run_hosted(ROOT, result_path, args.only_testing)
            print(f'Hosted tests exit={status}; result={result_path}', flush=True)
            sys.exit(status)
        finally:
            (directory / 'stop').touch()
            try:
                helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                helper.terminate()
                helper.wait(timeout=5)

