#!/usr/bin/env python3
"""Compile exact production compositor and recorder against Catalyst; no camera is opened."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'App/DualCameraCapture.swift').read_text()
geometry = source[source.index('enum DualCameraGeometry {'):source.index('/// All session, frame, writer')]
lease = source[source.index('private enum CameraHardwareLease {'):source.index('/// Geometry is shared')]
lease = 'final class DualCameraCaptureEngine {}\n' + lease
writer = source[source.index('final class DualCameraMovieWriter {'):]
out = Path(tempfile.mkdtemp(prefix='imim-dual-camera-regression-'))
(out / 'Production.swift').write_text('import AVFoundation\nimport CoreImage\nimport UIKit\n' +
    'enum DualCameraFailure: Error { case recording }\n' + lease + geometry + writer + '\n' +
    (root / 'scripts/DualCameraRegression.swift').read_text())
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
    '-target', 'arm64-apple-ios17.6-macabi', '-sdk', sdk,
    '-F', sdk + '/System/iOSSupport/System/Library/Frameworks', '-I', sdk + '/System/iOSSupport/usr/include',
    str(out / 'Production.swift'), '-o', str(out / 'regression')],
    env=env, check=True)
subprocess.run([str(out / 'regression')], env=env, check=True)
print('Harness artifacts:', out)
