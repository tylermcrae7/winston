# Winston Local Setup Notes

Date: 2026-07-01

## Repository

- Repo path: `/Users/tylermcrae/Documents/GitHub/winston`
- Branch: `tyler/local-xcode-build`
- Source repo: `https://github.com/lo-cafe/winston.git`
- Project: `winston.xcodeproj`
- Scheme: `winston`

## Local Toolchain

- Xcode stable: 26.3, build 17C519
- Xcode Beta used for iOS 27 device build: 27.0, build 27A5194q
- Swift: 6.2.4
- Git: 2.50.1 (Apple Git-155)
- Metal Toolchain: installed for both stable Xcode and Xcode Beta with `xcodebuild -downloadComponent MetalToolchain`

## Device

- Device: Tyler's iPhone
- Model: iPhone 16 Pro Max (`iPhone17,2`)
- iOS: 27.0, build 24A5370h
- Developer Mode: enabled
- Pairing/device state: available, paired, booted
- Xcode destination ID: `00008140-001130E11146801C`
- devicectl identifier: `F6D7479B-BD0A-5393-9BB0-D0A44007BF54`

## Winston App Settings

- App bundle ID: `com.tylermcrae.winston`
- Extension bundle ID: `com.tylermcrae.winston.winston-everywhere`
- Apple development team configured in project: `M5H3893R7A`
- Signing certificate display name includes `3AKZJK2Y7H`, but the certificate subject `OU` / developer team ID is `M5H3893R7A`.
- URL scheme: `winstonapp`
- Reddit redirect URI from source: `https://app.winston.cafe/auth-success`
- OAuth source file: `winston/models/RedditAPI/RedditAPI.swift`
- Current source expects Reddit client ID and client secret to be entered in the app UI; do not write those values into files or chat.
- Local signing entitlements were stripped from `winston/winston.entitlements` because Tyler's local provisioning profile rejected push notifications, associated domains, and the upstream iCloud container `iCloud.lo.cafe.winston`.

## Build Status

- Packages resolved successfully with system Git and temp package cache:
  - DerivedData: `/private/tmp/winston-dd`
  - Package checkouts: `/private/tmp/winston-spm`
- Stable Xcode simulator build succeeded for `iPhone 17`, iOS 26.2.
- Build output exists at `/tmp/winston-dd/Build/Products/Debug-iphonesimulator/winston.app`.
- Xcode Beta simulator build succeeded for `iPhone 17 Pro`, iOS 26.2.
- Xcode Beta physical-device build succeeded for Tyler's iPhone.
- Device build output: `/private/tmp/winston-beta-device-dd/Build/Products/Debug-iphoneos/winston.app`
- Winston installed on Tyler's iPhone:
  - Bundle ID: `com.tylermcrae.winston`
  - Version: `1.1.2`
  - Bundle version: `2`
- Winston launched successfully on the iPhone with `devicectl`; process search showed `/winston.app/winston`.
- Dependency fix applied: `swift-markdown-ui` bumped from 2.3.0 to 2.4.1 and transitive `swift-cmark` 0.5.0 added in `Package.resolved`, because 2.3.0 fails under Xcode 26.3 with `InlineNode` circular-reference compiler errors.
- Xcode Beta project reference fix applied: corrected case mismatches for `assets`, `components`, `extensions`, `globals`, `models`, `utils`, `views`, and `views/Settings/views/theming`.
- Xcode Beta Swift compiler fix applied in `winston/extensions/ViewModifiers/swipers/SwipeActionsOld.swift`: initialize the two `@State` backing properties with `State(initialValue:)`.
- OAuth fix applied:
  - normalized Reddit app ID and app secret values across manual entry, URL callback import, authorize URL generation, first token exchange, and refresh-token exchange;
  - used the cleaned authorization code after removing a trailing `#_`;
  - sanitized refresh-token failure logging so token payloads are not printed.
- Tyler retried the OAuth flow after the credential-normalization build and reported that the automatic authorization attempt worked.
- Post-auth crash fix applied in `winston/models/IconManager.swift`: app icon preview loading no longer force-unwraps `UIImage(named:)`; it falls back to `emptyCredential`, then `UIImage(systemName: "app.fill")`, then an empty `UIImage`.
- Rebuilt, reinstalled, and relaunched Winston on Tyler's iPhone after the crash fix. Console capture did not show the prior `IconManager.swift:62` fatal error during the watch window.
- Detailed fix write-up and upstream issue drafts: `OAUTH_AND_DEVICE_FIX_NOTES.md`.

## Next Manual Step

Use Winston normally on the iPhone and watch for any remaining runtime crashes or API failures.

If the app crashes again, relaunch with console capture:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun devicectl device process launch \
  --device F6D7479B-BD0A-5393-9BB0-D0A44007BF54 \
  --terminate-existing \
  --console \
  com.tylermcrae.winston
```

If OAuth regresses, first re-check that the existing Reddit developer app still has the exact redirect URI `https://app.winston.cafe/auth-success`, and confirm credentials are re-entered directly in Winston without copying them into files or chat.

## Reddit App Settings To Verify

- Use Tyler's existing Reddit app named `winston`; do not delete it.
- Redirect URI must be exactly `https://app.winston.cafe/auth-success`.
- Keep credentials out of Git and logs. Tyler should enter the client ID and secret directly in Winston's UI.
