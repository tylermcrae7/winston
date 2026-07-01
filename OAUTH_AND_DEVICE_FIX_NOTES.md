# Winston Local OAuth and Device Crash Fix Notes

Date: 2026-07-01

This document records the fixes applied while building Winston locally, installing it on a physical iPhone, and getting Reddit OAuth working with a personal Reddit developer app. It intentionally does not include Reddit client IDs, client secrets, access tokens, refresh tokens, or Apple signing secrets.

## Environment

- Repo: `/Users/tylermcrae/Documents/GitHub/winston`
- Branch: `tyler/local-xcode-build`
- Xcode used for physical device: Xcode Beta 27.0
- Device target: physical iPhone
- Local app bundle ID: `com.tylermcrae.winston`
- Winston redirect URI in source: `https://app.winston.cafe/auth-success`
- Winston URL scheme: `winstonapp`

## Symptoms

### OAuth authorization screen showed Unauthorized

The app accepted the Reddit app credentials as length-valid, but after Reddit approval Winston returned to the credential screen with an Unauthorized state.

Console evidence from the first diagnostic build showed:

```text
Reddit OAuth token response did not contain an access token. status=401 body={"message": "Unauthorized", "error": 401}
```

This happened after the callback was received and parsed, so it was not primarily a custom URL scheme or redirect callback failure.

### App crash after OAuth worked

After OAuth succeeded, Winston crashed while using the app. The device console showed:

```text
winston/IconManager.swift:62: Fatal error: Unexpectedly found nil while unwrapping an Optional value
App terminated due to signal 5.
```

The crashing source line was:

```swift
var preview: UIImage { UIImage(named: self.name ?? "iconStandard")! }
```

## Root Cause

### OAuth

Reddit's OAuth documentation says the authorization-code token exchange posts to:

```text
https://www.reddit.com/api/v1/access_token
```

with form data:

```text
grant_type=authorization_code&code=CODE&redirect_uri=URI
```

and HTTP Basic Auth where the username is the client ID and the password is the client secret. A 401 response at this endpoint means Reddit rejected the HTTP Basic client credentials.

In Winston, the browser authorization URL trimmed only ordinary spaces from the app ID, while the token exchange and refresh-token flow used the raw `apiAppID` and `apiAppSecret` values. If a credential was pasted or autofilled with hidden whitespace/newlines, Reddit authorization could start but the token exchange could still fail with 401.

The diagnostic pass also found that `injectFirstAccessTokenInto` stripped a trailing `#_` from a local `code` variable, but then built `GetAccessTokenPayload` with the original `authCode` instead of the cleaned `code`.

### Device crash

`WinstonAppIcon.preview` force-unwrapped `UIImage(named:)`. On the device build, `UIImage(named: "iconStandard")` or an alternate icon asset name could return `nil` in that preview path. Rendering Settings > Appearance or App Icon could therefore terminate the app.

## Applied Fixes

### `winston/models/RedditAPI/RedditAPI.swift`

Added a single credential normalizer:

```swift
static func normalizedCredentialComponent(_ value: String) -> String {
  value.components(separatedBy: .whitespacesAndNewlines).joined()
}
```

Used normalized app ID and app secret in:

- `getAuthorizationCodeURL(_:)`
- `injectFirstAccessTokenInto(_:authCode:)`
- Reddit token exchange Basic Auth

Also changed the first token payload to use the cleaned code:

```swift
let payload = GetAccessTokenPayload(code: code)
```

The diagnostic token exchange path now logs only status/body when Reddit returns non-token JSON. It does not print the app ID, app secret, access token, or refresh token.

### `winston/models/Credentials/RedditCredential.swift`

Used normalized app ID and app secret for:

- `validationStatus`
- refresh-token guard
- refresh-token Basic Auth

Also replaced a debug print that included the refresh payload with a safer error-only log:

```swift
print("Reddit OAuth refresh failed: \(error)")
```

### `winston/views/Settings/views/Credentials/EditView/AdvancedMode/CredentialEditAdvancedMode.swift`

Normalized app ID and app secret values as they enter the Advanced credential fields and Safari-extension callback handler.

This handles pasted values with spaces, tabs, or newlines, not just literal space characters.

### `winston/extensions/ViewModifiers/listeners/newCredentialListener.swift`

Normalized app ID and app secret values received through the app URL listener before matching or creating a credential.

### `winston/models/IconManager.swift`

Replaced the force unwrap in `WinstonAppIcon.preview` with fallbacks:

```swift
var preview: UIImage {
  UIImage(named: self.name ?? "iconStandard")
    ?? UIImage(named: "emptyCredential")
    ?? UIImage(systemName: "app.fill")
    ?? UIImage()
}
```

## Verification Performed

### Build and install

Built for the connected physical iPhone with Xcode Beta:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild \
  -project winston.xcodeproj \
  -scheme winston \
  -destination 'id=00008140-001130E11146801C' \
  -onlyUsePackageVersionsFromResolvedFile \
  -scmProvider system \
  -derivedDataPath /private/tmp/winston-beta-device-dd \
  -clonedSourcePackagesDirPath /private/tmp/winston-spm \
  -allowProvisioningUpdates \
  build \
  -quiet
```

Installed the built app:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun devicectl device install app \
  --device F6D7479B-BD0A-5393-9BB0-D0A44007BF54 \
  /private/tmp/winston-beta-device-dd/Build/Products/Debug-iphoneos/winston.app
```

Launched with console capture:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun devicectl device process launch \
  --device F6D7479B-BD0A-5393-9BB0-D0A44007BF54 \
  --terminate-existing \
  --console \
  com.tylermcrae.winston
```

### OAuth result

Tyler retried the auth flow after the credential normalization build and reported that the automatic attempt worked. That means Winston made it past the original Unauthorized credential screen.

### Crash result

After the icon preview fallback build:

- Physical-device build exited with code 0.
- Install to the iPhone succeeded.
- Winston launched with console capture.
- The app stayed running during the watch window.
- The prior `IconManager.swift:62` fatal error did not reappear during that console session.

Remaining non-fatal console noise observed:

```text
DecodingError.valueNotFound: Expected value of type String. Path: features[1].subtitle.
```

That appears to be unrelated Winston API metadata decoding noise and did not terminate the app during this verification window.

## How Someone Else Can Apply The Fix

1. Clone Winston and create a local branch.
2. Confirm the source redirect URI is still `https://app.winston.cafe/auth-success`.
3. Add a credential normalizer that removes all whitespace and newlines from the Reddit app ID and secret.
4. Use normalized credentials everywhere Winston builds the Reddit authorize URL, exchanges the authorization code, refreshes tokens, or receives credentials from app URL callbacks.
5. Confirm the authorization-code token exchange uses the cleaned authorization code value after removing any trailing `#_`.
6. Remove or sanitize logs that could expose client secrets, access tokens, refresh tokens, or payloads containing token values.
7. Replace `IconManager.preview` force unwraps with safe image fallbacks.
8. Build and install on a physical device.
9. Launch with console capture and run the Reddit OAuth flow.
10. Verify the app reaches the signed-in/feed state and no longer terminates when rendering Settings > Appearance or App Icon.

## Reddit App Settings To Check

Do not delete the existing Reddit developer app unless it is unusable.

Expected settings:

- App type: web app or the type Winston expects for client-secret-based OAuth
- Redirect URI: `https://app.winston.cafe/auth-success`
- Client ID and secret copied from the same Reddit app card
- Credentials entered directly into Winston, not committed to source or pasted into public issue text

If Reddit still returns a token endpoint 401 after this patch, check for:

- Wrong client secret
- App ID and secret copied from different Reddit app cards
- Reddit app type mismatch
- Redirect URI mismatch in the Reddit app settings
- A rotated or stale client secret

## GitHub Issue Draft: OAuth Credential Normalization

Title:

```text
Normalize Reddit app credentials before OAuth token exchange
```

Body:

````markdown
## Summary

In a local iOS device build, Winston accepted Reddit app credentials as length-valid and opened Reddit authorization, but the token exchange returned:

```text
401 {"message": "Unauthorized", "error": 401}
```

The callback was received and parsed, so this was not a URL scheme callback failure. Reddit's OAuth docs indicate a 401 at `/api/v1/access_token` means the HTTP Basic client credentials were rejected.

## Root cause

The authorize URL path trimmed only ordinary spaces from the app ID, while the token exchange and refresh-token paths used raw `apiAppID` and `apiAppSecret` values. Credentials pasted or autofilled with hidden whitespace/newlines can pass Winston's length-based validation but fail Reddit Basic Auth.

The first token exchange also strips a trailing `#_` from a local `code` variable but should ensure the cleaned value is used in `GetAccessTokenPayload`.

## Suggested fix

- Add a shared credential normalizer that removes `.whitespacesAndNewlines`.
- Use normalized app ID and app secret for authorize URL generation, token exchange, refresh-token exchange, manual credential entry, and URL callback credential import.
- Use the cleaned authorization code when creating `GetAccessTokenPayload`.
- Avoid logging secrets, refresh tokens, or full token payloads.

## Expected behavior

After Reddit approval, Winston should exchange the authorization code successfully and move the credential to the authorized/signed-in state.
````

## GitHub Issue Draft: App Icon Preview Crash

Title:

```text
Avoid force-unwrapping app icon preview images
```

Body:

````markdown
## Summary

On a physical iPhone build, Winston crashed while rendering app icon preview UI:

```text
winston/IconManager.swift:62: Fatal error: Unexpectedly found nil while unwrapping an Optional value
```

## Root cause

`WinstonAppIcon.preview` force-unwraps `UIImage(named:)`:

```swift
var preview: UIImage { UIImage(named: self.name ?? "iconStandard")! }
```

On device, app icon asset names can return nil through this preview path.

## Suggested fix

Return a fallback image instead of force-unwrapping:

```swift
var preview: UIImage {
  UIImage(named: self.name ?? "iconStandard")
    ?? UIImage(named: "emptyCredential")
    ?? UIImage(systemName: "app.fill")
    ?? UIImage()
}
```

## Expected behavior

Settings > Appearance and App Icon should render without terminating the app, even if a preview image cannot be loaded by name.
````
