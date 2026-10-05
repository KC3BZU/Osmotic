# Avata 2 wireless media transfer

Status: approved by Alex on 2026-10-05. No Avata transfer implementation yet.

## Intended outcome

Alex wants a Mac app that downloads original photos and videos from their Avata 2 wirelessly. The app will discover the drone, pair, join its Wi-Fi, browse media, and save selected files to a chosen folder. It will also offer Download New, progress, cancellation, and resume when supported by the drone's HTTP server.

The first hardware success requires downloading one photo and one video and comparing their sizes and SHA-256 hashes with copies read over USB or from the card. Bluetooth discovery alone is not transfer compatibility.

## Checkout and evidence

- Fork: https://github.com/KC3BZU/Osmotic
- Upstream: https://github.com/smithplus/Osmotic
- Starting commit: `e5c1498eb8986f4d8c0f38c3bda3c8583e90eb16`.
- Development branch: `kc3bzu/avata2-quicktransfer`.
- Local compatibility test on 2026-10-05 received Avata 2 model ID `0x0077` and service `FFF0`.
- Upstream `BluetoothService` scans broadly but discards every model classified as a drone. The observed Avata therefore never becomes selectable.
- Pairing, credential retrieval, Wi-Fi, session opening, and media transfer on this Avata remain untested.

The current Osmosis reference documents successful Mavic 3 transfers. Neo 2 reaches Wi-Fi but requires an unresolved session unlock. Avata must be tested independently.

## Approach

Extend Osmotic's native SwiftUI app. Reuse its BLE transport, Wi-Fi management, library interface, HTTP downloader, and destination handling. Add explicit Avata capabilities and a separate drone session and manifest parser.

An independent Swift app would require rebuilding permission handling, downloads, and the library UI. Porting the Android client wholesale would add unrelated platform code. The native fork offers the shortest path to a usable Mac app while keeping protocol changes testable.

## App identity

Package the development app as **Osmotic Avata**, with bundle ID `io.github.kc3bzu.osmotic-avata`. Keep upstream and Osmosis credits and MIT notices. Use separate preferences, pairing identity, logs, caches, Keychain service, and download history so both apps can coexist.

Disable the upstream updater in this build, including manual install actions. An official Osmotic release must not replace the Avata build. Changing to a fork update feed requires a later signed release workflow.

## Discovery and pairing

Add an explicit Avata 2 profile for model `0x0077`. Allow that profile through discovery and label transfer support experimental. Other drone profiles remain excluded until implemented.

Preserve the current Osmo pairing defaults. Pass a model-specific token into `PairingFlow`: `DJI FLY` for Avata, `osmo` for existing cameras. Generate and persist a 32-character pairing identifier per installation; use the same value on every retry.

Retain GATT setup for notifications on `FFF4` and `FFF5`, initialization of `FFF4`, and paced writes. When approval is requested, show the Avata instruction to hold its power button for two seconds. Wait for the approval response before requesting credentials. Never log passwords, SSIDs, serial numbers, or raw identity payloads.

## Connection and session

Use remote UDP port 9003 and bind the local socket to 9003 on the Wi-Fi interface. A port conflict produces an actionable connection error. Omit the camera TCP-7001 poke, Osmo registration, capture subscriptions, playback entry, and clock synchronization.

Add a drone session object that owns its socket on one worker thread and implements the same media operations the app needs: connect, next page, status callbacks, link loss, and close. Introduce a small media-session interface at the app boundary; the existing `CameraSession` implements it without changing its camera handshake or decoder.

Implement Osmosis's documented Mavic `0x51` tunnel as the initial experimental strategy. Decode beacons and challenge frames with checked bounds and CRCs. Echo the received serial tag internally and increment both tunnel and outer message counters. Keep serials in memory only. Success requires a valid session exchange and a media response; increased packet traffic alone is insufficient.

Use bounded deadlines and cancellation at each stage. If Avata does not answer the documented unlock, stop with an unsupported-session diagnostic. Do not replay the Neo upload sequence or probe arbitrary commands. Further adaptation requires observations from this Avata.

## Media enumeration

Implement a dedicated drone transfer collector for command `0x00/0x27`. Strip transport and routing headers and reassemble DUML frames across packets. Parse the 16-bit envelope length and final flag, request sequence, and chunk index. Enforce an 8 MiB manifest limit and validate declared count and byte length.

Reply with proceed when a pre-data state frame requests it. Release the transfer on completion, empty result, timeout, error, or cancellation while the link remains open. Missing or conflicting chunks fail the page rather than displaying a silently incomplete library.

Decode the documented 94-byte drone records separately from `ManifestDecoder`. Validate indices, sizes, timestamps, and field bounds. Preserve unknown metadata as unknown. Carry file index and storage identity into `CameraFile`; use them for stable IDs and paging. Deduplicate the overlapping boundary record and reject a nonadvancing cursor.

The initial media list covers the store selected by the documented query. SD/internal selection requires an Avata observation or a verified drone command reference before implementation. Until that evidence exists, label storage coverage unverified rather than claiming both stores are listed. Preserve the storage bits in every returned index.

## HTTP and file identity

Represent media addressing explicitly as either an Osmo path or a drone index. Drone original URLs contain all three parameters: `/v1?file_index=<u32>&file_subtype=0&file_seg_subindex=<value>`. Thumbnail and proxy URLs use the same index with their own subtype. Do not run drone files through Osmo storage probing.

Resolve segmentation from validated record information where available. The reference does not fully map the record field. Use the whole-file selector 0 only for the initial documented whole-file request and verify its response; do not invent nonzero segment values. If evidence shows segmented content cannot be reconstructed, report unsupported segmentation and preserve any partial file for diagnosis.

Reuse `FileDownloader` for Range resume, complete-length validation, safe names, and atomic completion. HTTP lengths are authoritative, including files larger than 4 GiB. Accept valid image/video payloads; reject HTML, error text, unexpected redirects, and inconsistent ranges. An unavailable thumbnail does not block the original download.

Drone filenames lack Osmotic's date-based naming. Use a destination namespace containing device identity, storage, and DCF directory so `DJI_0001` in two directories or stores cannot collide. Namespace the partial-file metadata and history by device, storage, file index, capture time, and verified total length. Resume only a matching item. Capture date comes from the drone record instead of a fabricated filename timestamp.

## UI and cleanup

Reuse Files, filters, selection, Download Selected, Download New, progress, destination chooser, and Show in Finder. Disable Live, shutter, recording, and unsupported sidecars for Avata through capabilities. Generic previews fall back to the original only when supported; unsupported previews show a clear message.

Restore the previous Wi-Fi after success, failure, cancel, disconnect, or quit. Reuse the existing independent cleanup task so cancellation cannot interrupt restoration. Stage errors distinguish discovery, approval, credentials, Wi-Fi, UDP handshake, session unlock, listing, and HTTP download. Log command IDs, counters, lengths, and timings without private payloads.

## Verification

1. Establish an upstream baseline with `swift test` and `swift build` on this Mac. Record any environment limitations separately from code failures.
2. Add Swift Testing cases before protocol changes: Avata resolution, pairing token and stable identity, approval gating, local UDP bind behavior, tunnel vectors and counters, malformed challenges, split frames, final flags, transfer release on every exit, truncated records, paging overlap, and nonadvancing cursors.
3. Test HTTP index URLs, metadata identity, same-name files across stores and directories, missing thumbnails, resumable transfers, changed content, and files above 4 GiB. Reuse and extend the existing fake HTTP server.
4. Run the existing golden decoder and camera-session suites unchanged, plus all tests, formatting, build, and `git diff --check`.
5. Package a separate debug app and launch its bundle through Finder so macOS evaluates its permissions correctly. Verify experimental labels, unavailable Live controls, and cancellation through the UI.
6. With the drone physically available, test each stage in order. Download a small photo, a video, and then an interrupted large video. Confirm hashes against originals. Verify SD/internal behavior and Wi-Fi restoration.

Record the last hardware-confirmed stage. Until both original media types pass, describe this as experimental Avata support.

## Scope

This work only offloads existing media. Firmware changes, flight controls, capture controls, cloud uploads, deletion, releases, and support for other drones are outside this design.

## References

- [Osmosis protocol, including drone session, manifest, and HTTP API](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md#dji-drone-quicktransfer-media-offload)
- [Osmotic architecture](../../ARCHITECTURE.md)
- [Osmotic agent guidance](../../../CLAUDE.md)
- [DJI Avata 2 QuickTransfer instructions](https://repair.dji.com/help/content?customId=01700011149&lang=en&paperDocType=ARTICLE&re=US&spaceId=17)
