#!/usr/bin/env python3
"""Run the current hosted probes against an isolated original git revision.

The baseline is expected to fail H1. This never rewrites the working checkout.
"""
import argparse
import pathlib
import shutil
import subprocess
import tarfile
import time
from hosted_driver import run as run_hosted

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision', help='Original revision to measure, for example e8176f27')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
revision = subprocess.check_output(['git', 'rev-parse', '--verify', args.revision], cwd=root, text=True).strip()
baseline = root / 'build' / ('fullscreen-original-' + revision[:12])
if baseline.exists():
    raise SystemExit(f'Baseline directory already exists: {baseline}; keep its results or remove it explicitly')
baseline.mkdir(parents=True)
archive = baseline / 'source.tar'
with archive.open('wb') as output:
    subprocess.run(['git', 'archive', revision], cwd=root, stdout=output, check=True)
with tarfile.open(archive) as source:
    source.extractall(baseline, filter='data')
archive.unlink()
# Share binaries/headers; keep all production Swift sources at the requested revision.
if (baseline / 'deps').exists():
    shutil.rmtree(baseline / 'deps')
(baseline / 'deps').symlink_to(root / 'deps', target_is_directory=True)
shutil.copytree(root / 'tests', baseline / 'tests', dirs_exist_ok=True)
shutil.copy2(root / 'iina.xcodeproj/project.pbxproj', baseline / 'iina.xcodeproj/project.pbxproj')
shutil.copy2(root / 'iina.xcodeproj/xcshareddata/xcschemes/IINAFullscreenRegression.xcscheme',
             baseline / 'iina.xcodeproj/xcshareddata/xcschemes/IINAFullscreenRegression.xcscheme')
probe = root / 'build/fullscreen-regression/cursor-capture'
subprocess.run([str(probe), '--preflight'], cwd=root, check=True)
directory = baseline / 'build/fullscreen-cursor-probe'
directory.mkdir(parents=True)
with (baseline / 'build/cursor-capture.log').open('w') as output:
    helper = subprocess.Popen([str(probe), str(directory)], cwd=root, stdout=output, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        while not (directory / 'available.json').exists():
            if helper.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Baseline cursor sampler did not start')
            time.sleep(0.05)
        status = run_hosted(baseline, baseline / 'build/original.xcresult', [
            'IINAFullscreenTests/IINAFullscreenTests/testH1VisibleUIIsIdempotentDuringMouseBurst',
            'IINAFullscreenTests/IINAFullscreenTests/testH5MouseResponseDuringRealPlayback',
            'IINAFullscreenTests/IINAFullscreenTests/testH6SystemCursorPresentationCadence'])
        print(f'Original revision={revision}; exit={status}; log={baseline / "build/fullscreen-regression/hosted.log"}')
        raise SystemExit(status)
    finally:
        (directory / 'stop').touch()
        try:
            helper.wait(timeout=5)
        except subprocess.TimeoutExpired:
            helper.terminate()
            helper.wait(timeout=5)
