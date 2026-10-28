# iPhone app

This fork adds a native SwiftUI client for iOS 17 or later. The existing Python
daemon, MCP tools, relay API and LiveKit rooms are shared with Android. The relay
supports both platforms at the same time.

Implemented: QR/manual pairing, Keychain credentials, messages and notification
replies, resumable foreground events, incoming CallKit calls, outgoing calls,
joining group calls, LiveKit audio, mute and speaker controls. Incoming calls are
reported to CallKit before any network work. A regular APNs notification is used
for messages and call updates; **only incoming invitations use PushKit**.

## Build

Open `app-ios/Agentring.xcodeproj` in Xcode 16.3 or later. The project is checked
in; XcodeGen is only needed after editing `app-ios/project.yml`:

```bash
cd app-ios
xcodegen generate
xcodebuild -project Agentring.xcodeproj -scheme Agentring \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
swift test
```

Use Xcode's toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`)
if your Mac defaults to the standalone command-line tools, which lack XCTest.
The core tests decode shared protocol fixtures and verify the HMAC test vector.
LiveKit Swift is pinned to 2.17.0; transitive dependencies are locked in the
project's `Package.resolved`.

For the simulator UI test, start an isolated relay in a separate terminal:

```bash
cd relay
npm ci && npm run build
HOST=127.0.0.1 PORT=18080 AGENTRING_PUBLIC_URL=http://127.0.0.1:18080 \
AGENTRING_INSECURE_DEV=1 AGENTRING_DATA_DIR=:memory: \
AGENTRING_API_KEY=ak_ios_ui_test node dist/main.js
```

Then run the Agentring scheme's tests on a dedicated simulator in Xcode. The UI
test pairs manually, receives a message through the relay, replies and relaunches
to check Keychain/session and message persistence. It skips if that relay is not
running. This test key is public and only for the in-memory localhost test relay.
Use normal simulator ad hoc signing (`CODE_SIGN_IDENTITY=-`) when running tests:
`CODE_SIGNING_ALLOWED=NO` is sufficient for a build but prevents Keychain access
at runtime. The project has simulator-only entitlements for these local tests;
physical devices use the APNs entitlements and your provisioning profile.

You can compile and run the UI in the simulator without signing. Incoming VoIP
pushes, locked-phone ringing, Bluetooth routing and microphone conversations must
be validated on a physical iPhone. A successful simulator build does not validate
these paths.

## Apple signing and push

For incoming calls while the iPhone is locked, use a paid Apple Developer account:

1. Create an explicit App ID with **Push Notifications** enabled. Choose a bundle
   ID you control (the default is `dev.agentring.ios`).
2. Set that bundle ID and your development team on the app target in Xcode. Keep
   `project.yml` consistent if you regenerate the project. The project declares
   audio, VoIP and remote-notification background modes and the APNs entitlement.
3. Create an APNs signing key in the Apple Developer portal that supports both
   the app's regular topic and its `.voip` topic. Download its `.p8` file once.
   Keep this private key on the relay, never in the app or Git.
4. Place it in `deploy/secrets/AuthKey.p8` and add these to the deployment env file:

   ```dotenv
   APNS_KEY_FILE=/secrets/AuthKey.p8
   APNS_KEY_ID=YOUR_KEY_ID
   APNS_TEAM_ID=YOUR_TEAM_ID
   APNS_BUNDLE_ID=your.bundle.identifier
   ```

5. Rebuild/restart the relay. `agentring status` should show `apns` (or `fcm+apns`
   when Android push is also configured). Firebase is not needed for iPhone.
6. Build/install on the iPhone, scan the QR produced by `agentring pair`, and grant
   microphone and notification permissions. Settings should show **VoIP registered**.

Debug signing uses APNs sandbox; Release/TestFlight uses production. The app sends
this environment with each token registration. If your provisioning differs,
adjust `APNS_ENVIRONMENT` to match the actual `aps-environment` signing entitlement.
Keys, team ID, bundle ID and token environment must agree. For development, use
HTTPS with a trusted certificate. Private HTTP is permitted by the URL policy and
local networking ATS exception, but OS transport restrictions may vary.

The existing daemon setup is unchanged. Configure LiveKit and the voice backend
as described in [setup.md](setup.md) and [voice.md](voice.md). To receive calls
from the app, run `agentring serve --ai` next to your agents.

## Physical-device acceptance check

1. Send `agentring msg "Hello iPhone"`, open it and reply. Also reply directly
   from the notification; verify the daemon receives the answer once.
2. Lock the iPhone and send `agentring call "Test iPhone" --ai`. Answer through
   the native call screen, verify two-way audio, mute, speaker and hang-up.
3. Repeat with the app in the background. Cancel a ringing call from the daemon
   and check CallKit closes it. Ignore one call and verify the missed-call fallback.
4. Tap **Call agent** and verify the daemon accepts. Join an existing group call
   from another paired phone and check that one phone hanging up does not end the
   other phone's conversation.
5. Switch Wi-Fi/mobile networks, restart the app, rotate push tokens and revoke
   the device with `agentring devices revoke`. Revoked credentials must stop working.

## iOS behavior and limits

- Focus/silent mode follow iOS rules. The Android urgent alarm behavior is not
  replicated; this app does not request Apple's restricted Critical Alerts entitlement.
- iOS suspends background WebSockets. PushKit wakes incoming calls; messages use
  visible APNs alerts. The app reconnects/replays when opened and polls call state
  while a CallKit call exists. Background call updates are best effort, so an
  unanswered incoming call also ends at its ring deadline.
- PushKit requires reporting every incoming VoIP push to CallKit. Invalid payloads
  are reported and immediately ended; their content is never trusted or used for tools.
- Messages are cached with data protection. Device JWT and push HMAC secret use
  `AfterFirstUnlockThisDeviceOnly` Keychain accessibility to support locked calls
  after the first unlock following a reboot.
- APNs payloads are signed, not end-to-end encrypted; Apple can see pushed message
  text and call reasons. Voice-provider privacy constraints are the same as on Android.
- Installation, APNs delivery and two-way audio require your own signing setup and
  physical-device testing; they are not established by the automated tests.

Apple references: [PushKit setup](https://developer.apple.com/documentation/pushkit/supporting-pushkit-notifications-in-your-app),
[responding to VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit).

## Dependency check (2026-10-28)

OSV was queried for all 230 packages/commits in the relay, daemon and iOS lockfiles.
No advisory matched the new Swift dependencies or runtime dependencies. The
upstream test-tool lockfile already contains advisories for `vitest`/`@vitest/mocker`
3.2.7 (GHSA-82fw-gwwq-j7x9, GHSA-qxg6-89mg-rqv8) and `tinypool` 1.1.1
(GHSA-5gmw-xhrv-c9v3, GHSA-85c8-ppgw-ccpr). This port does not change that lockfile;
upgrading the test runner is separate maintenance work. A clean query does not
establish the absence of vulnerabilities.
