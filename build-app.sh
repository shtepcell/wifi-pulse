#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$project_dir"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
python3 - "$project_dir" "$bin_dir" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys
root, binary_dir = map(Path, sys.argv[1:])
app = root / 'dist' / 'Wi-Fi Analyzer.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(exist_ok=True)
shutil.copy2(binary_dir / 'wifi-analyzer-menu', contents / 'MacOS' / 'wifi-analyzer-menu')
shutil.copytree(binary_dir / 'WifiAnalyzer_WifiAnalyzerCore.bundle', contents / 'Resources' / 'WifiAnalyzer_WifiAnalyzerCore.bundle', dirs_exist_ok=True)
info = {
    'CFBundleIdentifier': 'local.wifi-analyzer.menu',
    'CFBundleName': 'Wi-Fi Analyzer',
    'CFBundleDisplayName': 'Wi-Fi Analyzer',
    'CFBundleExecutable': 'wifi-analyzer-menu',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.2.0',
    'CFBundleVersion': '3',
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en'],
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'WASessionsDirectory': str(root / 'sessions'),
}
with (contents / 'Info.plist').open('wb') as f:
    plistlib.dump(info, f)
print(app)
PY
codesign --force --sign - "$project_dir/dist/Wi-Fi Analyzer.app"
codesign --verify --strict "$project_dir/dist/Wi-Fi Analyzer.app"
printf '\nBuilt: %s\n' "$project_dir/dist/Wi-Fi Analyzer.app"
