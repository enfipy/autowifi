import json
import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class IOSManifestTests(unittest.TestCase):
    def test_transport_extension_declares_apples_local_extension_point(self):
        with (ROOT / "ios/TransportExtension/Info.plist").open("rb") as stream:
            manifest = plistlib.load(stream)

        self.assertEqual(
            manifest["EXAppExtensionAttributes"],
            {
                "EXExtensionPointIdentifier": "com.apple.accessory-transport-extension",
                "Transport": "Local",
            },
        )

    def test_transport_extension_binds_the_extension_point_in_swift(self):
        source = (ROOT / "ios/TransportExtension/TransportExtension.swift").read_text()
        self.assertIn("import ExtensionFoundation", source)
        self.assertIn("@AppExtensionPoint.Bind", source)
        self.assertIn(
            'AppExtensionPoint.Identifier("com.apple.accessory-transport-extension")',
            source,
        )

    def test_picker_bluetooth_filters_are_declared_in_app_manifest(self):
        bluetooth = json.loads(
            (ROOT / "config" / "autowifi.json").read_text()
        )["bluetooth"]
        legacy_discovery_uuids = {
            uuid
            for uuids in bluetooth["legacyProductDiscoveryUUIDs"].values()
            for uuid in uuids
        }
        with (ROOT / "ios/App/Info.plist").open("rb") as stream:
            manifest = plistlib.load(stream)

        self.assertNotIn("NSAccessorySetupBluetoothNames", manifest)
        declared = set(manifest["NSAccessorySetupBluetoothServices"])
        self.assertEqual(
            declared,
            {
                bluetooth["serviceUUID"],
                *bluetooth["productDiscoveryUUIDs"].values(),
                *legacy_discovery_uuids,
            },
        )

        with (ROOT / "ios/TransportExtension/Info.plist").open("rb") as stream:
            extension_manifest = plistlib.load(stream)
        self.assertEqual(
            set(extension_manifest["NSBluetoothServices"]),
            {bluetooth["serviceUUID"]},
        )
        self.assertNotIn("NSBluetoothAlwaysUsageDescription", extension_manifest)
        self.assertNotIn("NSAccessorySetupBluetoothServices", extension_manifest)
        self.assertEqual(extension_manifest["UIBackgroundModes"], ["bluetooth-central"])

    def test_picker_avoids_fatal_undeclared_manufacturer_filter(self):
        source = (ROOT / "ios/App/AccessoryCatalog.swift").read_text()
        self.assertIn("legacyGigabyteDiscoveryUUIDs.map", source)
        self.assertNotIn("bluetoothCompanyIdentifier", source)
        self.assertNotIn("bluetoothManufacturerDataBlob", source)


if __name__ == "__main__":
    unittest.main()
