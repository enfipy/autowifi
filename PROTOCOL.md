# Autowifi v1: minimum iPhone-to-Spark protocol

## GATT shape

Use a private 128-bit service UUID and two private 128-bit characteristic UUIDs
(replace the placeholders before an on-device test):

| Characteristic | Direction | BlueZ flags | Purpose |
|---|---|---|---|
| `credential-rx` | iPhone -> Spark | `write`, `encrypt-authenticated-write` | Framed credential payload |
| `status-tx` | Spark -> iPhone | `notify`, `encrypt-authenticated-read` | Apply result |

If `encrypt-authenticated-*` proves stricter than the pairing flow created by
AccessorySetupKit, test `encrypt-*` while keeping BlueZ Secure Connections in
`only` mode. Do not silently fall back to an unencrypted characteristic.

The advertised service UUID is also the UUID placed in the app's
`NSAccessorySetupBluetoothServices` array and its `ASDiscoveryDescriptor`.
Set `descriptor.supportedOptions` to `.bluetoothPairingLE`.

BlueZ must:

1. support LE peripheral/advertising and GATT-server roles on the chosen
   controller;
2. use Secure Connections (`SecureConnections = only` for the experiment);
3. be pairable only during an explicit setup window;
4. register a pairing agent with the Spark's real I/O capability;
5. persist the iPhone bond, then stop general discoverability;
6. reject credential writes unless the link satisfies the characteristic's
   encryption/authentication flag.

## Framing

Each message is:

```text
uint32 payload_length_be
payload_length bytes of UTF-8 JSON
```

Maximum payload length is 65,536 bytes. The iOS side splits this byte stream at
the peripheral's `maximumWriteValueLength(for: .withResponse)`. The Spark feeds
received chunks to a streaming decoder. GATT writes use responses so a failed
encrypted write or disconnect is visible to the sender.

Bluetooth link encryption supplies confidentiality and integrity. Version 1
does not add bespoke application crypto. If later threat modeling requires
end-to-end protection beyond the BLE link, version the envelope rather than
changing v1 in place.

## Credential message

`ssid` is base64 of the raw 1–32 SSID bytes; it is not assumed to be UTF-8.

```json
{
  "version": 1,
  "type": "wifi-credential",
  "requestID": "fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
  "ssid": "SG90ZWxXaUZp",
  "hidden": false,
  "security": ["wpa2", "wpa3"],
  "credential": {
    "kind": "password",
    "password": "correct horse battery staple"
  }
}
```

Allowed v1 security values are `open`, `owe`, `wpa2`, and `wpa3`. The receiver
rejects `wep`, `wpa`, enterprise credentials, unknown fields with dangerous
semantics, invalid SSID lengths, and password-bearing open networks.

Do not write the payload or decoded credential to logs. Do not pass the
password to `nmcli` on its command line because it can appear in process
inspection. Call NetworkManager's D-Bus API directly.

## Status message

The Spark notifies one status for every accepted request ID:

```json
{
  "version": 1,
  "type": "wifi-status",
  "requestID": "fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
  "state": "connected",
  "error": null
}
```

Valid states are `received`, `connecting`, `connected`, and `failed`. Error text
must be generic and must not echo secrets.

With multiple configured accessories, the extension creates one provider,
credential queue, and CoreBluetooth connection pipeline per AccessorySetupKit
Bluetooth identifier. Request IDs are scoped to their pipeline. A terminal
failure stops only that credential operation; it never cancels another
accessory's delivery. Each accessory receives credentials directly from iOS.

## Coordinated accessory removal

Removing an `ASAccessory` does not remove the corresponding BlueZ bond. The
container therefore sends `accessory-forget` over the encrypted write
characteristic before calling `ASAccessorySession.removeAccessory`:

```text
iPhone -- accessory-forget --> Spark
iPhone <-- accessory-forget-ready -- Spark
Spark schedules removal of that exact connected BlueZ peer
iPhone removes its AccessorySetupKit record
Spark enters ownerless onboarding until the first new bond
```

The Spark derives the device object path from BlueZ's encrypted GATT write
metadata; the request cannot name an arbitrary device. Bond removal is delayed
briefly so the acknowledgement can be delivered. If the acknowledgement is
not received, iOS preserves its accessory record and reports a retryable error.
An ownerless Spark remains pairable so a delayed protected iOS setup sheet
cannot race a timer; the first new owner bond closes pairing immediately. This
ordering prevents either side from silently retaining a stale bond.

## NetworkManager mapping

After validation, the Linux daemon calls
`org.freedesktop.NetworkManager.AddAndActivateConnection2` with a memory-only
profile:

```text
connection.type                 = 802-11-wireless
connection.id                   = autowifi-<request-id>
802-11-wireless.ssid            = raw SSID bytes
802-11-wireless.hidden          = payload.hidden
802-11-wireless-security.key-mgmt =
  open -> omitted
  owe -> owe
  wpa2 or wpa2+wpa3 -> wpa-psk
  wpa3 only -> sae
802-11-wireless-security.psk    = password (when applicable)
ipv4.method                     = auto
ipv6.method                     = auto
```

Only after the device reports an activated connection should the daemon send
`connected`. Autowifi does not replace an active Wi-Fi connection; the request
fails with a generic code instead. The memory profile can reconnect during the
same NetworkManager lifetime, but it is not persisted across a Spark reboot.
After boot, iOS automatic sharing is expected to deliver the current network
again over BLE.

## Minimum Swift flow

The container app performs only onboarding and authorization:

```text
AccessorySetupKit picker
  -> paired ASAccessory
  -> connect with CoreBluetooth
  -> WINetworkSharingController.requestAuthorization()
```

The Accessory Transport Extension performs delivery:

```text
accept session request
  -> activate ASAccessorySession
  -> identify its accessory
  -> connect/retrieve the paired CBPeripheral
  -> create WINetworkSharingProvider
  -> consume networkEvents
  -> map a supported Network to the v1 DTO
  -> write the framed payload to credential-rx
  -> observe status-tx
```

Apple provides the network event and its credentials. Everything from mapping
the event onward is the custom transport boundary.
