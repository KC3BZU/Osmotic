# Avata 2 validation

This development fork derives from [Osmotic](https://github.com/smithplus/Osmotic) and [Osmosis](https://github.com/KonradIT/osmosis). It is experimental. Upstream camera hardware results do not establish Avata compatibility.

## Evidence as of 2026-10-05

| Stage | Result | Evidence or limit |
| --- | --- | --- |
| BLE discovery | Passed on Avata 2 | Model `0x0077`, FFF0 service |
| Physical approval | Passed on Avata 2 | DJI Fly pairing request, aircraft power-button approval |
| BLE Wi-Fi credentials | Passed on Avata 2 | SSID/password received; secrets excluded from logs and Git |
| Automatic internet restoration | Passed smoke test | Watchdog terminated runner, fallback cycled Wi-Fi, HTTPS verified through en0 |
| Aircraft Wi-Fi / HTTP | Passed on Avata 2 | CoreWLAN association, HTTP reachability and route through en0; one intermittent join timeout |
| UDP transport | Passed on Avata 2 | UDP 9003 handshake and CRC-valid aircraft identity beacons |
| Media session open | Failed on tested Avata 2 | Both documented Mavic and Mini opens ignored; identity beacons continue without a challenge |
| DJI Fly reference | User confirmed | Media thumbnails appear on the iPhone; Mac catalogue comparison awaits unlocked Mac |
| Media listing | Loopback only | Split datagrams, ordering, deduplication, timeout and retryable page failure covered |
| Original photo/video | HTTP fixture only | No Avata original has been downloaded or compared with USB/card |
| Cancel and resume | HTTP fixture only | Identity, validated totals, ranges and incomplete files covered |
| SD/internal storage coverage | Unverified | Lists selected storage; no unvalidated storage-selection commands |
| Full native SwiftUI app | Unverified | Installed Command Line Tools lack SwiftUIMacros.StateMacro |

`./scripts/test_core.sh` passes 131 tests in 31 suites. `./scripts/build_probe.sh` builds and ad-hoc signs the separate AppKit runner. Formatting and syntax checks do not replace full SwiftUI compilation or hardware tests.

## Autonomous test workflow

The Mac must join the aircraft Wi-Fi access point to read originals. On a Mac with one Wi-Fi adapter, internet access pauses during that connection. The runner operates locally; the independent watchdog survives its exit and restores connectivity on completion, failure or a 120-second deadline. Code and test instructions are prepared before switching networks.

Build once, then use that exact executable for recovery and live testing. Rebuilding invalidates the recovery proof. Keep the runner and private state in a mode-700 directory under `/private/tmp` to avoid Documents access prompts. Copying the identical built bundle preserves its executable hash. Store only the return SSID in a mode-600 file; do not export its password. macOS uses its saved network credentials.

```sh
scripts/build_probe.sh
mkdir -m 700 /private/tmp/avata-test
cp -R build/AvataProbe.app /private/tmp/avata-test/
# Create /private/tmp/avata-test/return-network privately, with your exact saved SSID.
chmod 600 /private/tmp/avata-test/return-network
open -n /private/tmp/avata-test/AvataProbe.app --args --mode recovery-test \
  --run-directory /private/tmp/avata-test/recovery \
  --return-network-file /private/tmp/avata-test/return-network
```

Wait for `recovery/recovery.status` to say `restored` and `recovery/recovery.proof` to exist. A failed or absent proof leaves live mode online. The watchdog terminates only the matching runner PID, bundle path and launch time, bounds its recovery helper, and verifies HTTPS connectivity through the Wi-Fi interface. If direct saved-network association fails, it cycles Wi-Fi and lets macOS autojoin its known network. It removes only an aircraft network newly introduced by the run.

```sh
open -n /private/tmp/avata-test/AvataProbe.app --args --mode live \
  --run-directory /private/tmp/avata-test/live \
  --return-network-file /private/tmp/avata-test/return-network \
  --recovery-proof-file /private/tmp/avata-test/recovery/recovery.proof
```

Grant Bluetooth, Local Network and Location when requested. First pairing may require holding the aircraft power button for two seconds. The runner downloads the smallest listed photo and video, records SHA-256 hashes locally, and requests restoration. Large clips may exceed the two-minute diagnostic window. That window is for hardware validation, not a production transfer limit.

Review `report.log`, `recovery.status` and downloaded originals locally. Compare file sizes and hashes with USB/card originals before calling transfers verified. Exercise cancel, failure, disconnect and quit separately; a recovery smoke test does not prove every path.

## Protocol limits

The normal implemented path uses the persisted installation identity, the DJI Fly BLE token, UDP 9003, the drone session tunnel and indexed `/v1` HTTP originals. The manifest decoder accepts only documented 67-byte and 94-byte record layouts. Unknown layouts and unsupported session stages fail explicitly. Raw FAT capture timestamps stabilize download identity across calendar and timezone changes.

The drone transport currently stops at tunnel-counter exhaustion rather than guessing wrap behavior. Listing failures preserve pagination and surface an error; they never announce that the entire library is complete. Resume metadata binds a partial file to its device, storage, DCF index, capture timestamp and validated server total. A conflicting response discards the partial instead of promoting it to an original.

## Current session blocker

Live tests on 2026-10-05 passed BLE re-pairing, credentials, Wi-Fi/HTTP and UDP. The Avata emits 137-byte transport-type-1 datagrams containing an outer `0x51/0x01` and inner `0x51/0x13` beacon. It sends no challenge to either the Mavic open or the separately documented Mini open. Both waits terminate explicitly; automatic internet restoration passed after each session failure.

The Mini fallback is sent once after ten seconds without a challenge, with a further five-second limit. Receiving a challenge disables fallback. Its fixture test failed before implementation and passes now. The request formats come from [Osmosis DroneSession at 6992036](https://github.com/KonradIT/osmosis/blob/6992036abc29a01126a728443f1d29a83a7ef467/app/src/main/java/dev/konraditurbe/osmosis/drone/DroneSession.kt).

The runner accepts an explicitly diagnostic `--probe-existing-media` flag for a comparison after DJI Fly has opened the aircraft. It performs the UDP handshake and a read-only catalogue query, without sending identity beacons or session-open requests. Production `connect()` still requires the mutual identity exchange. A valid catalogue in this diagnostic mode proves access to that catalogue, not a successful standalone initialization.

Keep the Mac unlocked and its lid open for radio/permission checks. The runner prevents display and system idle sleep while the test is active, and releases that assertion when it finishes. This does not change authentication or lock settings. If the Mac was already locked, it must first be unlocked manually.
