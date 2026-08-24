# Autowifi

Autowifi securely shares the iPhone's current Wi-Fi network with one or more
headless Linux mini PCs. The iOS app uses Apple's Wi-Fi Infrastructure and
AccessorySetupKit frameworks; each PC receives credentials over an encrypted
Bluetooth LE connection and activates the network through NetworkManager.

The supported first release is intentionally narrow:

- iOS 26.2 or later;
- open, OWE, WPA2-Personal, and WPA3-Personal networks;
- one iPhone paired independently with one or more PCs;
- no WPA-Enterprise, WEP, captive-portal replay, or replacement of an already
  active Wi-Fi connection.

See [PROTOCOL.md](PROTOCOL.md) for the versioned wire protocol and BlueZ
security boundary.

## Repository layout

- `ios/App/` — SwiftUI UI and AccessorySetupKit session orchestration.
- `ios/Sources/AutoWiFiWire/` — portable framing, validation, generated
  constants, and sharing policy.
- `ios/Sources/AutoWiFiTransport/` — CoreBluetooth transport and Apple network
  conversion used by both iOS targets.
- `ios/TransportExtension/` — the Accessory Transport Extension entry point.
- `linux/autowifi_setupd.py` — BlueZ advertisement, encrypted GATT service, and
  daemon lifecycle.
- `linux/network_manager*.py` — NetworkManager activation and status reporting.
- `tests/python/` and `ios/Tests/` — protocol, policy, manifest, and adapter
  tests.
- `config/autowifi.json` — shared protocol and Bluetooth identities. Run
  `tools/generate_constants.py` after changing it.

## Verify

On a Mac with Xcode installed, run:

```bash
scripts/verify.sh
```

This checks generated files, runs the Python and Swift tests in temporary build
directories, and type-checks the iOS-only transport code against the iPhone SDK.

## Build the iOS app

Copy the local signing template and set your Apple Developer Team ID:

```bash
cp ios/Config/Signing.local.xcconfig.example \
  ios/Config/Signing.local.xcconfig
open ios/Autowifi.xcodeproj
```

The local signing file is ignored by Git. Bundle IDs and Bluetooth UUIDs are
committed because both sides depend on those identities. AccessorySetupKit's
protected setup sheet and Bluetooth transport must be tested on a physical
iPhone, not through iPhone Mirroring.

## Install a PC receiver

The receiver requires BlueZ, NetworkManager, Python 3, D-Bus Python bindings,
and root authority for unattended NetworkManager activation. From a checkout on
the PC:

```bash
sudo linux/preflight.sh
sudo scripts/install_spark.sh
systemctl status autowifi-setupd.service
```

The installer copies the receiver to `/opt/autowifi`, installs the root-owned
systemd unit, enables it for boot, and restarts it. It does not interrupt an
active NetworkManager Wi-Fi connection.

Successful NetworkManager profiles are stored on disk with autoconnect enabled,
so the PC can reconnect after reboot. A failed profile is removed. Ethernet is
left active, and Autowifi never writes SSIDs or credentials to logs or command
arguments.

## Diagnose a remote PC

The diagnostic checks the BlueZ ownership invariant without changing Bluetooth
or Wi-Fi. Set an SSH destination instead of relying on a fixed hostname or
adapter number:

```bash
AUTOWIFI_SPARK_HOST=user@enfis1 scripts/diagnose_spark.sh
```

If the SSH alias needs a separate address—for example, a ConnectX-7 link—also
set `AUTOWIFI_SPARK_HOSTNAME`:

```bash
AUTOWIFI_SPARK_HOST=user@enfis1 \
AUTOWIFI_SPARK_HOSTNAME=192.0.2.10 \
scripts/diagnose_spark.sh
```

An ownerless receiver remains pairable until its first iPhone bond succeeds.
Once owned, it stops general pairing while keeping its BLE advertisement
available for reconnects.

## Use with multiple PCs

Add each receiver separately with **Add another Spark**. New receivers are
selected by default.

- **Set sharing for selected** asks iOS for each receiver's policy sequentially.
- **Share current network with selected** processes receivers one at a time and
  waits for the app to be foreground before each iOS request.
- A global iOS failure such as foreground rejection or rate limiting stops the
  batch; a receiver-specific failure does not cancel other receivers.
- The UI reports the receiver's terminal result, including `connected`,
  `wifi-already-connected`, or the NetworkManager failure.

For an OWE-transition access point that advertises both OWE and an open
compatibility BSS, Autowifi uses the open profile proven to work across the
supported Linux NetworkManager versions. OWE-only networks remain OWE.

Use **Remove Spark** in the app rather than deleting only the iOS accessory. The
encrypted removal handshake clears that iPhone's bond on the receiver without
touching Wi-Fi, then returns the receiver to ownerless onboarding.

Credentials travel directly from the iPhone to every selected receiver; one PC
never forwards credentials to another.
