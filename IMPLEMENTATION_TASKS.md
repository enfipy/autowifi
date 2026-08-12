# Autowifi implementation backlog

Goal: after one foreground setup, an iPhone shares a newly joined Wi-Fi
network with one DGX Spark over secure BLE, and the Spark joins that network
through NetworkManager without reopening the app.

This backlog targets a controlled WPA2/WPA3-Personal proof first. Enterprise
Wi-Fi, captive-portal replay, two-Spark orchestration, App Store distribution,
and NAT are explicitly post-MVP.

## Definition of done

The MVP is complete only when this exact test passes:

1. The iPhone and Spark have previously been paired and **Automatically Share**
   was authorized.
2. The Spark's Wi-Fi radio is on, but it has no saved profile for the test SSID.
3. `autowifi-setupd` starts at boot and reconnects to the bonded iPhone over
   BLE.
4. With the container app backgrounded and the phone locked, the iPhone joins a
   controlled WPA2/WPA3 test access point.
5. The extension sends a v1 credential message; the Spark activates an
   in-memory NetworkManager profile and returns status over BLE.
6. Within 30 seconds, the Spark has working IP, DNS, and HTTPS connectivity.
7. Neither the password, raw payload, nor SSID appears in application or
   journal logs.

Do not use `nmcli radio wifi off` for this test. BLE transfers credentials; the
Spark's Wi-Fi adapter must remain enabled to join the access point.

## Dependency order

| Order | Track | Tasks | Exit gate |
|---:|---|---|---|
| 1 | Shared | S0–S1 | Frozen UUIDs and v1 fixtures |
| 2 | Device preflight | P0–P1 | iPhone/Apple capabilities and Spark BLE roles confirmed |
| 3 | Secure BLE | L0–L2, I0–I2 | Paired/bonded iPhone exchanges nonsecret ping/ACK |
| 4 | Apple gate | I3–I4 | Authorization succeeds without `accessoryTransportNotSecured` |
| 5 | Credential path | I5, L3–L4 | Controlled credential reaches NetworkManager |
| 6 | Automation | E0–E2 | Locked-phone, no-app-open test passes |
| 7 | Operations | O0–O2 | Boot service, recovery, and redacted diagnostics work |

The iOS and Linux tasks within an order can proceed in parallel, but do not
implement real credential delivery before the secure nonsecret ping gate.

## Shared contract

### S0 — Freeze identifiers and deployment baseline

Status: **complete**. The source of truth is `config/autowifi.json`; generated
Swift and Python constants are checked by `scripts/verify.sh`.

Deliverables:

- Choose one private 128-bit service UUID, credential-RX UUID, and status-TX
  UUID.
- Store them once in a machine-readable source of truth and generate or mirror
  Swift/Python constants from it.
- Choose the container and extension bundle IDs; suggested starting values are
  `com.enfipy.autowifi` and `com.enfipy.autowifi.transport`.
- Set the minimum deployment target to iOS 26.2. Guard APIs introduced in 26.4
  or 26.5 instead of silently raising the whole target.
- Record the Apple development team identifier outside source control if it is
  personal configuration.

Acceptance:

- The same UUID bytes appear in the iOS discovery descriptor, iOS GATT code,
  BlueZ advertisement, BlueZ service, and protocol fixtures.
- No placeholder UUID or Apple sample dice UUID remains in a build target.

### S1 — Make the wire contract executable on both platforms

Status: **complete**. Shared fixtures are under `fixtures/`; Swift and Python
tests consume them and verify encoding, validation, framing, and status
transitions.

Deliverables:

- Keep `PROTOCOL.md` as the v1 specification.
- Add nonsecret JSON fixtures for open, OWE, WPA2, WPA3, malformed length,
  unsupported security, and status ACK/failure.
- Add Swift encode tests and Python decode tests against the same fixture
  bytes, including binary SSIDs.
- Define the status state machine: `received -> connecting -> connected` or
  `received -> connecting -> failed`.
- Define idempotency by `requestID`: replaying the same request may retry or
  return the prior status, but must not create duplicate profiles.

Acceptance:

- Swift-produced fixture bytes decode in Python.
- Fragmented and coalesced frames round-trip.
- Payloads over 65,536 bytes and unsupported credential types are rejected.

## Device and account preflight

### P0 — Confirm the iPhone and signing account

Status: **complete**. The iPhone 16 Pro runs iOS 26.6.1 with Developer Mode,
is registered in the paid developer team, and has matching development
profiles. Signed container and extension builds contain the expected
entitlements; the app installs and launches on the physical phone.

Deliverables:

- Confirm the physical iPhone runs iOS 26.2 or later.
- In Xcode, confirm the paid development team can add the Wi-Fi Infrastructure
  capability to an app target and sign the Accessory Transport Extension.
- Install a blank development build on the phone.
- Record whether development/testing outside the EU reaches the framework as
  Apple documents; do not attempt to bypass a customer-region gate.

Acceptance:

- The container and extension signatures contain their expected entitlements.
- The app launches on the physical iPhone without provisioning errors.

Useful verification after building:

```bash
codesign -d --entitlements :- '<path-to-built-app>'
codesign -d --entitlements :- '<path-to-built-extension>'
```

### P1 — Confirm the Spark's actual Bluetooth and NetworkManager capabilities

Status: **complete** on `enfis1`. BlueZ 5.72 exposes LE peripheral,
advertising, GATT-manager, and Secure Connections support on `/org/bluez/hci0`.
NetworkManager 1.46 owns Wi-Fi device path
`/org/freedesktop/NetworkManager/Devices/14`; the OS-provided Python D-Bus and
GLib bindings are present.

Copy the `autowifi` folder to the target Spark and run the read-only collector
while retaining Ethernet or local-console access:

```bash
sudo ./linux/preflight.sh | tee spark-preflight.txt
```

The script makes no changes. Review `spark-preflight.txt` before sharing it;
the NetworkManager section contains device names and states but intentionally
does not request Wi-Fi SSIDs or addresses.

Deliverables:

- Record the Bluetooth adapter path and whether it supports LE, advertising,
  Secure Connections, GATT server, and persistent bonding.
- Identify the Wi-Fi NetworkManager device by D-Bus object path rather than
  assuming it is named `wlan0`.
- Choose the system D-Bus binding already supportable on DGX OS. Prefer an OS
  package over an unpinned `pip install`; keep the protocol module independent
  of that binding.
- Capture BlueZ and NetworkManager versions for the test report.

Acceptance:

- Both BlueZ manager interfaces are present on a usable adapter.
- NetworkManager owns the intended Wi-Fi device.
- A supported Python D-Bus binding is available or has an explicit packaged
  dependency.

## Spark: secure BLE transport

### L0 — Build the daemon skeleton and D-Bus object tree

Status: **complete** on `enfis1`. Registration, advertisement, daemon
operation, clean shutdown, and start/stop/restart cleanup were exercised
against the real BlueZ controller without changing Wi-Fi.

Deliverables under `linux/`:

- `autowifi_setupd.py` with a single async/process lifecycle and clean SIGTERM.
- BlueZ ObjectManager root, one `GattService1`, credential-RX
  `GattCharacteristic1`, status-TX `GattCharacteristic1`, and one
  `LEAdvertisement1`.
- Registration through `GattManager1.RegisterApplication` and
  `LEAdvertisingManager1.RegisterAdvertisement`.
- No NetworkManager mutation yet. A credential write feeds only the bounded
  frame decoder and returns a nonsecret test status.
- Explicit startup failures if the adapter or required managers are absent.

Acceptance:

- `bluetoothctl` on another device sees the chosen device name and service.
- BlueZ introspection shows the service and two characteristics.
- Start/stop/restart does not leave a duplicate advertisement or registration.

### L1 — Add owner onboarding, bonding, and Secure Connections policy

Status: **in progress**. The `NoInputNoOutput` agent, owner-based onboarding,
automatic pairability close, encrypted RX/TX characteristic flags, and clean
adapter restoration are implemented and exercised on `enfis1`. A physical
iPhone completed AccessorySetupKit setup and is paired, bonded, connected, and
service-resolved in BlueZ; pairing was then disabled without dropping the
connection or advertisement. BlueZ's
`Adapter1.Discoverable` mode remains off; BLE discovery is provided by the LE
service advertisement because this controller returns `Busy` if adapter mode
is toggled while an advertisement is active. Reconnect, unpaired-write, and
Secure-Connections-only acceptance gates remain.

Deliverables:

- An ownerless device remains pairable until its first bond; a bonded device is
  not pairable but keeps advertising for authorized reconnects.
- A BlueZ pairing agent whose I/O capability matches the Spark's real setup.
  Start with `NoInputNoOutput`; retain a documented passkey/confirmation test
  variant if Apple rejects that bond.
- Set discoverable/pairable only during onboarding; disable both afterward.
- Configure the experiment for `SecureConnections = only` and verify the
  controller applies it. Preserve BlueZ's persistent bond database.
- Restrict credential writes to an encrypted link. Test the documented
  `encrypt-authenticated-*` characteristic flags first; if the headless pairing
  method cannot satisfy them, test `encrypt-*` while retaining Secure
  Connections-only controller policy and record the result.

Acceptance:

- The iPhone becomes both paired and bonded in BlueZ.
- Reconnecting does not prompt for pairing again.
- An unpaired client cannot write the credential characteristic.
- Pairing is unavailable after the setup window closes.

### L2 — Implement framing, status notification, and safe session behavior

Deliverables:

- Feed arbitrary GATT write chunks into `FrameDecoder`.
- Enforce one bounded in-progress frame per connected peer and clear partial
  state on disconnect.
- Validate the v1 request before emitting `received`.
- Enable status notifications and encode the status DTO without including an
  SSID or credential.
- Add request-ID idempotency and a small bounded cache of recent results.
- Ensure exceptions and debug representations never contain the payload.

Acceptance:

- A synthetic frame split at every possible byte boundary is accepted once.
- Malformed and oversize frames produce a generic failure or disconnect.
- Replaying a request ID does not create repeated side effects.
- Journal output remains credential- and SSID-free.

## iOS: container app and extension

### I0 — Create the signed Xcode project from Apple's packaging shape

Status: **complete**. Both targets and current/legacy SDK callbacks compile.
The paid-team development build signs with the required entitlements, installs
on the registered iPhone, and launches through CoreDevice.

Deliverables under `ios/`:

- One SwiftUI container target and one Accessory Transport Extension target.
- Use Apple's official Wi-Fi-sharing sample as the packaging reference and
  preserve any copied source license notice.
- Apply current SDK compatibility: implement the iOS 26.5 transport handler
  requirements and correctly guard iOS 26.4 APIs.
- Container entitlement:

  ```text
  com.apple.developer.wifi-infrastructure = [WiFiNetworkSharing]
  ```

- Extension entitlements:

  ```text
  com.apple.developer.wifi-infrastructure = [WiFiNetworkSharing]
  com.apple.developer.accessory-transport-extension = true
  ```

- Container `Info.plist` declares Bluetooth AccessorySetupKit support and the
  Autowifi service UUID. Extension `Info.plist` declares
  `com.apple.accessory-transport-extension`.

Acceptance:

- Both targets compile with warnings treated as errors.
- A no-signing generic-device CI build succeeds.
- A development-signed build installs and launches on the iPhone.

### I1 — Implement minimal onboarding UI

Status: **in progress**. The physical picker discovers `enfis1` and setup
creates the expected persistent BlueZ bond. The working descriptor matches
Apple's current sample: service UUID plus `.bluetoothPairingLE`, without an
`.immediate` range restriction. iPhone Mirroring cannot present the protected
AccessorySetupKit sheet and is not a valid discovery test surface. Relaunch
restore and remove/re-pair remain to verify.

The container needs only four visible states: no Spark, pairing, paired but not
authorized, and ready. Add a diagnostics sheet showing redacted state and error
codes, never SSIDs or credentials.

Deliverables:

- Activate `ASAccessorySession` and restore already authorized accessories.
- Present one `ASPickerDisplayItem` matching the service UUID, immediate range,
  and `.bluetoothPairingLE`.
- Handle add/change/remove/invalidation events.
- Retrieve the selected `CBPeripheral` by the AccessorySetupKit Bluetooth
  identifier.
- Provide Remove Spark and Retry Pairing actions.

Acceptance:

- The picker shows only the advertising Spark.
- Selecting it creates the expected AccessorySetupKit record and BlueZ bond.
- Relaunching restores the same Spark without another picker.
- Removing it clears authorization on iOS and permits a clean re-pair.

### I2 — Prove encrypted BLE with a nonsecret ping/ACK

Status: **complete**. The physical iPhone restored the AccessorySetupKit bond
and completed a framed encrypted GATT ping/pong against `enfis1` in 92 ms. The
Spark acknowledged the request without reopening pairing. The transport waits
through CoreBluetooth's observed transient `poweredOff -> poweredOn` startup
sequence instead of treating the first callback as terminal.

Deliverables:

- A small reusable CoreBluetooth transport state machine: disconnected,
  connecting, discovering, ready, sending, and failed.
- Discover only the Autowifi service and two characteristics.
- Subscribe to status-TX before sending.
- Chunk a framed synthetic ping using
  `maximumWriteValueLength(for: .withResponse)` and serialize writes through
  `didWriteValueFor`.
- Reassemble and validate the status notification.
- Cancel continuations/tasks on disconnect and use a bounded retry policy.

Acceptance:

- The container app sends 1-byte, MTU-boundary, and multi-chunk synthetic
  messages and receives matching request-ID acknowledgements.
- Unencrypted access fails; the paired encrypted path succeeds.
- Power-cycling Bluetooth produces a bounded reconnect rather than a hung task.

This is the secure BLE gate. Do not send Apple credential objects until it
passes on the real Spark.

### I3 — Implement the Accessory Transport Extension lifecycle

Status: **complete**. The proven GATT probe is shared by both targets. The
extension retains its transport session, activates an extension-local
AccessorySetupKit session, requires exactly one configured MVP accessory, and
runs an extension-originated encrypted ping with bounded cleanup. Apple
launched the extension during authorization and `enfis1` acknowledged its
second encrypted ping.

Deliverables:

- Accept `AccessoryTransportSession.Request` and retain a per-session handler.
- Activate an extension-local `ASAccessorySession` and select the accessory
  belonging to that session; do not blindly assume multiple future accessories
  can always use `.first`.
- Retrieve/connect the bonded peripheral and reuse the tested GATT transport.
- Implement current `sessionInvalidated` and message callbacks, cancelling all
  work promptly on invalidation.
- Send a nonsecret extension-started ping before creating a network provider.

Acceptance:

- A transport session starts the extension and produces a ping/ACK from the
  extension process, not the foreground container app.
- Locking the phone does not break an already established test exchange.
- Repeated extension launch/invalidation leaves no duplicated tasks.

### I4 — Pass Apple's Wi-Fi-sharing authorization security gate

Status: **complete for Ask Every Time**. Apple accepted the accessory transport
without `accessoryTransportNotSecured`, displayed all three sharing modes, and
the user selected Ask Every Time. iOS then offered the current Wi-Fi network
for sharing. Automatic mode remains a user-selectable follow-up, not a code
blocker.

Deliverables:

- After the peripheral is connected and encrypted, construct
  `WINetworkSharingController(for:)` in the container and call
  `requestAuthorization()`.
- Display the returned state: undetermined, denied, ask-to-share, or automatic.
- Select **Automatically Share** for the MVP test.
- Map and display `WINetworkSharingError` cases without logging accessory or
  network data.
- Record the BlueZ security/pairing configuration used for every attempt.

Acceptance:

- Authorization returns `.automatic` on the physical iPhone and real Spark.
- It does not return `accessoryTransportNotSecured`.
- If it does, stop feature work and test the planned BlueZ agent/characteristic
  security variants; this is a formal blocker, not an error to suppress.

### I5 — Forward supported Apple network events

Status: **in progress**. The extension starts a
`WINetworkSharingProvider` only after its encrypted ping succeeds, maps only
the supported v1 network types, serializes credential transfers, and requires
a matching `received` status from the Spark. The current Spark milestone
validates and acknowledges the credential but deliberately does not mutate
NetworkManager. The first live network, `GCC`, advertises WPA1+WPA2; Apple
therefore reports the intentionally unsupported legacy `.wpa` policy and the
mapper correctly skips it. Live acceptance remains to test against a
WPA2/WPA3-only or open network.

Deliverables:

- Create one `WINetworkSharingProvider` for the authorized accessory inside the
  extension and consume `networkEvents`.
- For automatic authorization, forward newly shared networks without
  unnecessarily presenting ask-to-share UI.
- Use `MinimumTransport.swift` to convert only open, OWE, WPA2-Personal, and
  WPA3-Personal objects into the stable v1 DTO.
- Queue one request at a time until a matching status is received or a bounded
  timeout occurs.
- Deduplicate provider updates so the same network event is not transmitted
  repeatedly.
- Never print `Network.description`, the encoded DTO, SSID, or credentials.

Acceptance:

- A controlled Apple network event produces one correctly framed GATT request.
- Unsupported WEP/WPA1/Enterprise data is rejected locally with a redacted
  diagnostic.
- Disconnecting mid-transfer retries without duplicating a completed request.

## Spark: NetworkManager activation

### L3 — Implement the direct NetworkManager D-Bus adapter

Deliverables:

- Resolve the target Wi-Fi device from NetworkManager properties.
- Convert `networkmanager_settings()` into the D-Bus `a{sa{sv}}` variant map.
- Call `AddAndActivateConnection2` directly; never put the PSK in an `nmcli`
  command or process arguments.
- Use an in-memory/volatile profile for the first test.
- Observe active-connection state until activated, failed, or timed out.
- Map open, OWE, WPA2/WPA3 transition, and WPA3-only settings as specified.

Acceptance:

- A local non-BLE test fixture activates the controlled access point.
- The password is absent from `ps`, command history, stdout/stderr, and journal.
- A bad password returns generic `failed`; it does not crash or loop forever.

### L4 — Join Wi-Fi and return end-to-end status

Deliverables:

- On valid BLE input, emit `received`, then call the NetworkManager adapter and
  emit `connecting` followed by `connected` or `failed`.
- Confirm activated IP configuration and default route before `connected`.
- Decide whether replacing an existing Wi-Fi connection is permitted. For MVP,
  require an explicit configuration flag and preserve Ethernet access.
- Zero/delete transient credential references as far as Python permits and
  avoid retaining decoded requests after completion.

Acceptance:

- One BLE request activates the controlled AP and returns `connected` with the
  same request ID.
- Failure preserves the daemon, BLE bond, and diagnostic access.
- Replaying the request is idempotent.

## End-to-end tests

### E0 — Controlled foreground credential test

Setup:

- Use a temporary WPA2/WPA3 access point and password created for this test.
- Keep Spark Ethernet/local-console access.
- Keep Spark Wi-Fi enabled, disconnect it, and delete any profile for the SSID.
- Keep the iOS app foregrounded for this first run.

Acceptance:

- Pair, authorize, share, activate, and ACK work end to end.
- `nmcli connection show --active`, DNS lookup, and HTTPS access succeed.
- The Spark did not know the network before the BLE delivery.

### E1 — Automatic locked-phone test

Setup:

1. Complete pairing and `.automatic` authorization once.
2. Background the app and lock the iPhone; do not force-quit it for the first
   background test.
3. Delete the Spark's test Wi-Fi profile and disconnect Wi-Fi while leaving the
   radio on.
4. Join a second controlled network on the iPhone.

Acceptance:

- The system launches the extension, BLE reconnects, and the Spark joins within
  30 seconds without reopening the app.
- Repeat after the Spark daemon restarts.
- Separately record behavior after force-quitting the container app; do not
  assume iOS treats force-quit like ordinary backgrounding.

### E2 — Failure and recovery matrix

Test at least:

- iPhone out of BLE range, then returns;
- Spark reboots;
- iPhone Bluetooth toggled off/on;
- Wi-Fi password wrong or changed;
- GATT transfer interrupted at every chunk;
- duplicate request ID;
- denied Wi-Fi-sharing authorization;
- bond removed on only one side;
- no matching access point;
- NetworkManager unavailable and then restarted.

Acceptance:

- No infinite retry loops, duplicate profiles, leaked onboarding state, or
  credential-bearing logs.
- The UI provides one clear recovery action: retry, reauthorize, or remove and
  re-pair.

## Operations and packaging

### O0 — Install as a systemd service

Deliverables:

- `autowifi-setupd.service` with explicit Python path, working directory,
  restart policy, timeouts, and dependencies on Bluetooth and NetworkManager.
- An install script or Debian package that installs code, D-Bus/PolicyKit rules
  if needed, service unit, and configuration without overwriting unrelated
  BlueZ settings.
- On boot, automatically open onboarding only when no bonded owner exists and
  close it immediately after the first bond.

Acceptance:

- A clean Spark boot starts the daemon and reconnects to an existing bond.
- Stop/start/reinstall preserves the bond unless an explicit reset is invoked.

### O1 — Harden privileges and secret handling

Deliverables:

- Prototype as root only if required to pass the hardware gate; then replace
  broad privilege with a dedicated service account and narrowly scoped D-Bus /
  PolicyKit permissions where the platform permits.
- Disable debug payload logging, core dumps containing credentials where
  practical, and unbounded journal output.
- Add redaction tests for every exception and status path.
- Restrict configuration and state file permissions.

Acceptance:

- A repository-wide and journal search using the temporary test password finds
  no occurrence after a complete successful and failed run.
- The service cannot perform unrelated NetworkManager or filesystem changes.

### O2 — Write the operator runbook

Document:

- prerequisites and supported iOS/DGX OS versions;
- Xcode signing and phone installation;
- service installation and pairing-window command;
- first pairing and automatic authorization;
- how to confirm BLE bond, daemon state, and NetworkManager activation without
  exposing credentials;
- remove/re-pair and full reset procedures;
- controlled rollback that leaves Ethernet untouched;
- known limitation: arbitrary captive portals are not part of MVP.

Acceptance:

- A fresh Spark and iPhone can be configured using only the runbook.

## Post-MVP tasks

- Persist successful NetworkManager profiles only after defining retention and
  deletion behavior.
- Test captive-portal form metadata against specific controlled portals; do not
  promise generic replay.
- Add WPA-Enterprise only with a dedicated credential and certificate threat
  model.
- Pair a second Spark directly and repeat the complete authorization flow.
- Alternatively route Spark 2 through Spark 1 without forwarding Apple's
  credential payload.
- Prepare TestFlight/App Store distribution only after confirming entitlement
  and EU customer behavior with the intended distribution profile.
