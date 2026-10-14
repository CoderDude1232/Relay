//
//  RelayWatch_Watch_AppUITests.swift
//  RelayWatch Watch AppUITests
//
//  The watch app as someone uses it: the chat list, opening a chat, quick
//  replies and calling. There's no paired iPhone in the simulator, so the app
//  runs on its built-in test chats (see WatchUITestFixture.swift) and treats
//  sends and calls as accepted.
//

import XCTest

final class RelayWatch_Watch_AppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchWithChats() {
        app.launchArguments = ["-RelayWatchUITestFixture"]
        app.launch()
    }

    /// Any element whose accessibility label contains `text`.
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openChat(_ id: String) {
        let row = app.buttons["chat-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "chat row \(id) missing")
        row.tap()
    }

    @MainActor
    func testFirstLaunchAsksForTheIPhone() throws {
        app.launchArguments = ["-RelayWatchUITestEmpty"]
        app.launch()
        XCTAssertTrue(element(containing: "Open Relay on your iPhone").waitForExistence(timeout: 10))
    }

    @MainActor
    func testChatListShowsChatsWithPreviews() throws {
        launchWithChats()
        XCTAssertTrue(app.buttons["chat-alice"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Alice Smith").exists)
        XCTAssertTrue(element(containing: "See you there").exists)
        XCTAssertTrue(element(containing: "2 unread").exists)
        XCTAssertTrue(element(containing: "You: OK").exists)
    }

    @MainActor
    func testOpeningAChatShowsItsMessages() throws {
        launchWithChats()
        openChat("alice")
        XCTAssertTrue(element(containing: "Sure, noon works").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "You: Lunch tomorrow?").exists)
    }

    @MainActor
    func testGroupMessagesNameTheirSender() throws {
        launchWithChats()
        openChat("family")
        XCTAssertTrue(element(containing: "Mom: Dinner at 7").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Missed group call").exists)
        // Calls from a group start on the iPhone, so the watch offers none.
        XCTAssertFalse(app.buttons["call"].exists)
    }

    @MainActor
    func testQuickReplyAppearsInTheChat() throws {
        launchWithChats()
        openChat("alice")
        // "OK", the second quick reply; later ones sit off to the side.
        let reply = app.buttons["quick-reply-1"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertFalse(element(containing: "You: OK").exists)
        // Tap the button's centre directly: inside the horizontally scrolling
        // row, an element tap can be taken as the start of a scroll.
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element(containing: "You: OK").waitForExistence(timeout: 10),
                      "no sent bubble; screen was:\n\(app.debugDescription)")
        XCTAssertFalse(element(containing: "Couldn't send").exists)
    }

    @MainActor
    func testCallingHandsOffToTheIPhone() throws {
        launchWithChats()
        openChat("alice")
        // The toolbar can report the button more than once.
        let call = app.buttons["call"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertEqual(call.label, "Call Alice Smith")
        call.tap()
        XCTAssertTrue(element(containing: "The call is on your iPhone").waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyChatSaysSo() throws {
        launchWithChats()
        openChat("bob")
        XCTAssertTrue(element(containing: "No recent messages").waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launchArguments = ["-RelayWatchUITestFixture"]
            app.launch()
        }
    }
}
