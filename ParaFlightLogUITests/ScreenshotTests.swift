//
//  ScreenshotTests.swift
//  ParaFlightLogUITests
//
//  Smoke test SoarX V10 : 4 onglets + écrans clés Phase A (détail vol, stats, voiles)
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
            attach(app, name: "tab_\(index)")
        }
    }

    @MainActor
    func testPhaseAScreens() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "La tab bar doit apparaître")

        // 1. Logbook > Timeline : ouvrir le premier vol (détail avec profil du vol)
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)
        let firstCell = app.cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            sleep(2)
            XCTAssertTrue(app.state == .runningForeground, "Le détail du vol ne doit pas crasher")
            attach(app, name: "flight_detail_top")
            app.swipeUp(); app.swipeUp()
            sleep(1)
            attach(app, name: "flight_detail_charts")
            // Fermer le détail (bouton Fermer ou retour navigation)
            if app.buttons["Fermer"].exists {
                app.buttons["Fermer"].tap()
            } else if app.navigationBars.buttons.element(boundBy: 0).exists {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            sleep(1)
        }

        // 2. Logbook > Stats (segment)
        let statsSegment = app.buttons["Stats"]
        if statsSegment.exists {
            statsSegment.tap()
            sleep(2)
            XCTAssertTrue(app.state == .runningForeground, "Les stats ne doivent pas crasher")
            attach(app, name: "stats_top")
            app.swipeUp(); app.swipeUp()
            sleep(1)
            attach(app, name: "stats_new_sections")
        }

        // 3. Réglages > Mes voiles
        tabBar.buttons.element(boundBy: 3).tap()
        sleep(1)
        let wingsRow = app.staticTexts["Mes voiles"]
        if wingsRow.waitForExistence(timeout: 5) {
            wingsRow.tap()
            sleep(2)
            XCTAssertTrue(app.state == .runningForeground, "La liste des voiles ne doit pas crasher")
            attach(app, name: "wings_list")
            // Ouvrir la première voile (détail avec compteur matériel)
            let firstWing = app.cells.element(boundBy: 0)
            if firstWing.exists {
                firstWing.tap()
                sleep(2)
                attach(app, name: "wing_detail")
            }
        }

        XCTAssertTrue(app.state == .runningForeground)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
