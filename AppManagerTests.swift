import AppKit
import ServiceManagement

@MainActor
final class TestApplication: NSObject, ManagedApplication {
  let processIdentifier: pid_t
  let localizedName: String?
  let icon: NSImage? = nil
  var bundleURL: URL?
  var isTerminated = false
  var acceptsQuit = true
  var acceptsActivation = true
  var quitCount = 0
  var forceQuitCount = 0
  var activationCount = 0

  init(pid: pid_t, name: String) {
    processIdentifier = pid
    localizedName = name
  }

  func activate(options: NSApplication.ActivationOptions) -> Bool {
    activationCount += 1
    return acceptsActivation
  }

  func terminate() -> Bool {
    quitCount += 1
    return acceptsQuit
  }

  func forceTerminate() -> Bool {
    forceQuitCount += 1
    return acceptsQuit
  }
}

@main
@MainActor
struct AppManagerTests {
  static func main() async {
    _ = NSApplication.shared
    let editor = TestApplication(pid: 100, name: "Editor")
    var running: [any ManagedApplication] = [editor]
    let model = AppDropdownModel(runningApplications: { running })
    let editorRow = model.rows[0]
    model.checkedIDs.insert(editorRow.id)

    model.quit(rows: model.selectedRows, force: false)
    precondition(editor.quitCount == 1 && editor.forceQuitCount == 0)
    precondition(
      model.rows.count == 1 && model.selectedRows.count == 1,
      "A save prompt or cancelled quit must not hide or deselect a running app.")
    precondition(
      model.status?.message.contains("save prompt") == true && model.status?.isError == false)
    model.refreshApps()
    precondition(model.rows[0].id == editorRow.id, "Refresh must preserve a live app's selection.")

    editor.acceptsQuit = false
    model.quit(rows: model.selectedRows, force: false)
    precondition(model.status?.isError == true && model.status?.message.contains("Editor") == true)
    precondition(model.rows.count == 1 && model.selectedRows.count == 1)
    model.quit(rows: model.selectedRows, force: true)
    precondition(editor.forceQuitCount == 1 && model.status?.isError == true)

    editor.isTerminated = true
    let replacement = TestApplication(pid: 100, name: "Replacement")
    running = [replacement]
    model.refreshApps()
    precondition(
      model.rows[0].id != editorRow.id && model.checkedIDs.isEmpty,
      "A reused PID must not inherit the old app's selection.")
    model.quit(rows: [editorRow], force: true)
    precondition(
      replacement.forceQuitCount == 0 && editor.forceQuitCount == 1,
      "A stale row must never quit a replacement process.")
    precondition(!model.activate(row: editorRow) && replacement.activationCount == 0)

    let replacementRow = model.rows[0]
    model.checkedIDs.insert(replacementRow.id)
    model.quit(rows: model.selectedRows, force: true)
    precondition(
      replacement.forceQuitCount == 1 && model.status?.isError == false && model.rows.count == 1)
    replacement.isTerminated = true
    running = []
    model.refreshApps()
    precondition(model.rows.isEmpty && model.checkedIDs.isEmpty)

    let first = TestApplication(pid: 102, name: "Same Name")
    let second = TestApplication(pid: 101, name: "Same Name")
    running = [first, second]
    model.refreshApps()
    precondition(
      model.visibleRows.map(\.pid) == [101, 102], "Equal names need a stable tie-breaker.")

    let sample = parseMemoryMB(
      "  101 1024\n102\t2048\n999 99\n101 nope\n103 -12\n104 nan\n105 inf\n",
      for: [101, 102, 103, 104, 105])
    precondition(sample.count == 2 && sample[101] == 1.048576 && sample[102] == 2.097152)
    precondition(parseMemoryMB("", for: []).isEmpty)
    precondition(fetchMemoryMB(for: []) == [:])
    precondition(memoryLabel(megabytes: nil) == "N/A")
    precondition(memoryLabel(megabytes: .infinity) == "N/A")
    precondition(memoryLabel(megabytes: 0) == "0 MB")
    precondition(memoryLabel(megabytes: 0.5) == "<1 MB")
    precondition(memoryLabel(megabytes: 999) == "999 MB")
    precondition(memoryLabel(megabytes: 1000) == "1.0 GB")

    let negativeDisplay = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
    let frame = dropdownFrame(
      anchor: NSRect(x: -40, y: 1055, width: 24, height: 25),
      contentSize: NSSize(width: 320, height: 650), visibleFrame: negativeDisplay)
    precondition(negativeDisplay.contains(frame) && frame.maxY == 1051)
    let offsetDisplay = NSRect(x: 1440, y: 900, width: 1280, height: 700)
    let tallFrame = dropdownFrame(
      anchor: NSRect(x: 1450, y: 1600, width: 24, height: 25),
      contentSize: NSSize(width: 320, height: 2000), visibleFrame: offsetDisplay)
    precondition(
      tallFrame.height == 2000 && tallFrame.maxY == offsetDisplay.maxY - 4,
      "Tall lists must retain their full height and stay anchored below the menu bar.")
    precondition(!confirmForceQuit(names: []))
    testQuitAllExceptSelected()
    testLaunchAtLogin()
    testNativeSelection()
    testActionConfirmation()
    await testRestart()
    print("AppManager regression assertions passed. No real apps were quit.")
  }

  static func testQuitAllExceptSelected() {
    let kept = TestApplication(pid: 501, name: "Keep")
    let closed = TestApplication(pid: 502, name: "Close")
    let late = TestApplication(pid: 503, name: "Opened Later")
    var running: [any ManagedApplication] = [kept, closed]
    let model = AppDropdownModel(runningApplications: { running })
    model.quitAllExceptSelected()
    precondition(kept.quitCount == 0 && closed.quitCount == 0)
    model.checkedIDs = Set(model.rows.map(\.id))
    precondition(!model.canQuitAllExceptSelected)
    model.quitAllExceptSelected()
    precondition(kept.quitCount == 0 && closed.quitCount == 0)
    model.checkedIDs = [model.rows.first { $0.pid == kept.processIdentifier }!.id]
    running.append(late)
    model.quitAllExceptSelected()
    precondition(kept.quitCount == 0 && closed.quitCount == 1 && late.quitCount == 1)
    precondition(running.allSatisfy { ($0 as! TestApplication).forceQuitCount == 0 })
    precondition(model.selectedRows.count == 1 && model.rows.count == 3)
    precondition(model.status?.message.contains("save prompt") == true)
    kept.isTerminated = true
    running = [closed, late]
    model.quitAllExceptSelected()
    precondition(
      closed.quitCount == 1 && late.quitCount == 1,
      "If all selected apps closed, do not turn the action into Quit All.")
  }

  static func testLaunchAtLogin() {
    var loginStatus: SMAppService.Status = .notRegistered
    var shouldFail = false
    var requested: [Bool] = []
    let model = AppDropdownModel(
      readLoginStatus: { loginStatus },
      setLoginEnabled: { enabled in
        requested.append(enabled)
        if shouldFail { throw NSError(domain: "Test", code: 1) }
        loginStatus = enabled ? .enabled : .notRegistered
      },
      runningApplications: { [] })
    model.refreshLoginStatus()
    precondition(!model.launchesAtLogin)
    model.setLaunchAtLogin(true)
    precondition(model.launchesAtLogin && model.status == nil)
    model.setLaunchAtLogin(false)
    precondition(!model.launchesAtLogin && requested == [true, false])
    loginStatus = .requiresApproval
    model.refreshLoginStatus()
    precondition(model.launchesAtLogin && model.loginStatus == .requiresApproval)
    shouldFail = true
    model.setLaunchAtLogin(false)
    precondition(model.launchesAtLogin && model.status?.isError == true)
    let pending = AppDropdownModel(
      readLoginStatus: { .requiresApproval }, setLoginEnabled: { _ in },
      runningApplications: { [] })
    pending.setLaunchAtLogin(true)
    precondition(pending.status?.message.contains("System Settings") == true)
  }

  static func testNativeSelection() {
    let apps = [
      TestApplication(pid: 301, name: "A Very Long Application Name That Must Remain Accessible"),
      TestApplication(pid: 302, name: "Notes"),
      TestApplication(pid: 303, name: "Safari"),
    ]
    let rows = apps.map { AppRow(application: $0) }
    let controller = AppTableController()
    let table = controller.tableView
    var selectionChanges: [Set<UUID>] = []
    var opened: [UUID] = []
    var dispatched: [(AppAction, [UUID])] = []
    var closed = false
    controller.onSelectionChanged = { selectionChanges.append($0) }
    controller.onOpen = { opened.append($0.id) }
    controller.onAction = { dispatched.append(($0, $1.map(\.id))) }
    table.onClose = { closed = true }
    controller.update(rows: rows, memory: [:], selectedIDs: [], isEnabled: true)
    precondition(selectionChanges.isEmpty)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = controller.scrollView
    precondition(window.initialFirstResponder === table)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    precondition(
      selectionChanges.last == [rows[0].id] && opened.isEmpty,
      "Selecting a row must not activate its application.")
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: true)
    let selected: Set<UUID> = [rows[0].id, rows[2].id]
    precondition(selectionChanges.last == selected)

    let previousChanges = selectionChanges.count
    let reordered = [rows[2], rows[0], rows[1]]
    controller.update(rows: reordered, memory: [303: 1200], selectedIDs: selected, isEnabled: true)
    precondition(table.selectedRowIndexes == IndexSet([0, 1]))
    precondition(Set(controller.selectedRows.map(\.id)) == selected)
    precondition(
      selectionChanges.count == previousChanges,
      "Reconciliation must not feed a stale row-index selection back into the model.")
    let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: 1) as! AppTableCell
    precondition(
      cell.textField?.stringValue == apps[0].localizedName && cell.toolTip == apps[0].localizedName)

    let focus = FocusSentinel()
    controller.scrollView.addSubview(focus)
    precondition(window.makeFirstResponder(focus))
    controller.update(rows: reordered, memory: [303: 1300], selectedIDs: selected, isEnabled: true)
    precondition(
      window.firstResponder === focus && selectionChanges.count == previousChanges,
      "A memory refresh must preserve keyboard focus and selected identities.")

    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let menu = table.menu!
    controller.menuWillOpen(menu)
    controller.update(rows: rows, memory: [:], selectedIDs: [rows[1].id], isEnabled: true)
    let forceItem = menu.items.first { $0.title == AppAction.forceQuit.title }!
    precondition(NSApp.sendAction(forceItem.action!, to: forceItem.target, from: forceItem))
    precondition(
      dispatched.count == 1 && dispatched[0].0 == .forceQuit && dispatched[0].1 == [rows[0].id],
      "An open menu must keep its original targets when the table refreshes.")

    let returnKey = keyEvent(code: 36, characters: "\r")
    table.keyDown(with: returnKey)
    precondition(opened == [rows[1].id])
    let selectAll = keyEvent(code: 0, characters: "a", modifiers: .command)
    precondition(table.performKeyEquivalent(with: selectAll))
    precondition(Set(controller.selectedRows.map(\.id)) == Set(rows.map(\.id)))
    table.keyDown(with: returnKey)
    precondition(opened.count == 1, "Return should only activate a single selected app.")
    table.keyDown(with: keyEvent(code: 53, characters: "\u{1b}"))
    precondition(closed)

    controller.update(rows: [rows[2]], memory: [:], selectedIDs: [rows[2].id], isEnabled: false)
    table.keyDown(with: returnKey)
    precondition(opened.count == 1 && !table.isEnabled)
    controller.update(rows: [], memory: [:], selectedIDs: [], isEnabled: true)
    precondition(table.numberOfRows == 0 && controller.selectedRows.isEmpty)
  }

  static func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [])
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
  }

  static func testActionConfirmation() {
    let app = TestApplication(pid: 400, name: "Editor")
    let model = AppDropdownModel(runningApplications: { [app] })
    var confirmations = 0
    let cancel: ([String], Bool) -> Bool = { names, _ in
      precondition(names == ["Editor"])
      confirmations += 1
      return false
    }
    performAppAction(.forceQuit, rows: model.rows, model: model, confirm: cancel)
    let restart = performAppAction(.restart, rows: model.rows, model: model, confirm: cancel)
    precondition(confirmations == 2 && app.forceQuitCount == 0 && restart == nil)
    performAppAction(.quit, rows: model.rows, model: model, confirm: cancel)
    precondition(
      app.quitCount == 1 && confirmations == 2,
      "A normal Quit should let the application handle its own save confirmation.")
    performAppAction(.forceQuit, rows: [], model: model, confirm: cancel)
    precondition(confirmations == 2)
    performAppAction(.forceQuit, rows: model.rows, model: model) { names, restart in
      precondition(names == ["Editor"] && !restart)
      return true
    }
    precondition(app.forceQuitCount == 1)
  }

  static func testRestart() async {
    let editor = TestApplication(pid: 200, name: "Editor")
    let secondEditor = TestApplication(pid: 201, name: "Editor")
    let stuck = TestApplication(pid: 202, name: "Stuck App")
    let unbundled = TestApplication(pid: 203, name: "Unbundled App")
    let refusing = TestApplication(pid: 204, name: "Refusing App")
    let editorURL = URL(fileURLWithPath: "/Applications/Editor.app")
    editor.bundleURL = editorURL
    secondEditor.bundleURL = editorURL
    stuck.bundleURL = URL(fileURLWithPath: "/Applications/Stuck.app")
    refusing.bundleURL = URL(fileURLWithPath: "/Applications/Refusing.app")
    refusing.acceptsQuit = false

    var opened: [URL] = []
    var failToOpen = false
    let model = AppDropdownModel(
      runningApplications: { [editor, secondEditor, stuck, unbundled, refusing] },
      reopenApplication: { url in
        precondition(editor.isTerminated && secondEditor.isTerminated)
        if failToOpen { throw CocoaError(.fileNoSuchFile) }
        opened.append(url)
      }
    )
    let editorRows = Array(model.rows.prefix(2))
    let restart = Task { await model.restart(rows: editorRows) }
    while editor.forceQuitCount == 0 { await Task.yield() }
    precondition(model.isRestarting && opened.isEmpty && secondEditor.forceQuitCount == 1)
    model.stop()
    await model.restart(rows: editorRows)
    precondition(editor.forceQuitCount == 1 && secondEditor.forceQuitCount == 1)
    editor.isTerminated = true
    secondEditor.isTerminated = true
    await restart.value
    precondition(opened == [editorURL] && model.status?.isError == false && !model.isRestarting)

    await model.restart(rows: model.rows, exitTimeout: .zero)
    precondition(stuck.forceQuitCount == 1 && refusing.forceQuitCount == 1)
    precondition(unbundled.forceQuitCount == 0 && opened == [editorURL])
    precondition(model.status?.isError == true && !model.isRestarting)
    precondition(model.status?.message.contains("did not exit") == true)
    precondition(model.status?.message.contains("app bundle") == true)
    precondition(model.status?.message.contains("Could not force quit") == true)

    editor.isTerminated = false
    failToOpen = true
    model.refreshApps()
    let relaunch = Task { await model.restart(rows: [model.rows[0]]) }
    while editor.forceQuitCount == 1 { await Task.yield() }
    editor.isTerminated = true
    await relaunch.value
    precondition(model.status?.message.contains("Could not reopen Editor") == true)
  }
}

@MainActor
final class FocusSentinel: NSView {
  override var acceptsFirstResponder: Bool { true }
}
