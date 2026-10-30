#!/bin/bash
# Builds disposable old/new app bundles with an ephemeral signing key and feed.
# Serve build/app-update-qa/public on 127.0.0.1:8769 before opening the fixture.
set -euo pipefail
UPDATE_QA_REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$UPDATE_QA_REPOSITORY"
bash scripts/fetch-sparkle-tools.sh >/dev/null
UPDATE_QA_FRAMEWORK="$UPDATE_QA_REPOSITORY/build/Sparkle-2.10.1"
UPDATE_QA_ROOT="$UPDATE_QA_REPOSITORY/build/app-update-qa"
mkdir -p "$UPDATE_QA_ROOT/public/v1.0.1"
swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -parse-as-library \
  -F "$UPDATE_QA_FRAMEWORK" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  PiWork/Core/UI/AppLanguage.swift PiWork/Core/UI/AppPalette.swift PiWork/Core/UI/AppTheme.swift \
  PiWork/Core/UI/AdaptiveCornerShape.swift \
  PiWork/Core/Update/ReleaseVersion.swift PiWork/Features/Updates/*.swift \
  scripts/AppUpdatePreview.swift -o "$UPDATE_QA_ROOT/UpdateQA"
python3 - "$UPDATE_QA_ROOT" "$UPDATE_QA_FRAMEWORK" <<'PY'
import base64, importlib.util, json, os, pathlib, plistlib, shutil, subprocess, sys
root, framework = map(pathlib.Path, sys.argv[1:])
key_path = root / 'signing-key'
if not key_path.exists():
    key_path.write_text(base64.b64encode(os.urandom(32)).decode())
    key_path.chmod(0o600)
derive = root / 'public-key.swift'
derive.write_text('''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))!)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
public_key = subprocess.check_output(['swift', str(derive), str(key_path)], text=True).strip()
installed = pathlib.Path.home() / 'Library/Caches/pi-work/AppUpdateQA/PiWorkUpdateQA.app'
for version, app in [('1.0.0', installed), ('1.0.1', root / 'new/PiWorkUpdateQA.app')]:
    if app.exists(): shutil.rmtree(app)
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Frameworks').mkdir()
    (contents / 'Resources').mkdir()
    shutil.copy2(root / 'UpdateQA', contents / 'MacOS/UpdateQA')
    subprocess.run(['ditto', str(framework / 'Sparkle.framework'), str(contents / 'Frameworks/Sparkle.framework')], check=True)
    for resource in pathlib.Path('PiWork/Resources').glob('*.lproj'):
        shutil.copytree(resource, contents / 'Resources' / resource.name)
    info = dict(CFBundleExecutable='UpdateQA', CFBundleIdentifier='cc.vibevibe.pi-work.app-update-qa',
                CFBundleName='PiWork Update QA', CFBundlePackageType='APPL',
                CFBundleShortVersionString=version, CFBundleVersion=version, LSMinimumSystemVersion='13.0',
                SUFeedURL='http://127.0.0.1:8769/appcast-arm64.xml', SUPublicEDKey=public_key,
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                NSAppTransportSecurity={'NSAllowsLocalNetworking':True, 'NSAllowsArbitraryLoads':True})
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--preserve-metadata=entitlements,flags,runtime', '--sign', '-', str(app)], check=True)
dmg = root / 'public/v1.0.1/PiWork-1.0.1-macos-arm64.dmg'
subprocess.run(['hdiutil', 'create', '-volname', 'PiWork Update QA', '-srcfolder', str(root / 'new'),
                '-format', 'UDZO', '-ov', str(dmg)], check=True, stdout=subprocess.DEVNULL)
spec=importlib.util.spec_from_file_location('appcast', 'scripts/generate-appcast.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.generate('1.0.1', 'arm64', dmg, root / 'public/appcast-arm64.xml', framework / 'bin/sign_update',
                key_path.read_text(), download_base='http://127.0.0.1:8769')
print(f'Built isolated updater fixture: {installed}')
PY
