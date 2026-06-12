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
    func testPhaseBScreens() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        // 1. Onglet Vol : toggle vario visible
        tabBar.buttons.element(boundBy: 0).tap()
        sleep(1)
        attach(app, name: "vol_tab_vario")

        // 2. Replay : Logbook > premier vol > bouton Replay
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(1)
        // Cibler le vol de test qui possède une trace GPS
        let gpsFlightCell = app.cells.containing(.staticText, identifier: "Tarifa Test").firstMatch
        let firstCell = gpsFlightCell.exists ? gpsFlightCell : app.cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            sleep(2)
            attach(app, name: "diag_after_cell_tap")
            let replayButton = app.buttons["Replay"]
            XCTAssertTrue(replayButton.waitForExistence(timeout: 5), "Le bouton Replay doit exister sur un vol avec trace")
            if replayButton.exists {
                replayButton.tap()
                sleep(2)
                attach(app, name: "replay_2d")
                XCTAssertTrue(app.state == .runningForeground, "Le replay ne doit pas crasher")
                // Basculer en 3D si le contrôle existe
                let threeD = app.buttons["3D"]
                if threeD.exists {
                    threeD.tap()
                    sleep(3)
                    attach(app, name: "replay_3d")
                }
            }
        }

        // Relancer l'app pour repartir d'un état propre (fermer replay/détail de façon fiable)
        app.terminate()
        app.launch()
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        // 3. Librairie de voiles : Réglages > Mes voiles > +
        tabBar.buttons.element(boundBy: 3).tap()
        sleep(1)
        let wingsRow = app.staticTexts["Mes voiles"]
        if wingsRow.waitForExistence(timeout: 5) {
            wingsRow.tap()
            sleep(1)
            // Bouton + (ajout)
            let addButton = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS 'plus' OR label CONTAINS 'Ajouter' OR label == 'Add'")).firstMatch
            if addButton.exists {
                addButton.tap()
                sleep(1)
                attach(app, name: "add_wing_chooser")
                // Depuis la bibliothèque
                let libraryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'bibliothèque' OR label CONTAINS 'Bibliothèque' OR label CONTAINS 'library'")).firstMatch
                if libraryButton.waitForExistence(timeout: 2) {
                    libraryButton.tap()
                    sleep(4) // téléchargement du catalogue GitHub
                    attach(app, name: "wing_library")
                    XCTAssertTrue(app.state == .runningForeground, "La bibliothèque ne doit pas crasher")
                }
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
