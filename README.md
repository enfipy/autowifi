# autowifi feasibility spike

This folder is implementing the smallest useful Apple Wi-Fi Infrastructure
vertical slice for one DGX Spark. It is not yet a deployable
credential-sharing utility: the current hardware-safe milestone exchanges only
a nonsecret BLE ping/pong.

## Result

The idea is feasible, but Apple's sample does **not** contain an accessory-side
protocol. Its transport-extension source says `Wireless protocol isn't
defined`, encodes the shared networks with `JSONEncoder`, and discards the
result. The BLE GATT service, framing, delivery acknowledgement, Linux pairing
agent, and NetworkManager integration are product code we must supply.

The published sample also needs two small compatibility updates for Xcode 26.6
(new iOS 26.5 transport-handler requirements and an iOS 26.4 availability
annotation). `RESEARCH.md` records the exact issue.

The minimum sensible first vertical slice is intentionally narrower than the
full framework:

- one iPhone and one DGX Spark;
- iOS/iPadOS 26.2 or later;
- open, OWE, WPA2-Personal, or WPA3-Personal networks;
- one encrypted GATT write characteristic and one encrypted notify
  characteristic;
- a length-prefixed, versioned JSON message;
- NetworkManager activation through D-Bus;
- no WPA-Enterprise and no captive-portal replay in the first slice.

See [PROTOCOL.md](PROTOCOL.md) for the wire and BlueZ boundary. The current code
artifacts are:

- `ios/Autowifi.xcodeproj`: a SwiftUI container plus Accessory Transport
  Extension, with the required capability declarations.
- `ios/MinimumTransport.swift`: converts Apple's network objects into the
  stable v1 payload and frames them for GATT writes.
- `linux/autowifi_setupd.py`: BlueZ LE advertisement/GATT registration,
  encrypted characteristics, single-owner onboarding, and the nonsecret
  ping/pong gate.
- `linux/autowifi_protocol.py`: dependency-free framing, validation, and
  NetworkManager settings mapping.
- `linux/test_autowifi_protocol.py`: executable contract tests.

The execution-ordered build backlog is in
[`IMPLEMENTATION_TASKS.md`](IMPLEMENTATION_TASKS.md).

## Module map

The project keeps orchestration thin and concentrates behavior behind small
interfaces:

- `ios/App/AccessorySessionModel.swift` coordinates AccessorySetupKit,
  WiFiInfrastructure, and the encrypted transport.
- `ios/App/AccessoryCatalog.swift` owns pre-pairing product matching and
  GIGABYTE/NVIDIA picker artwork.
- `ios/App/RemovalRecovery.swift` owns persisted post-removal recovery timing.
- `ios/Sources/AutoWiFiWire/` owns framing, validation, network mapping, and the
  reusable CoreBluetooth transport.
- `linux/autowifi_setupd.py` orchestrates the BlueZ daemon lifecycle.
- `linux/bluez_gatt.py` owns the encrypted GATT application and peer-reset
  callback.
- `linux/ownership_policy.py` is the pure single-owner onboarding policy.
- `linux/autowifi_protocol.py` owns framing, validation, and NetworkManager
  settings mapping without D-Bus dependencies.

Run the read-only Spark inventory with:

```bash
cd autowifi
sudo ./linux/preflight.sh | tee spark-preflight.txt
```

Run all portable tests, generated-file checks, and iOS SDK type-checking with:

```bash
autowifi/scripts/verify.sh
```

Before signing the iOS app, copy
`ios/Config/Signing.local.xcconfig.example` to
`ios/Config/Signing.local.xcconfig` and set your Apple Developer Team ID. The
local file is ignored by Git; bundle IDs and BLE UUIDs remain committed because
they are protocol and provisioning identities shared by both sides.

Start the daemon on a Spark with:

```bash
python3 linux/autowifi_setupd.py
```

The LE advertisement stays available for reconnects. An ownerless Spark stays
pairable until its first owner bond succeeds; an owned Spark is not pairable.
Wi-Fi and NetworkManager are not modified by this lifecycle.

The daemon derives a stable picker product identity from Linux DMI data:
GIGABYTE `AI TOP ATOM` hardware advertises `Autowifi GIGABYTE`, NVIDIA hardware
advertises `Autowifi NVIDIA`, and unknown hardware uses the generic artwork.
Use `--product gigabyte`, `--product nvidia`, or `--product generic` only when
the firmware-reported identity needs an explicit override.

Spark diagnostic scripts do not assume a hostname, IP address, user, or BlueZ
adapter number. Set `AUTOWIFI_SPARK_HOST` to an SSH target before running them;
set `AUTOWIFI_SPARK_HOSTNAME` only when that SSH target needs a separate
`HostName` override.

Use the app's **Remove Spark** action instead of removing only the iOS record.
It first performs the encrypted removal handshake documented in `PROTOCOL.md`,
then clears the iOS accessory. The Spark deletes only that connected iPhone's
bond and enters ownerless onboarding until the first replacement bond succeeds;
this operation does not touch Wi-Fi. Pairing closes immediately once an owner
exists.

After removal, the app preserves a 60-second Bluetooth recovery deadline in
`UserDefaults`. If the app relaunches while iOS is still settling the removed
AccessorySetupKit/Bluetooth record, it shows a countdown and disables **Add DGX
Spark** instead of opening a setup attempt that is likely to fail. This deadline
does not cache or recreate accessory authorization.

## Honest size estimate

The happy-path experiment can plausibly fit in roughly 700–1,000 source lines.
A utility safe enough to carry around is more likely 1,000–1,600 lines once it
includes reconnects, BlueZ pairing-agent behavior, D-Bus error handling,
secret-safe logging, acknowledgements, service installation, and tests.

The first on-device gate is not LOC. It is whether a DGX Spark's Bluetooth
controller and BlueZ bond are accepted by Wi-Fi Infrastructure as Bluetooth
Secure Connections. Test that before implementing captive portals or support
for a second Spark.

The first real shared-network attempt used `GCC`, whose access point advertises
WPA1+WPA2 transition security. Apple includes legacy `.wpa` in that network's
policy set, so the v1 mapper intentionally skips it. Use a WPA2/WPA3-only or
open test network for the credential-delivery acceptance gate; do not weaken
the protocol to WPA1 merely to make this environmental test pass.

The AccessorySetupKit picker must be tested on the physical iPhone. Its
protected system sheet does not present through iPhone Mirroring. Use the
service-UUID discovery rule from Apple's sample without the optional
`.immediate` range restriction; the Spark's controller-reported TX power made
that restriction reject an otherwise strong nearby advertisement in testing.

Run the foreground CoreBluetooth gate on the physical iPhone as well. In this
test environment, CoreBluetooth reported `poweredOff` while iPhone Mirroring
was active even though BlueZ still showed the bonded phone connected. The app
automatically starts one nonsecret encrypted ping after restoring the Spark;
the visible button retries it.

## Deliberately not included yet

- NetworkManager activation from a received credential.
- Accessory Transport Extension-to-GATT delivery.
- A systemd unit or privileged installation.
- Logging of SSIDs or credentials.
