import AccessorySetupKit
import CoreBluetooth
import UIKit

enum AccessoryCatalog {
    static func pickerItems() -> [ASPickerDisplayItem] {
        var items = [
            item(
                name: "GIGABYTE AI TOP ATOM",
                discoveryUUID: AutoWiFiConstants.productDiscoveryUUIDs["gigabyte"]!,
                imageName: "gigabyte-spark"
            ),
            item(
                name: "NVIDIA DGX Spark",
                discoveryUUID: AutoWiFiConstants.productDiscoveryUUIDs["nvidia"]!,
                imageName: "nvidia-spark"
            ),
            item(
                name: "Autowifi PC",
                discoveryUUID: AutoWiFiConstants.productDiscoveryUUIDs["generic"]!,
                imageName: nil
            ),
        ]

        // Keep accepting the temporary UUID shipped to early Sparks. This migration
        // entry can be removed after every daemon has been reinstalled from current source.
        items += AutoWiFiConstants.legacyGigabyteDiscoveryUUIDs.map { discoveryUUID in
            item(
                name: "GIGABYTE AI TOP ATOM",
                discoveryUUID: discoveryUUID,
                imageName: "gigabyte-spark"
            )
        }
        return items
    }

    private static func item(
        name: String,
        discoveryUUID: UUID,
        imageName: String?
    ) -> ASPickerDisplayItem {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(nsuuid: discoveryUUID)
        descriptor.supportedOptions.insert(.bluetoothPairingLE)
        return ASPickerDisplayItem(
            name: name,
            productImage: productImage(named: imageName),
            descriptor: descriptor
        )
    }

    private static func productImage(named imageName: String?) -> UIImage {
        if let imageName, let image = UIImage(named: imageName) {
            return image.withRenderingMode(.alwaysOriginal)
        }

        let palette = UIImage.SymbolConfiguration(
            paletteColors: [.systemBlue, .systemCyan]
        )
        let symbol = UIImage(systemName: "wifi.router.fill", withConfiguration: palette)
            ?? UIImage(systemName: "externaldrive.connected.to.line.below.fill")!

        // AccessorySetupKit renders template symbols as black artwork. Original rendering
        // preserves the dynamic palette in both light and dark picker appearances.
        return symbol.withRenderingMode(.alwaysOriginal)
    }
}
