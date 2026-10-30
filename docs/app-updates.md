# App updates

PiWork uses the pinned Sparkle 2.10.1 package for application updates on macOS 13
and later. Sparkle replaces the former GitHub API checker and browser download
flow. The separately updated Pi agent runtime keeps its existing installer.

## User flow

- Check on launch and daily while running, respecting Sparkle's saved automatic
  check preference. Settings → General exposes this preference and manual checks.
- Show the available version in a main-window banner and Software Update settings.
- Clicking **Install Update** authorizes download, signature verification,
  replacement, and normal macOS quit/relaunch. No second install click is needed.
- Show download/extraction progress. Downloads can be cancelled before extraction;
  failed checks and downloads can be retried. Running tasks stop on app restart.
- Keep conversations, configuration, and agent runtimes in Application Support.
  Sparkle manages replacement and installation recovery; the Host handles normal
  stdin EOF when the application quits.

The first version containing this updater must be installed manually by users
of earlier releases. Subsequent updates use the in-app flow.

## Release integration

The app loads `appcast-arm64.xml` or `appcast-x86_64.xml` from the latest GitHub
Release. CI signs the final DMG and its architecture-specific feed with Ed25519.
Both feeds and DMGs are uploaded before the Release becomes public. The minimum
system version in each feed is 13.0.0. `CFBundleVersion` follows
`MARKETING_VERSION`, so Sparkle can compare successive app releases.

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. The app
contains the public key; the private seed is the repository's
`SPARKLE_ED25519_PRIVATE_KEY` Actions Secret. An owner backup is kept under
`~/Library/Application Support/pi-work-release-signing/` with directory mode
0700 and key mode 0600. Keep this key backed up; never commit or log it.

`scripts/fetch-sparkle-tools.sh` verifies the official distribution checksum.
`scripts/generate-appcast.py` signs both archive and feed and rejects missing
keys, mismatched filenames, and invalid versions. No separate hosting service
or GitHub API credentials are needed by the app.

## Verification

```sh
bash scripts/fetch-sparkle-tools.sh
python3 -m unittest scripts/test_appcast.py scripts/test_release_workflow.py
bash scripts/test-app-updates.sh
bash scripts/test-native.sh
```

The standalone checks cover consent, cancellation, download progress, error
retention, architecture routing, and six-language light/dark layouts at
436/620/900 points. XCTest adds controller tests in the existing application
test target. Full XCTest requires Xcode.

For a real local installation test:

```sh
bash scripts/build-app-update-preview.sh
python3 -m http.server 8769 --bind 127.0.0.1 --directory build/app-update-qa/public
open ~/Library/Caches/pi-work/AppUpdateQA/PiWorkUpdateQA.app
```

This fixture uses its own bundle identifier, disposable signing seed, local
feed, and writable app directory. On macOS 26.6, one click upgraded 1.0.0 to
1.0.1 and relaunched the new version. Flipping one byte in the signed DMG was
rejected before extraction while 1.0.0 stayed running; restoring the original
DMG and retrying upgraded and relaunched successfully. The installed PiWork
application and user conversations were not involved in these checks.
