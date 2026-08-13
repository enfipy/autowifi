# autowifi feasibility spike

This folder implements the smallest useful Apple Wi-Fi Infrastructure vertical
slice for one DGX Spark: iOS delivers a supported network over encrypted BLE,
and the Spark activates it through NetworkManager.

## Result

The idea is feasible, but Apple's sample does **not** contain an accessory-side
protocol. Its transport-extension source says `Wireless protocol isn't
defined`, encodes the shared networks with `JSONEncoder`, and discards the
result. The BLE GATT service, framing, delivery acknowledgement, Linux pairing
agent, and NetworkManager integration are product code we must supply.

The published sample also needs two small compatibility updates for Xcode 26.6
(new iOS 26.5 transport-handler requirements and an iOS 26.4 availability
annotation). `RESEARCH.md` records the exact issue.

The implemented vertical slice is intentionally narrower than the full
framework:

- one iPhone and one or more independently paired DGX Sparks;
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
- `linux/network_manager.py`: status sequencing and request idempotency.
- `linux/network_manager_dbus.py`: safe in-memory NetworkManager activation.
- `linux/test_autowifi_protocol.py`: executable contract tests.

The execution-ordered build backlog is in
[`IMPLEMENTATION_TASKS.md`](IMPLEMENTATION_TASKS.md).

## Module map

The project keeps orchestration thin and concentrates behavior behind small
interfaces:

- `ios/App/AccessorySessionModel.swift` coordinates AccessorySetupKit,
  WiFiInfrastructure, per-Spark selection, and independent encrypted transports.
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

Install and enable the daemon on a Spark with:

```bash
sudo scripts/install_spark.sh
systemctl status autowifi-setupd.service
```

When the Spark user already has systemd lingering enabled, a BLE development
daemon can be installed without root:

```bash
scripts/install_spark_user.sh
systemctl --user status autowifi-setupd.service
```

The user installer deliberately refuses to proceed unless lingering is enabled,
because otherwise "enabled" would mean login-time rather than boot-time startup.
For unattended Wi-Fi activation, use the root unit unless `nmcli general
permissions` reports `yes` (not `auth`) for NetworkManager `network-control` and
connection modification. The root installer automatically disables a user unit
before taking over.

The root systemd unit starts after Bluetooth and NetworkManager and has the
non-interactive authority needed to activate a connection. The lingering user
unit retries until those system services are ready, but remains subject to the
host's NetworkManager PolicyKit rules. Both restart after a failure and preserve
BlueZ bonds. The LE advertisement stays available for reconnects. An ownerless
Spark stays pairable until its first owner bond succeeds; an owned Spark is not
pairable.

On a credential request, Autowifi refuses to replace an already active Wi-Fi
connection. If Wi-Fi is enabled and disconnected, it creates a memory-only
profile, reports `connecting`, waits for NetworkManager state `activated`, and
then reports `connected`. A failed profile is removed. Ethernet connections are
left active. SSIDs and credentials are never written to Autowifi logs or process
arguments.

The daemon derives a stable picker product identity from Linux DMI data and
advertises a product-specific discovery service UUID. GIGABYTE reuses the
original shared service UUID for backwards compatibility; NVIDIA and generic
hardware use private discovery UUIDs. This selects the appropriate picker
artwork without cluttering the visible label or claiming a Bluetooth SIG
company allocation. The iOS picker temporarily accepts the legacy GIGABYTE
discovery UUID used by early test installs, so those Sparks remain discoverable
until their daemons are upgraded. The BLE local name is only the sanitized
machine hostname, such as `enfis1` or `enfis2`.
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

## Multiple Sparks

Add each Spark separately with **Add another Spark**. New accessories are
selected by default. The app displays independent BLE, authorization, manual
share, and removal state for every Bluetooth identifier.

- **Set sharing for selected** asks Apple for a sharing policy separately and
  sequentially for each selected Spark. Choose **Automatically Share** or **Ask
  Every Time** in each system sheet.
- **Share current network with selected** presents Apple's manual sharing flow
  separately for each selected Spark.
- **Select all** changes to **Deselect all** when every Spark is selected.
  Deselecting a Spark does not revoke an existing Automatically Share
  authorization; Apple stores that policy per accessory and it can be changed
  in Settings.

The transport extension maintains one isolated provider/BLE queue per restored
accessory. A connection or NetworkManager failure on one Spark is logged only
for that pipeline and does not cancel delivery to another. Credentials always
travel directly from the iPhone to each selected/authorized Spark; Autowifi
never forwards credentials between Sparks.

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

- Logging of SSIDs or credentials.
- Persistent Wi-Fi profiles across NetworkManager or Spark restarts. Automatic
  sharing is expected to deliver the current network again after boot.
- Replacing an already active Wi-Fi connection.
