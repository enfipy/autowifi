# autowifi feasibility spike

This folder reduces Apple's Wi-Fi Infrastructure sample to the smallest useful
contract for one DGX Spark. It is a research/protocol spike, not a deployable
credential-sharing utility.

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

See [PROTOCOL.md](PROTOCOL.md) for the wire and BlueZ boundary. The small code
artifacts are:

- `ios/MinimumTransport.swift`: converts Apple's network objects into the
  stable v1 payload and frames them for GATT writes.
- `linux/autowifi_protocol.py`: dependency-free framing, validation, and
  NetworkManager settings mapping.
- `linux/test_autowifi_protocol.py`: executable contract tests.

The execution-ordered build backlog is in
[`IMPLEMENTATION_TASKS.md`](IMPLEMENTATION_TASKS.md).

Run the portable tests with:

```bash
python3 -m unittest discover -s autowifi/linux -p 'test_*.py'
```

## Honest size estimate

The happy-path experiment can plausibly fit in roughly 700–1,000 source lines.
A utility safe enough to carry around is more likely 1,000–1,600 lines once it
includes reconnects, BlueZ pairing-agent behavior, D-Bus error handling,
secret-safe logging, acknowledgements, service installation, and tests.

The first on-device gate is not LOC. It is whether a DGX Spark's Bluetooth
controller and BlueZ bond are accepted by Wi-Fi Infrastructure as Bluetooth
Secure Connections. Test that before implementing captive portals or support
for a second Spark.

## Deliberately not included

- An Xcode project or copied Apple sample. Start from Apple's official sample
  so capability configuration and extension packaging remain canonical.
- A fake BlueZ server that cannot demonstrate Secure Connections. The protocol
  module is real and tested; the GATT/advertising layer still needs an actual
  Spark for verification.
- Logging of SSIDs or credentials.
