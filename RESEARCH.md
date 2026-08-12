# Autowifi feasibility research

Research date: 2026-08-12. Sources are first-party Apple, BlueZ,
NetworkManager, and NVIDIA documentation and source only.

## Bottom line

The proposed iPhone-to-DGX-Spark flow is technically plausible, and Apple is
explicit that Wi-Fi Infrastructure is intended for traveling accessories that
need credentials for networks the iPhone joins. The practical target is an
iPhone or iPad on 26.2 or later, an AccessorySetupKit-paired BLE accessory, an
Accessory Transport Extension, and a Bluetooth Secure Connections link.
[Apple's framework overview](https://developer.apple.com/documentation/wifiinfrastructure)
and [official sample](https://developer.apple.com/documentation/wifiinfrastructure/sharing-wi-fi-network-credentials)
support that conclusion.

The important qualification is that Apple's sample is not an end-to-end
accessory implementation. It exposes `WINetworkSharingProvider.Network` values
inside the extension and shows that they can be JSON-encoded, but it does not
connect the extension to the simulated accessory or write the encoded bytes.
Its source explicitly says that the wireless protocol is not defined. Thus a
minimal Swift + BlueZ implementation can be designed, but it cannot be copied
or fully derived from an Apple accessory protocol because Apple has not
published one. The first real-device spike must prove that the Spark's BlueZ
bond satisfies iOS's `accessoryTransportNotSecured` check.

## What Apple documents

### Availability, region, and accounts

- Wi-Fi Infrastructure and Apple's sample require iOS/iPadOS 26.2 or later;
  the sample also requires physical devices and an Apple Developer account.
  Simulator is not supported. See
  [Sharing Wi-Fi network credentials](https://developer.apple.com/documentation/wifiinfrastructure/sharing-wi-fi-network-credentials).
- The Accessory Transport Extension framework says customer installations work
  only when the device is physically in the EU and signed into an Apple Account
  whose country or region is in the EU. Development and testing are allowed on
  devices in any region. It also says the framework is iOS-only and ignores
  Mac Catalyst and iOS apps running on visionOS or Apple-silicon Macs. See
  [Accessory Transport Extension](https://developer.apple.com/documentation/accessorytransportextension).
- Therefore a development-signed prototype can be exercised in Dubai, but that
  does not demonstrate the customer-mode region gate. The exact public wording
  is "Apple Account with an EU country or region," not merely an inferred
  billing-address rule.

### Capabilities and entitlements

The minimum signed targets are:

| Target | Required configuration |
|---|---|
| Container app | `com.apple.developer.wifi-infrastructure = [WiFiNetworkSharing]`; AccessorySetupKit Bluetooth declarations in `Info.plist` |
| Accessory Transport Extension | `com.apple.developer.wifi-infrastructure = [WiFiNetworkSharing]`; `com.apple.developer.accessory-transport-extension = true`; extension point `com.apple.accessory-transport-extension` |

Apple says to add Wi-Fi Infrastructure as an ordinary Xcode capability, and
the transport-extension entitlement is a Boolean in the extension signature.
See the
[Wi-Fi Infrastructure entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-infrastructure),
[transport-extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-transport-extension),
and [provider requirements](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider).

I found no documented MFi prerequisite for this flow. AccessorySetupKit's
documented Bluetooth discovery path accepts a custom advertised service UUID,
name, or company identifier, and Apple's Wi-Fi sample lists an Apple Developer
account rather than MFi membership. See
[Discovering and configuring accessories](https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories).
This is an absence-of-requirement finding, not a guarantee about future App
Review or hardware-program policy.

An `AccessoryTransportSecurity` extension and its separate entitlement are
documented for encrypted notification forwarding. They are not present in the
official Wi-Fi-sharing sample and are not listed as a Wi-Fi-sharing
prerequisite. For Wi-Fi credentials, the security boundary is the authorized,
secure BLE transport. See
[AccessoryTransportAppExtension](https://developer.apple.com/documentation/accessorytransportextension/accessorytransportappextension).

### Authorization and background behavior

`WINetworkSharingController.requestAuthorization()` offers exactly three user
choices:

- Automatically Share: iOS sends new networks when it joins them while the
  accessory is connected.
- Ask Every Time: the extension receives a
  `newShareableNetworkAvailable` event and may present system sharing UI.
- Don't Share: no networks are shared.

See
[`requestAuthorization()`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingcontroller/requestauthorization%28%29).
For Automatically Share, Apple says future provider events receive the new
network without another UI call. For a newly available network, the extension
may present the picker while the container app is not in the foreground. See
[`presentAskToShareUI`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider/presentasktoshareui%28scanprovider%3A%29).
The transport framework says the system invokes the extension when it is ready
to start a transport session. Together, these support the proposed no-app-open
happy path, provided BLE is connected and the extension implements its missing
transport/reconnection logic.

### Credential model

`WINetworkSharingProvider.Network` is `Codable` and includes SSID, whether the
SSID is broadcast, one or more security policies, credentials, optional captive
portal data, and timestamps. The documented security policies are open, OWE,
WEP, WPA, WPA2, and WPA3. Credentials can be none, a password, or detailed EAP
enterprise credentials. See
[`Network`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider/network),
[`Credentials`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider/network/credentials-swift.enum),
and [`SecurityPolicy`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider/network/securitypolicy-swift.enum).

The captive-portal object is narrower than a general browser session. It
contains a `[String: String]` dictionary in which each key is a CSS selector
for an HTML element and the value is what the user entered. Apple says it can
be empty because the form was empty, data expired, or the user removed it. The
API does not document cookies, JavaScript state, a submission URL, or a generic
portal-replay engine. See
[`userEnteredFormValues`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingprovider/network/captiveportallogin-swift.struct/userenteredformvalues).
Consequently, captive portal replay should be a later experiment, not part of
the minimum utility.

### Security and use restrictions

Apple requires the accessory to be paired and use Bluetooth Secure
Connections as defined in Bluetooth 4.2, including Secure Simple Pairing and
AES-128 encryption for all data. Authorization fails with
`accessoryTransportNotSecured` when the link does not meet the requirement.
See the
[Wi-Fi Infrastructure entitlement's Transport Security section](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-infrastructure)
and [`accessoryTransportNotSecured`](https://developer.apple.com/documentation/wifiinfrastructure/winetworksharingerror/accessorytransportnotsecured).

The public API documentation does not say that numeric comparison, a passkey,
or some other MITM-authenticated pairing method is mandatory. Apple's sample
requests `.bluetoothPairingLE` and forces an encrypted characteristic access;
it does not demonstrate a passkey UI. Therefore "authenticated pairing" is too
specific as an API claim. The Developer Program License Agreement separately
requires direct, secure, authenticated, end-to-end encrypted delivery to the
authorized target accessory. This is a compliance requirement even where the
API's precise link acceptance test remains opaque. See the
[Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/).

The same agreement prohibits an authorized target accessory from sharing any
Wi-Fi Network Sharing Information with another device, including another
authorized target accessory. Two Sparks should therefore either be separately
paired and separately authorized, or only one Spark should receive credentials
and provide routed connectivity to the other without forwarding Apple's
credential data.

## What the official sample actually proves

Inspection of Apple's downloadable `SharingWiFiNetworkCredentials.zip` shows:

Artifact inspected: [Apple's published ZIP](https://docs-assets.developer.apple.com/published/506776157302/SharingWiFiNetworkCredentials.zip),
SHA-256 `eef654710a8dad1c1a9382e6f3a3349c2eaf596c027240e4661b49747f151ee6`.

1. The container app discovers a custom service UUID through AccessorySetupKit,
   requests LE pairing, connects with CoreBluetooth, and calls
   `WINetworkSharingController.requestAuthorization()`.
2. The transport extension accepts `AccessoryTransportSession.Request`,
   activates its own `ASAccessorySession`, obtains the paired accessory, creates
   `WINetworkSharingProvider`, and consumes `networkEvents`.
3. The provider code calls `JSONEncoder().encode(event.networks)` but discards
   the resulting bytes and only prints the network description.
4. The simulated accessory defines an encrypted-read characteristic and a
   write-without-response characteristic with UUID `0xFF5F`, and attempts to
   decode received bytes as `[WINetworkSharingProvider.Network]`.
5. No sample code connects the transport extension to that peripheral, frames
   writes, handles MTU/chunking, writes the JSON, acknowledges delivery, or
   reconnects in the background. The retained `AccessoryTransportSession` is
   not used for Wi-Fi payload delivery.

The downloadable source's own comment says "Wireless protocol isn't defined."
This is consistent with Apple's API documentation: after accepting a session,
the extension connects directly to the accessory and delivers provider data,
but Apple does not specify the wireless byte protocol. See the
[official sample page](https://developer.apple.com/documentation/wifiinfrastructure/sharing-wi-fi-network-credentials)
and
[AccessoryTransportAppExtension](https://developer.apple.com/documentation/accessorytransportextension/accessorytransportappextension).

This gap is not evidence that Linux is unsupported. It means the BLE GATT
service, framing, encoding, acknowledgements, and retry policy are intentionally
accessory-vendor code. A Linux accessory does not need to impersonate an Apple
device.

### Current Xcode compatibility note

The inspected ZIP is also slightly stale against the installed Xcode 26.6 /
iPhoneOS 26.5 SDK. A no-signing generic-device build reaches Swift compilation
but fails because `AccessoryTransportSession.EventHandler` now requires the
iOS 26.5 `sessionInvalidated(error:)` and `messageReceived(_:completion:)`
methods, while the sample implements the older invalidation callback. Its
access-point event handler also needs an iOS 26.4 availability annotation (or a
higher deployment target). These are small sample-compatibility edits, not a
Linux or Wi-Fi-sharing blocker, but the official ZIP should not be expected to
build literally unchanged with the current SDK.

## Linux and DGX Spark feasibility

NVIDIA documents Bluetooth 5.4 and Wi-Fi 7 in DGX Spark, and its porting guide
says the Wi-Fi and Bluetooth drivers are included, with LE support in the
platform. See NVIDIA's
[DGX Spark hardware overview](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)
and
[software stack](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/porting/software-requirements.html).
Bluetooth 5.4 hardware is new enough for LE Secure Connections, but the actual
controller, firmware, kernel, and BlueZ configuration still need verification
on the target Spark.

BlueZ exposes all of the required building blocks over D-Bus:

- `org.bluez.LEAdvertisingManager1` publishes a peripheral advertisement with
  a service UUID via `RegisterAdvertisement`. See the official
  [LE advertisement API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.LEAdvertisement.rst).
- `org.bluez.GattManager1.RegisterApplication` publishes a local GATT server
  represented by D-Bus service and characteristic objects. See
  [GattManager](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattManager.rst).
- GATT characteristic flags include encrypted and authenticated encrypted
  read/write/notify variants and server-only `secure-*` variants. See
  [GattCharacteristic](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst).
- A pairing agent declares the Spark's actual I/O capability and handles
  passkey/confirmation/authorization callbacks. See
  [AgentManager](https://github.com/bluez/bluez/blob/master/doc/org.bluez.AgentManager.rst)
  and [Agent](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Agent.rst).
- BlueZ's shipped `main.conf` documents `SecureConnections = only`, which
  rejects peers that cannot use Secure Connections, and a GATT minimum key-size
  control. See
  [BlueZ main.conf](https://github.com/bluez/bluez/blob/master/src/main.conf).

For the experiment, use `SecureConnections = only`, an encrypted GATT
characteristic, a short explicit pairing window, and persistent bonding. Do not
assume that BlueZ's `NoInputNoOutput`/Just Works path passes Apple's check until
tested. If the Spark can expose a display or confirmation UI, test a stronger
agent capability as a second pairing variant.

NetworkManager has a direct D-Bus path for applying the result.
`AddAndActivateConnection2` accepts the settings dictionary, target device, and
optional AP, and can persist the profile to disk, memory, or only for the
activation lifetime. The settings schema requires the raw SSID bytes and maps
personal security to `wpa-psk` or `sae`; `owe` and enterprise modes are also
represented. See
[`org.freedesktop.NetworkManager`](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html),
[`802-11-wireless`](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless.html),
and
[`802-11-wireless-security`](https://networkmanager.dev/docs/api/latest/settings-802-11-wireless-security.html).
Using D-Bus keeps the password out of command-line arguments and allows the
daemon to observe activation state.

## Practical minimum

### iOS container app

1. Declare the custom BLE service in `NSAccessorySetupBluetoothServices` and
   Bluetooth support in `NSAccessorySetupKitSupports`.
2. Present one `ASPickerDisplayItem` whose descriptor contains the service UUID
   and `.bluetoothPairingLE`.
3. Retain the authorized `ASAccessory`, retrieve its `CBPeripheral`, connect,
   and trigger an encrypted characteristic access so pairing/bonding completes.
4. Create `WINetworkSharingController(for:)` and call
   `requestAuthorization()` while connected.
5. Provide remove/re-pair diagnostics; no general-purpose app UI is needed for
   the first spike.

### iOS Accessory Transport Extension

1. Accept the session request and activate `ASAccessorySession`.
2. Retrieve/connect the paired peripheral by `bluetoothIdentifier`.
3. Create `WINetworkSharingProvider`, consume `networkEvents`, and initially
   support only open, OWE, WPA2-Personal, and WPA3-Personal networks.
4. Convert Apple's type to a small versioned DTO rather than making Linux
   depend on Swift's synthesized Codable representation.
5. Frame and chunk the payload across an encrypted GATT write characteristic;
   receive an acknowledgement/status notification; retry safely after a
   disconnect without logging credentials.

### Linux daemon

1. Register one private 128-bit service UUID with encrypted credential-RX and
   status-TX characteristics, plus the LE advertisement.
2. Register or rely on an appropriate BlueZ pairing agent, persist the iPhone
   bond, and close discoverability after setup.
3. Reassemble bounded, versioned messages and reject unsupported/invalid
   credential types.
4. Call NetworkManager's D-Bus API, observe activation completion, and notify
   a credential-free result to iOS.
5. Install as a narrowly privileged systemd service. Do not log SSIDs or
   credential payloads; do not forward them to the other Spark.

## Blockers and go/no-go gates

| Priority | Gate | Why it matters |
|---|---|---|
| 1 | Apply the small iOS 26.5 API-compatibility edits, then build Apple's sample with the intended signing team on an iOS 26.2+ device | Proves the two capabilities are available to the developer account and the region-independent development path works |
| 2 | On the Spark, verify an LE-peripheral-capable adapter and BlueZ GATT/advertising managers, then pair with `SecureConnections = only` | Hardware version alone does not prove the running stack can advertise and satisfy Apple's link-security inspection |
| 3 | Make `WINetworkSharingController.requestAuthorization()` return without `accessoryTransportNotSecured` against the real Spark | This is the decisive feasibility test |
| 4 | Transfer one synthetic nonsecret framed message from the extension to BlueZ and receive an ACK | Proves extension launch, CoreBluetooth retrieval, MTU/framing, and reconnect behavior before handling credentials |
| 5 | Transfer one open-network event, then one WPA2-Personal event, directly into a volatile NetworkManager activation | Proves the end-to-end minimum without enterprise or captive-portal complexity |
| 6 | Turn the app off/lock the phone, join a new network, and measure automatic extension wake/reconnection | Proves the actual travel workflow rather than only a foreground demo |

Secondary risks are captive portal variability, NetworkManager/PolicyKit
permissions, BlueZ pairing UI on a headless Spark, and reliable delivery across
extension termination. None requires Apple protocol reverse engineering, but
all require tests on the physical devices.

## LOC estimate

Evidence: the official sample's relevant container-app, transport-extension,
and shared Swift files are about 684 physical lines, or approximately 457
nonblank/noncomment lines. That code includes a demonstration UI but omits the
actual extension-to-accessory connection, GATT transmission, framing,
acknowledgements, retry policy, and all Linux code.

Inference for a deliberately narrow proof of concept:

| Component | Estimated source lines |
|---|---:|
| Minimal Swift container app | 120–220 |
| Transport extension, provider mapping, and CoreBluetooth GATT client | 250–420 |
| Linux BlueZ advertisement/GATT server/pairing integration | 250–450 |
| Framing, validation, NetworkManager integration, systemd, and focused tests | 180–350 |
| **Total** | **800–1,440** |

A 500-line total is unlikely unless it is a fragile demo built on substantial
third-party wrapper code and excludes tests/service integration. Roughly
700–1,000 lines is credible for the happy path if the BlueZ and D-Bus wrappers
are concise. A travel-ready utility with safe reconnects, idempotency,
credential-safe diagnostics, profile lifecycle, two accessories, packaging,
and tests is more plausibly 1,200–2,000 lines. These are engineering estimates,
not claims from Apple.

## Recommended decision

Proceed with one Spark and one iPhone, but time-box the work around gates 1–3.
The first deliverable should not be a polished app: it should be evidence that
a real DGX Spark bond passes Apple's secure-transport check and that a transport
extension can write one framed message to a BlueZ GATT characteristic while the
container app is not foregrounded. If that succeeds, the remaining WPA2/WPA3
NetworkManager path is conventional Linux integration. Defer enterprise Wi-Fi,
captive portals, the second Spark, and NAT until the automatic single-Spark
path is measured end to end.
