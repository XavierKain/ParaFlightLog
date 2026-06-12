//
//  ScreenshotTests.swift
//  ParaFlightLogUITests
//
//  Smoke test SoarX V10 : vérifie que les 4 onglets s'affichent sans crash
//

import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFourTabsSmoke() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "La tab bar doit apparaître")
        XCTAssertEqual(tabBar.buttons.count, 4, "L'app doit avoir exactement 4 onglets")

        // Parcourir chaque onglet et vérifier que l'app ne crash pas
        for index in 0..<4 {
            let tab = tabBar.buttons.element(boundBy: index)
            XCTAssertTrue(tab.exists, "L'onglet \(index) doit exister")
            tab.tap()
            sleep(1)
            XCTAssertTrue(app.state == .runningForeground, "L'app doit rester au premier plan sur l'onglet \(index)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "tab_\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
