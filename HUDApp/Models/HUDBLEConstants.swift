import Foundation
import CoreBluetooth

enum HUDBLEConstants {
    static let serviceUUID = CBUUID(string: "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C001")
    static let writeCharacteristicUUID = CBUUID(string: "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C002")
    static let notifyCharacteristicUUID = CBUUID(string: "B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C003")

    static let allowedDeviceNames: Set<String> = [
        "GlanceHUD",
        "HUD Glasses",
        "XIAO-HUD"
    ]

    static let stateRestorationIdentifier = "com.colin.glancehud.central"
    static let lastPeripheralIdentifierKey = "com.colin.glancehud.lastPeripheralIdentifier"
    static let lastPeripheralNameKey = "com.colin.glancehud.lastPeripheralName"
}
