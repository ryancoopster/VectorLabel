import XCTest
@testable import VectorLabelCore
import PrinterBrother
import PrinterM611

/// The PT-E550W network transport plumbing: the driver advertises `.network`, and a
/// network printer's stored MODEL round-trips so each driver enumerates only its own
/// (the M611/Brother collision fix relies on the per-entry model).
final class BrotherNetworkTests: XCTestCase {

    func testBrotherAdvertisesUSBAndNetwork() {
        let t = PTE550WModule().capabilities.supportedTransports
        XCTAssertTrue(t.contains(.network))
        XCTAssertTrue(t.contains(.usb))
    }

    func testM611AdvertisesNetwork() {
        XCTAssertTrue(M611Module().capabilities.supportedTransports.contains(.network))
    }

    func testNetworkPrinterStoreRoundTripsModel() {
        // Save & restore the real key so the test leaves UserDefaults untouched.
        let key = NetworkPrinterStore.defaultsKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        XCTAssertTrue(NetworkPrinterStore.add(name: "PT-E550W (192.168.86.32)",
                                              host: "192.168.86.32", model: "PT-E550W"))
        XCTAssertTrue(NetworkPrinterStore.add(name: "M611 (192.168.86.40)",
                                              host: "192.168.86.40", model: "M611"))
        let brother = NetworkPrinterStore.list().first { $0.host == "192.168.86.32" }
        XCTAssertEqual(brother?.model, "PT-E550W")
        let m611 = NetworkPrinterStore.list().first { $0.host == "192.168.86.40" }
        XCTAssertEqual(m611?.model, "M611")

        // Each driver's enumerate filters NetworkPrinterStore to its OWN model, so
        // these two entries route to different drivers (no duplicate device id).
        let brotherModels = ["PT-E550W"]
        XCTAssertEqual(NetworkPrinterStore.list().filter { brotherModels.contains($0.model) }.count, 1)
        XCTAssertEqual(NetworkPrinterStore.list().filter { $0.model == "M611" }.count, 1)
    }

    func testLegacyEntryDefaultsToM611() {
        // A legacy "name|host" (no model field) still parses as M611, so existing M611
        // network printers keep enumerating after the per-model filter was added.
        let key = NetworkPrinterStore.defaultsKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(["Old Printer|192.168.86.50"], forKey: key)
        XCTAssertEqual(NetworkPrinterStore.list().first?.model, "M611")
    }
}
