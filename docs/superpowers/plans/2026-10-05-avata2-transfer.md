# Avata 2 Wireless Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution, or superpowers:subagent-driven-development if Alex selects that method. Steps use checkbox syntax for tracking.

**Goal:** Download original Avata 2 photos and videos directly to the Mac over Bluetooth and Wi-Fi.

**Architecture:** Reuse Osmotic's UI, Wi-Fi cleanup, and HTTP downloader. Add an explicit Avata profile and a separate drone session, collector, and decoder behind a shared media-session interface. Keep the existing Osmo protocol and golden expectations intact.

**Tech Stack:** Swift 6.2+, SwiftUI, CoreBluetooth, CoreWLAN, POSIX UDP, URLSession, Swift Testing; macOS 15+.

**Spec:** [Approved design](../specs/2026-10-05-avata2-transfer-design.md).

## Global constraints

- Model ID `0x0077`; service `FFF0`; pairing token `DJI FLY`.
- Remote and local UDP port 9003; no TCP-7001 poke or Osmo registration/playback/clock commands for drones.
- App display name `Osmotic Avata`; bundle ID `io.github.kc3bzu.osmotic-avata`; separate app state; upstream updater disabled.
- Preserve MIT notices, upstream credits, camera behavior, and decoder golden files.
- One worker owns each session socket; no private payloads in logs; manifest limit 8 MiB.
- Release every open media transfer on success, empty result, failure, and cancellation.
- Original HTTP URLs contain file index, subtype 0, and segment selector; HTTP lengths govern completion.
- Downloads namespace device, storage, directory, and media identity; never overwrite an existing file.
- Avata support stays experimental until photo and video originals match USB/card hashes.
- No flight control, capture control, deletion, firmware changes, or public release.

## Review focus

1. Two nearby drones and stale callbacks: connecting device A cannot consume device B's callbacks or credentials. Task 6 owns this check.
2. Reused file numbers after card formatting: old history or partial data must not cause a new clip to be skipped or resumed. Task 5 owns this check.
3. Cancellation during pairing, listing, or HTTP: sockets and transfer slots are released, and Wi-Fi restoration finishes. Tasks 2, 4, and 6 own these checks.
4. Empty, truncated, or reordered manifests: valid empty responses differ from unsupported storage and incomplete transfers. Task 4 owns this check.
5. An Avata session differing from Mavic: stop at a specific unsupported stage without sending unrelated upload or control commands. Task 3 owns this check.

## Baseline and toolchain

Source baseline: `e5c1498eb8986f4d8c0f38c3bda3c8583e90eb16`.

On 2026-10-05 the unmodified core bundle passed **105 tests in 24 suites**, including 14 golden cases. Commands used temporary scratch/cache paths:

```sh
swift test --scratch-path /private/tmp/avata-transfer-swift-build --cache-path /private/tmp/avata-transfer-swift-cache
swift test --skip-build --scratch-path /private/tmp/avata-transfer-swift-build --cache-path /private/tmp/avata-transfer-swift-cache
```

The first command built the core and test bundle but failed compiling the app: `SwiftUIMacros.StateMacro` was unavailable. The second ran that newly compiled core bundle successfully. Compiler cache and test sockets required execution outside the workspace sandbox.

No full Xcode installation or SwiftUI macro plugin was found in `/Applications`, `~/Applications`, or `/Library/Developer`. Do not claim a working app build until a matching toolchain is available. Do not treat `--skip-build` as verification after test or source edits.

### Task 1: Establish independent core verification and fork packaging

**Files:** Create `scripts/test_core.sh`; modify `scripts/package_app.sh`, `Resources/Info.plist`, `Resources/es.lproj/InfoPlist.strings`, `Sources/Osmotic/App/AppLog.swift`, `Sources/Osmotic/App/Persistence.swift`, `Sources/Osmotic/Services/UpdateService.swift`, `Sources/Osmotic/Views/SettingsView.swift`, `Sources/Osmotic/App/OsmoticApp.swift`, `README.md`.

**Interfaces:** Produce `scripts/test_core.sh [Swift test arguments...]`. Produce `Preferences.pairingIdentifier: String`, persisted once as 32 lowercase hexadecimal characters. Package output is `build/Osmotic Avata.app`; keep the executable target name `Osmotic`.

- [ ] Write the core harness: create a temporary Swift package named `Osmotic`, symlink `Sources/OsmoticCore` and `Tests/OsmoticCoreTests`, and reproduce their targets and fixture resources. Forward test arguments, preserve the exit status, and clean the temporary package with a shell trap. Never compile or launch the app from this harness.
- [ ] Run `scripts/test_core.sh`. Expect all existing core tests to pass with fresh compilation. Run `scripts/test_core.sh --filter ManifestGoldenTests`; expect all 14 argument cases to pass.
- [ ] Apply the fork display/bundle/signing identity and separate log/cache/history/Keychain paths. Disable both automatic and manual upstream update installation. Add a development README section with the actual baseline and experimental hardware status.
- [ ] Check the packaged plist, signature identifier, state paths, and updater call sites against the exact global values. On a compatible toolchain, run `scripts/package_app.sh debug` and `codesign --verify --deep --strict 'build/Osmotic Avata.app'`. Until then, record packaging as unverified.
- [ ] Commit the harness and fork identity changes: `chore: isolate Avata development app and core tests`.

### Task 2: Avata discovery and drone pairing

**Files:** Modify `Sources/OsmoticCore/BLE/CameraModel.swift`, `Sources/OsmoticCore/BLE/PairingFlow.swift`, `Sources/OsmoticCore/DUML/OsmoCommands.swift`, `Sources/Osmotic/Services/BluetoothService.swift`, `Sources/Osmotic/App/AppModel+Connection.swift`, `Sources/Osmotic/Views/ConnectingView.swift`, `Resources/Localizable.xcstrings`; extend `Tests/OsmoticCoreTests/ProtocolTests.swift` and `PairingFlowTests.swift`.

**Interfaces:** Add `CameraModel.supportsMediaTransfer: Bool`, `supportsCaptureControl: Bool`, and `pairingToken: String`. Add `PairingFlow.init(bleName:savedPassword:identifier:token:)` with the existing defaults plus token default `osmo`. Avata resolves by `0x0077`, is a drone, supports experimental media, and has no capture control.

- [ ] Write tests named `avataProfileUsesDroneTransport`, `unknownDroneRemainsUnsupported`, `dronePairingUsesFlyToken`, `approvalGatesCredentialRequests`, and `cancelledPairingIgnoresScheduledWrites`. Assert ports 9003, poke false, correct length-prefixed token, same identifier on retries, no credentials before approval, and unchanged Osmo vectors.
- [ ] Run the affected core suites and confirm the added cases fail for missing Avata/token behavior.
- [ ] Implement the model profile, capability filter, and token parameter on every pairing retry. Pass the persisted identifier from Task 1. Display the two-second Avata power-button instruction only after an approval-required event.
- [ ] Redact pairing and connection logging, including BLE-name fallback and the selected device name. Keep only model ID, stage, lengths, and counters. Verify tests do not contain private observations.
- [ ] Run `scripts/test_core.sh --filter 'AdvertAndModelTests|PairingFlowTests|DumlFramingTests'`; expect no failures. Sync/localize the new UI strings and commit: `feat: discover and pair Avata 2`.

### Task 3: Drone socket and session-unlock state machine

**Files:** Modify `Sources/OsmoticCore/Datalink/DatalinkTransport.swift`; create `Sources/OsmoticCore/Drone/DroneSessionHandshake.swift`, `DroneCommands.swift`; create `Tests/OsmoticCoreTests/DroneHandshakeTests.swift`.

**Interfaces:** Extend `DatalinkTransport.init(port:interfaceName:localPort:log:)` with optional `localPort: UInt16? = nil`. Add `DroneSessionHandshake.receive(_ message: DjiMessage) throws -> [DjiMessage]`, `begin() -> [DjiMessage]`, and `isUnlocked: Bool`. Add a distinct typed unsupported-session error. Clock and deadlines are supplied by the session in Task 4.

- [ ] Write tests for optional local bind preserving camera defaults, explicit bind 9003, bind conflict, checked tunnel decoding, inner app-to-drone target `0xe9ee` and outer target `0xe93b`, serial-tag echo, increasing trailer and message counters, malformed serial/challenge, duplicate frames, and unsupported unlock. Verify the generated open packet against the Osmosis example and CRCs.
- [ ] Run `scripts/test_core.sh --filter DroneHandshakeTests`; expect failures before implementation.
- [ ] Add the explicit socket bind before handshake and close the socket on bind failure. Keep existing camera defaults unchanged. Implement only the documented Mavic `0x51` strategy with checked inner framing and the 22-byte trailer.
- [ ] Require a validated challenge/identity exchange before `isUnlocked` becomes true. Do not infer success from telemetry volume. The caller supplies a 10-second unlock deadline and cancellation; unknown Avata behavior returns unsupported-session.
- [ ] Run the handshake and existing header/framing suites. Assert no Osmo registration, playback, clock, flight, or Neo upload commands are emitted by the drone state machine. Commit: `feat: add experimental drone session negotiation`.

### Task 4: Drone listing and media-session integration boundary

**Files:** Create `Sources/OsmoticCore/Camera/MediaSession.swift`; modify `CameraSession.swift` only for conformance and `CameraFile.swift` for addressing/date fields; create `Sources/OsmoticCore/Drone/DroneMediaSession.swift`, `DroneTransferCollector.swift`, `DroneManifestDecoder.swift`; create `Tests/OsmoticCoreTests/DroneMediaTests.swift`, `FakeDrone.swift`.

**Interfaces:** `MediaSession: AnyObject, Sendable` exposes `ip`, `model`, `isClosed`, existing status/progress/link callbacks, `connect() async -> CameraSession.ConnectResult`, `nextPage() async -> (files: [CameraFile], moreAvailable: Bool)`, and `close() async`. Add `failureDescription: String?` with a default nil implementation for camera sessions. `DroneMediaSession.init(ip:model:interfaceName:log:)` implements this interface. Add `MediaAddress.path` and `.drone(index: UInt32, segment: UInt32)` to `CameraFile`, defaulting to the current path behavior, plus `recordCaptureDate: Date?`. `DroneManifestDecoder.decode(_ bytes: [UInt8]) throws -> [CameraFile]` produces these index/date fields.

- [ ] Write collector tests with split DUML frames, 16-bit lengths above 255, reordered chunks, duplicate chunks, missing chunks, incorrect request sequences, conflicting counts, 8 MiB overflow, empty final response, and truncation of a 94-byte record. Assert incomplete lists fail instead of returning partial media.
- [ ] Write fake-drone end-to-end tests for state/proceed/data/final/release, timeout, cancellation, paging overlap, nonadvancing cursor, and idempotent close. Assert release on every exit where the socket is still open, and command ordering after the validated session unlock.
- [ ] Run `scripts/test_core.sh --filter DroneMediaTests`; confirm red tests.
- [ ] Implement the collector with request sequence and chunk-index tracking. Enforce declared length/count; use a 10-second page deadline. Decode FAT timestamps, index storage/directory/file components, duration, and mapped metadata. Keep unmapped values explicit. Initial listing covers the reference's selected store; do not claim both stores.
- [ ] Implement the one-thread job queue and cancellation discipline following `CameraSession`. Expose stage-specific failure descriptions, link callbacks, and bounded receives. Keep the connection result unsuccessful if session unlock or listing fails.
- [ ] Run drone tests plus existing `ManifestGoldenTests`, `SessionEndToEndTests`, and `ControlEndToEndTests`. Expect unchanged camera behavior. Commit: `feat: browse drone media through a dedicated session`.

### Task 5: Indexed URLs, dates, and safe resumable downloads

**Files:** Modify `Sources/OsmoticCore/Camera/CameraFile.swift`, `LibraryOrder.swift`, `Sources/OsmoticCore/HTTP/ThumbnailFetcher.swift`, `FileDownloader.swift`, `Sources/Osmotic/App/Persistence.swift`, `AppModel+Library.swift`, `AppModel+Transfers.swift`; create `Sources/OsmoticCore/Drone/DroneDownloadIdentity.swift`; extend `DownloaderTests.swift`, `LibraryOrderTests.swift`, and `PathSafetyTests.swift`; create `DroneFileTests.swift`.

**Interfaces:** Consume Task 4's `MediaAddress` and `CameraFile.recordCaptureDate`. Add `DroneDownloadIdentity(device:storage:index:captureDate:totalLength:)` with a deterministic local directory and partial-file identity. URLs use unsigned decimal values through `URLComponents`.

- [ ] Write tests asserting all three drone URL parameters, original subtype 0, thumbnail/proxy subtype addressing, no Osmo storage probing, record-based dates/order, safe directories, distinct device/store/DCF namespaces, and unchanged camera URLs.
- [ ] Add fake HTTP cases for a missing still thumbnail, an error-text response with HTTP 200, conflicting Range totals, a changed item with reused index, an existing unrelated `.part`, and metadata lengths above 4 GiB. Test that an incomplete or changed item is never promoted or appended to the wrong content.
- [ ] Run new tests and confirm they fail before implementation.
- [ ] Implement index addressing and identity metadata. Use segment 0 only for the initial documented whole-file request; preserve and report unsupported segmentation when observations require a different unmapped selector. Use server lengths to validate complete content, and do not mark unknown coverage complete.
- [ ] Reuse the downloader's current range/atomic path; extend validation only for the failing cases. Persist drone partial metadata before resume, and namespace download history without changing existing camera history behavior. Use still EXIF fallback or a placeholder when thumbnails are unavailable.
- [ ] Run `scripts/test_core.sh --filter 'DroneFileTests|DownloaderTests|LibraryOrderTests|PathSafetyTests'`; expect no failures. Commit: `feat: download indexed drone originals safely`.

### Task 6: App connection, capability UI, and cleanup

**Files:** Modify `Sources/Osmotic/App/AppModel.swift`, `AppModel+Connection.swift`, `AppModel+Teardown.swift`, `AppModel+Library.swift`, `AppModel+Transfers.swift`, `AppModel+Live.swift`, `AppModel+Demo.swift`, `Sources/Osmotic/Views/CamerasView.swift`, `ConnectingView.swift`, `LibraryView.swift`, `PreviewView.swift`, `Resources/Localizable.xcstrings`; create `Tests/OsmoticCoreTests/DroneLifecycleTests.swift` for pure lifecycle/identity helpers extracted as needed.

**Interfaces:** Change stored `session` to `(any MediaSession)?`. For camera-control operations use a checked `CameraSession` cast plus `supportsCaptureControl`. Preserve object-identity guards for callbacks and every connection generation. Session factory selects `DroneMediaSession` only for the explicit supported Avata profile.

- [ ] Write lifecycle helper tests for stale device/session callbacks, cancellation at each connection stage, restoration finishing after caller cancellation, duplicate disconnect, a new connection waiting for cleanup, and downloads stopping when their session is replaced.
- [ ] Confirm added tests fail for the new drone routing or extracted lifecycle behavior, then implement only the needed boundary changes.
- [ ] Route Avata through the drone factory and indexed library path. Disable Live, shutter, recording, and sidecar operations for Avata. Surface experimental support, unverified storage coverage, approval instructions, unsupported session errors, and download completion clearly.
- [ ] Add an Avata demo screen with synthetic media for UI inspection. Keep logs redacted throughout app callbacks and failure messages. Run `scripts/sync_strings.sh` and translate the new strings.
- [ ] Run fresh core tests. With the compatible SwiftUI toolchain, run `swift build`, `scripts/lint.sh`, and debug packaging. Use the existing snapshot tooling to inspect Avata discovery, connecting, library, and unsupported-session screens. Commit: `feat: connect Avata media transfers to the Mac app`.

### Task 7: Hardware validation and status documentation

**Files:** Add `docs/AVATA_TESTING.md`; update `docs/STATUS.md`, `docs/PROTOCOL.md`, `docs/ARCHITECTURE.md`, `docs/GUIDE.md`, `README.md`, `CHANGELOG.md`.

**Interfaces:** A stage table records untested, passed, or failed for discovery, approval, credentials, Wi-Fi, UDP, session, listing, photo, video, resume, storage coverage, and restoration. Logs remain local; documentation uses sanitized model/protocol evidence.

- [ ] Run all core tests and full build/format/package checks on the available compatible toolchain; record exact results. Run `git diff --check`.
- [ ] Launch the separate app bundle through Finder. Have Alex power on the Avata nearby and perform physical pairing approval when prompted. Stop at the first unsupported stage and preserve sanitized evidence.
- [ ] When listing succeeds, download one photo and one video. Compare sizes and SHA-256 hashes with USB/card originals. Test cancellation and resumed video download, same-name files, and SD/internal coverage only where a validated selector exists.
- [ ] Verify Wi-Fi restoration after success, cancel, failure, disconnect, and quit. Mark unsupported/untested stages explicitly. If session negotiation differs, diagnose that exchange before changing the strategy; do not claim hardware compatibility or a finished transfer app.
- [ ] Commit verified status and docs: `docs: record Avata transfer validation`. Push the development branch to Alex's fork. Create no release or upstream pull request without a later request.

## Execution recommendation

Native execution is recommended: the tasks share the session/file interfaces, and the hardware findings can change the next task. Implement in this chat with focused verification after each task and a final independent code review. Await Alex's review of this plan and execution-method choice before product changes.
