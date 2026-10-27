#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$project_dir"
swift build --build-system native -c release
bin_dir=$(swift build --build-system native -c release --show-bin-path)
python3 - "$project_dir" "$bin_dir" <<'PY'
from pathlib import Path
import plistlib
import re
import shutil
import sys
root, binary_dir = map(Path, sys.argv[1:])
version = (root / 'Sources/WifiAnalyzerCore/Resources/VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('VERSION must contain a semantic version such as 0.2.0')
platform = re.search(r'\.macOS\(\.v(\d+)\)', (root / 'Package.swift').read_text())
if not platform:
    raise SystemExit('Cannot determine the minimum macOS version from Package.swift')
minimum_macos = platform.group(1) + '.0'
app = root / 'dist' / 'Wi-Fi Pulse.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(exist_ok=True)
shutil.copy2(binary_dir / 'wifi-analyzer-menu', contents / 'MacOS' / 'wifi-analyzer-menu')
shutil.copy2(root / 'Assets' / 'AppIcon.icns', contents / 'Resources' / 'AppIcon.icns')
shutil.copy2(root / 'LICENSE', contents / 'Resources' / 'LICENSE')
shutil.copytree(binary_dir / 'WifiAnalyzer_WifiAnalyzerCore.bundle', contents / 'Resources' / 'WifiAnalyzer_WifiAnalyzerCore.bundle', dirs_exist_ok=True)
info = {
    'CFBundleIdentifier': 'local.wifi-analyzer.menu',
    'CFBundleName': 'Wi-Fi Pulse',
    'CFBundleDisplayName': 'Wi-Fi Pulse',
    'CFBundleExecutable': 'wifi-analyzer-menu',
    'CFBundleIconFile': 'AppIcon',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': '4',
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en'],
    'LSMinimumSystemVersion': minimum_macos,
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
}
with (contents / 'Info.plist').open('wb') as f:
    plistlib.dump(info, f)
print(app)
PY
codesign --force --sign - "$project_dir/dist/Wi-Fi Pulse.app"
codesign --verify --strict "$project_dir/dist/Wi-Fi Pulse.app"
printf '\nBuilt: %s\n' "$project_dir/dist/Wi-Fi Pulse.app"
