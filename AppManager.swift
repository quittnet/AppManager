import AppKit
import SwiftUI

// MARK: - Process sampling

func parseMemoryMB(_ output: String, for pids: Set<pid_t>) -> [pid_t: Double] {
  var memory: [pid_t: Double] = [:]
  for line in output.split(whereSeparator: \.isNewline) {
    let columns = line.split(whereSeparator: \.isWhitespace)
    guard columns.count == 2,
      let pid = pid_t(columns[0]), pids.contains(pid),
      let rssKB = Double(columns[1]), rssKB.isFinite, rssKB >= 0
    else { continue }
    // ps reports KiB. Convert to decimal MB to match the displayed MB/GB units.
    memory[pid] = rssKB * 1024 / 1_000_000
  }
  return memory
}

func fetchMemoryMB(for pids: Set<pid_t>) -> [pid_t: Double]? {
  guard !pids.isEmpty else { return [:] }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = [
    "-p", pids.sorted().map(String.init).joined(separator: ","), "-o", "pid=,rss=",
  ]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
  } catch {
    return nil
  }
  // Drain while ps runs: waiting first can deadlock when the pipe fills.
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  // ps exits with 1 if every requested process has already exited.
  guard process.terminationReason == .exit,
    process.terminationStatus == 0 || process.terminationStatus == 1,
    let output = String(data: data, encoding: .utf8)
  else { return nil }
  return parseMemoryMB(output, for: pids)
}

func memoryLabel(megabytes: Double?) -> String {
  guard let megabytes, megabytes.isFinite, megabytes >= 0 else { return "N/A" }
  if megabytes >= 1000 { return String(format: "%.1f GB", megabytes / 1000) }
  if megabytes > 0 && megabytes < 1 { return "<1 MB" }
  return String(format: "%.0f MB", megabytes)
}

// MARK: - Application state

@MainActor
protocol ManagedApplication: AnyObject {
  var processIdentifier: pid_t { get }
  var localizedName: String? { get }
  var icon: NSImage? { get }
  var bundleURL: URL? { get }
  var isTerminated: Bool { get }
  func isEqual(_ object: Any?) -> Bool
  func activate(options: NSApplication.ActivationOptions) -> Bool
  func terminate() -> Bool
  func forceTerminate() -> Bool
}

extension NSRunningApplication: ManagedApplication {}

struct AppRow: Identifiable {
  let id = UUID()
  let name: String
  let pid: pid_t
  let icon: NSImage?
  let application: any ManagedApplication

  @MainActor
  init(application: any ManagedApplication) {
    self.application = application
    name = application.localizedName ?? "App (PID \(application.processIdentifier))"
    pid = application.processIdentifier
    icon = application.icon
  }
}

@MainActor
final class AppDropdownModel: ObservableObject {
  private struct Inventory {
    var rows: [AppRow] = []
    var memory: [pid_t: Double] = [:]
    var checkedIDs: Set<UUID> = []
  }

  struct Status {
    let message: String
    var isError = false
  }

  @Published private var inventory = Inventory()
  @Published private(set) var status: Status?
  @Published private(set) var isRestarting = false

  private let runningApplications: () -> [any ManagedApplication]
  private let reopenApplication: (URL) async throws -> Void
  private var timer: Timer?
  private var isSampling = false
  private var generation = 0

  init(
    runningApplications: @escaping () -> [any ManagedApplication] = {
      NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
          && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
      }
    },
    reopenApplication: @escaping (URL) async throws -> Void = { url in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
  ) {
    self.runningApplications = runningApplications
    self.reopenApplication = reopenApplication
    refreshApps()
  }

  var rows: [AppRow] { inventory.rows }
  var memoryMap: [pid_t: Double] { inventory.memory }
  var checkedIDs: Set<UUID> {
    get { inventory.checkedIDs }
    set { inventory.checkedIDs = newValue }
  }

  var visibleRows: [AppRow] {
    rows.sorted { first, second in
      // Coarse buckets keep small memory changes from constantly moving rows.
      let firstBucket = floor((memoryMap[first.pid] ?? 0) / 100)
      let secondBucket = floor((memoryMap[second.pid] ?? 0) / 100)
      if firstBucket != secondBucket { return firstBucket > secondBucket }
      let order = first.name.localizedStandardCompare(second.name)
      return order == .orderedSame ? first.pid < second.pid : order == .orderedAscending
    }
  }

  var selectedRows: [AppRow] {
    visibleRows.filter { checkedIDs.contains($0.id) }
  }

  func start() {
    guard timer == nil else { return }
    let timerGeneration = generation
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == timerGeneration else { return }
        self.refresh()
      }
    }
    refresh()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    generation += 1
    if !isRestarting {
      checkedIDs.removeAll()
      status = nil
    }
  }

  func refreshApps() {
    let running = runningApplications().filter { !$0.isTerminated && $0.processIdentifier > 0 }
    let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
    let updatedRows = running.map { application in
      if let row = previous[application.processIdentifier],
        !row.application.isTerminated,
        row.application.isEqual(application)
      {
        return row
      }
      // Keep the original NSRunningApplication instance for all actions. A PID
      // lookup at click time could target a different app after PID reuse.
      return AppRow(application: application)
    }
    let updatedIDs = updatedRows.map(\.id)
    let updatedSelection = checkedIDs.intersection(updatedIDs)
    guard updatedIDs != rows.map(\.id) || updatedSelection != checkedIDs else { return }
    let unchangedPIDs = Set(updatedRows.filter { previous[$0.pid]?.id == $0.id }.map(\.pid))
    inventory = Inventory(
      rows: updatedRows,
      memory: memoryMap.filter { unchangedPIDs.contains($0.key) },
      checkedIDs: updatedSelection
    )
  }

  private func refresh() {
    refreshApps()
    guard !isSampling else { return }
    isSampling = true
    let sampleGeneration = generation
    let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.id) })
    let pids = Set(identities.keys)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let memory = fetchMemoryMB(for: pids)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isSampling = false
        guard self.timer != nil, self.generation == sampleGeneration else { return }
        let currentIDs = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.pid, $0.id) })
        let updatedMemory = (memory ?? [:]).filter { identities[$0.key] == currentIDs[$0.key] }
        if updatedMemory != self.memoryMap {
          self.inventory.memory = updatedMemory
        }
      }
    }
  }

  func quit(rows selected: [AppRow], force: Bool) {
    guard !isRestarting, !selected.isEmpty else { return }
    var failures: [String] = []
    var requested = 0
    for row in selected where !row.application.isTerminated {
      let accepted = force ? row.application.forceTerminate() : row.application.terminate()
      if accepted {
        requested += 1
      } else {
        failures.append(row.name)
      }
    }
    if !failures.isEmpty {
      let target: String
      if failures.count == 1, let name = failures.first {
        target = name.count > 40 ? String(name.prefix(40)) + "..." : name
      } else {
        target = "\(failures.count) selected apps"
      }
      status = Status(
        message:
          "Could not \(force ? "force quit" : "quit") \(target). Try again or open Activity Monitor.",
        isError: true
      )
    } else if requested > 0 {
      status = Status(
        message: force
          ? "Force quit requested. Apps disappear once they exit."
          : "Quit requested. If an app stays open, check its save prompt."
      )
    } else {
      status = Status(message: "The selected apps have already closed.")
    }
    // A successful request is not proof of exit. Save prompts can cancel quits.
    refreshApps()
  }

  func restart(rows selected: [AppRow], exitTimeout: Duration = .seconds(5)) async {
    guard !isRestarting, !selected.isEmpty else { return }
    isRestarting = true
    status = Status(message: "Restarting \(selected.count == 1 ? "app" : "apps")…")
    defer {
      refreshApps()
      isRestarting = false
    }

    var pending: [(row: AppRow, url: URL)] = []
    var blockedURLs: Set<URL> = []
    var failures: [String] = []
    for row in selected {
      if row.application.isTerminated {
        failures.append("\(row.name) had already closed.")
      } else if let url = row.application.bundleURL, url.isFileURL {
        if row.application.forceTerminate() {
          pending.append((row, url))
        } else {
          blockedURLs.insert(url)
          failures.append("Could not force quit \(row.name).")
        }
      } else {
        failures.append("Could not find the app bundle for \(row.name).")
      }
    }

    let clock = ContinuousClock()
    let deadline = clock.now + exitTimeout
    while clock.now < deadline && pending.contains(where: { !$0.row.application.isTerminated }) {
      do {
        try await clock.sleep(until: min(deadline, clock.now + .milliseconds(100)))
      } catch {
        status = Status(message: "Restart was interrupted.", isError: true)
        return
      }
    }

    for (row, url) in pending where !row.application.isTerminated {
      blockedURLs.insert(url)
      failures.append("\(row.name) did not exit in time.")
    }

    var reopened: Set<URL> = []
    for (row, url) in pending {
      guard !blockedURLs.contains(url), reopened.insert(url).inserted else { continue }
      do {
        try await reopenApplication(url)
      } catch {
        failures.append("Could not reopen \(row.name): \(error.localizedDescription)")
      }
    }

    if failures.isEmpty {
      status = Status(message: reopened.count == 1 ? "App restarted." : "Apps restarted.")
    } else {
      status = Status(message: failures.joined(separator: "\n"), isError: true)
    }
  }

  func activate(row: AppRow) -> Bool {
    guard !row.application.isTerminated, row.application.activate(options: []) else {
      status = Status(
        message: "Could not open \(row.name). It may have already closed.", isError: true)
      refreshApps()
      return false
    }
    return true
  }
}

@MainActor
func confirmForceQuit(names: [String], restart: Bool = false) -> Bool {
  guard !names.isEmpty else { return false }
  let alert = NSAlert()
  alert.alertStyle = .warning
  let target = names.count == 1 ? names[0] : "\(names.count) apps"
  alert.messageText = restart ? "Force quit and restart \(target)?" : "Force quit \(target)?"
  let listedNames = names.prefix(8).joined(separator: "\n")
  let remainder = names.count > 8 ? "\nAnd \(names.count - 8) more apps." : ""
  let detail =
    restart
    ? "AppManager will reopen the selected apps after they exit."
    : "Use this when an app is unresponsive."
  alert.informativeText = "Unsaved changes will be lost. \(detail)\n\n\(listedNames)\(remainder)"
  alert.addButton(withTitle: "Cancel")
  alert.addButton(withTitle: restart ? "Force Quit & Restart" : "Force Quit").hasDestructiveAction =
    true
  NSApp.activate(ignoringOtherApps: true)
  return alert.runModal() == .alertSecondButtonReturn
}

// MARK: - Menu bar dropdown

struct VisualEffectView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum AppAction: CaseIterable {
  case quit, forceQuit, restart

  var title: String {
    switch self {
    case .quit: "Quit"
    case .forceQuit: "Force Quit…"
    case .restart: "Force Quit & Restart…"
    }
  }
}

@MainActor
@discardableResult
func performAppAction(
  _ action: AppAction, rows: [AppRow], model: AppDropdownModel,
  confirm: ([String], Bool) -> Bool = { confirmForceQuit(names: $0, restart: $1) }
) -> Task<Void, Never>? {
  guard !model.isRestarting, !rows.isEmpty else { return nil }
  if action != .quit, !confirm(rows.map(\.name), action == .restart) { return nil }
  switch action {
  case .quit:
    model.quit(rows: rows, force: false)
  case .forceQuit:
    model.quit(rows: rows, force: true)
  case .restart:
    // This task belongs to the operation, so dismissing the panel does not cancel it.
    return Task { await model.restart(rows: rows) }
  }
  return nil
}

@MainActor
final class AppTableView: NSTableView {
  var onOpen: (() -> Void)?
  var onClose: (() -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Set initial focus only. Refreshes must not take focus from another control.
    window?.initialFirstResponder = self
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onClose?()
    } else if event.keyCode == 36 || event.keyCode == 76 {
      if isEnabled { onOpen?() }
    } else if isEnabled {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "a", isEnabled
    {
      selectAll(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard isEnabled else { return nil }
    let clickedRow = row(at: convert(event.locationInWindow, from: nil))
    guard clickedRow >= 0 else { return nil }
    if !selectedRowIndexes.contains(clickedRow) {
      selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    }
    return super.menu(for: event)
  }
}

@MainActor
final class AppTableCell: NSTableCellView {
  private let isMemory: Bool

  init(isMemory: Bool) {
    self.isMemory = isMemory
    super.init(frame: .zero)
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.font =
      isMemory
      ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      : .systemFont(ofSize: 13)
    label.alignment = isMemory ? .right : .left
    addSubview(label)
    textField = label
    NSLayoutConstraint.activate([
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])
    if isMemory {
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
    } else {
      let icon = NSImageView()
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.imageScaling = .scaleProportionallyUpOrDown
      icon.setAccessibilityElement(false)
      addSubview(icon)
      imageView = icon
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 24),
        icon.heightAnchor.constraint(equalToConstant: 24),
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      ])
    }
    updateTextColor()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateTextColor() }
  }

  private func updateTextColor() {
    textField?.textColor =
      backgroundStyle == .emphasized
      ? .alternateSelectedControlTextColor : (isMemory ? .secondaryLabelColor : .labelColor)
  }
}

@MainActor
final class AppTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate
{
  static let rowHeight: CGFloat = 34
  static let headerHeight: CGFloat = 25

  let tableView = AppTableView()
  let scrollView = NSScrollView()
  private var rows: [AppRow] = []
  private var memory: [pid_t: Double] = [:]
  private var isUpdating = false
  private var menuRows: [AppRow] = []
  var onSelectionChanged: (Set<UUID>) -> Void = { _ in }
  var onOpen: (AppRow) -> Void = { _ in }
  var onAction: (AppAction, [AppRow]) -> Void = { _, _ in }

  override init() {
    super.init()
    tableView.style = .fullWidth
    tableView.rowHeight = Self.rowHeight
    tableView.intercellSpacing = .zero
    tableView.backgroundColor = .clear
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.allowsColumnReordering = false
    tableView.allowsColumnResizing = false
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.headerView = NSTableHeaderView(
      frame: NSRect(x: 0, y: 0, width: 360, height: Self.headerHeight))
    tableView.setAccessibilityLabel("Running apps")
    tableView.setAccessibilityHelp(
      "Select an app, or use Command or Shift to select multiple apps. Double-click or press Return to open an app."
    )
    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
    nameColumn.title = "App"
    nameColumn.width = 264
    nameColumn.minWidth = 120
    let memoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("memory"))
    memoryColumn.title = "Memory"
    memoryColumn.width = 96
    memoryColumn.minWidth = 80
    memoryColumn.headerCell.alignment = .right
    memoryColumn.headerToolTip =
      "Resident memory of the main process. Helper processes are not included. N/A means unavailable."
    tableView.addTableColumn(nameColumn)
    tableView.addTableColumn(memoryColumn)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.target = self
    tableView.doubleAction = #selector(openClickedRow)
    tableView.onOpen = { [weak self] in self?.openSelection() }

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    let openItem = NSMenuItem(
      title: "Open", action: #selector(openMenuSelection), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    for (index, action) in AppAction.allCases.enumerated() {
      let item = NSMenuItem(
        title: action.title, action: #selector(performMenuAction), keyEquivalent: "")
      item.tag = index
      item.target = self
      menu.addItem(item)
    }
    tableView.menu = menu

    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.documentView = tableView
  }

  func update(rows: [AppRow], memory: [pid_t: Double], selectedIDs: Set<UUID>, isEnabled: Bool) {
    isUpdating = true
    defer { isUpdating = false }
    let structureChanged = rows.map(\.id) != self.rows.map(\.id)
    let changedMemory = IndexSet(
      rows.indices.filter { memory[rows[$0].pid] != self.memory[rows[$0].pid] })
    self.rows = rows
    self.memory = memory
    tableView.isEnabled = isEnabled
    if structureChanged {
      tableView.reloadData()
    } else if !changedMemory.isEmpty {
      // Leave native selection tracking and the app-name cells intact during sampling.
      tableView.reloadData(forRowIndexes: changedMemory, columnIndexes: IndexSet(integer: 1))
    }
    let indexes = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
    if tableView.selectedRowIndexes != indexes {
      tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }
  }

  var selectedRows: [AppRow] {
    tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard rows.indices.contains(row), let tableColumn else { return nil }
    let app = rows[row]
    let isMemory = tableColumn.identifier.rawValue == "memory"
    let cell =
      tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? AppTableCell
      ?? AppTableCell(isMemory: isMemory)
    cell.identifier = tableColumn.identifier
    if isMemory {
      let value = memoryLabel(megabytes: memory[app.pid])
      cell.textField?.stringValue = value
      cell.textField?.setAccessibilityLabel("Memory: \(value)")
    } else {
      cell.textField?.stringValue = app.name
      cell.imageView?.image =
        app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
      cell.toolTip = app.name
    }
    return cell
  }

  func selectionShouldChange(in tableView: NSTableView) -> Bool {
    isUpdating || tableView.isEnabled
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdating else { return }
    onSelectionChanged(Set(selectedRows.map(\.id)))
  }

  @objc private func openClickedRow() {
    let index = tableView.clickedRow
    guard tableView.isEnabled, rows.indices.contains(index) else { return }
    onOpen(rows[index])
  }

  func openSelection() {
    guard tableView.isEnabled, selectedRows.count == 1, let row = selectedRows.first else {
      return
    }
    onOpen(row)
  }

  func menuWillOpen(_ menu: NSMenu) {
    // Keep menu targets fixed even if the next memory sample changes the row order.
    menuRows = selectedRows
    menu.items.first?.isEnabled = menuRows.count == 1
  }

  @objc private func openMenuSelection() {
    guard menuRows.count == 1, let row = menuRows.first else { return }
    onOpen(row)
  }

  @objc private func performMenuAction(_ sender: NSMenuItem) {
    guard AppAction.allCases.indices.contains(sender.tag) else { return }
    onAction(AppAction.allCases[sender.tag], menuRows)
  }
}

struct AppListView: NSViewRepresentable {
  let rows: [AppRow]
  let memory: [pid_t: Double]
  @Binding var selectedIDs: Set<UUID>
  let isEnabled: Bool
  let onOpen: (AppRow) -> Void
  let onAction: (AppAction, [AppRow]) -> Void
  let onClose: () -> Void

  func makeCoordinator() -> AppTableController { AppTableController() }

  func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelectionChanged = { selectedIDs = $0 }
    coordinator.onOpen = onOpen
    coordinator.onAction = onAction
    coordinator.tableView.onClose = onClose
    coordinator.update(rows: rows, memory: memory, selectedIDs: selectedIDs, isEnabled: isEnabled)
  }
}

@MainActor
struct AppDropdownView: View {
  @ObservedObject var model: AppDropdownModel
  let onClose: () -> Void
  let onContentChanged: () -> Void

  var body: some View {
    let selectionCount = model.checkedIDs.count

    VStack(spacing: 0) {
      HStack {
        Text("Running Apps")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Menu {
          ForEach(AppAction.allCases, id: \.self) { action in
            Button(action.title) {
              performAppAction(action, rows: model.selectedRows, model: model)
            }
          }
        } label: {
          Label("Actions", systemImage: "stop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selectionCount == 0 || model.isRestarting)
        .help("Quit, force quit, or restart selected apps")
        .accessibilityLabel("Actions for selected apps")
      }
      .padding(.horizontal, 16)
      .frame(height: 48)

      Divider()

      AppListView(
        rows: model.visibleRows, memory: model.memoryMap,
        selectedIDs: Binding(get: { model.checkedIDs }, set: { model.checkedIDs = $0 }),
        isEnabled: !model.isRestarting,
        onOpen: { row in if model.activate(row: row) { onClose() } },
        onAction: { action, rows in performAppAction(action, rows: rows, model: model) },
        onClose: onClose
      )
      // The native table expands with its inventory; there is no capped scrolling region.
      .frame(
        height: AppTableController.headerHeight + max(1, CGFloat(model.rows.count))
          * AppTableController.rowHeight
          + (model.rows.isEmpty ? 46 : 0)
      )
      .overlay {
        if model.rows.isEmpty {
          VStack(spacing: 4) {
            Text("No running apps").font(.system(size: 13, weight: .medium))
            Text("Apps you open appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          .padding(.top, AppTableController.headerHeight)
          .allowsHitTesting(false)
        }
      }

      if let status = model.status {
        Divider()
        HStack(alignment: .top, spacing: 8) {
          if model.isRestarting {
            ProgressView().controlSize(.small).accessibilityHidden(true)
          } else if status.isError {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
          }
          Text(status.message)
            .lineLimit(3)
            .help(status.message)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(status.isError ? "Error: \(status.message)" : status.message)
          Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }

      Divider()

      HStack(spacing: 12) {
        Text(
          selectionCount == 0
            ? "\(model.rows.count) \(model.rows.count == 1 ? "app" : "apps")"
            : "\(selectionCount) of \(model.rows.count) selected"
        )
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Spacer(minLength: 0)
        Button("Activity Monitor") {
          let configuration = NSWorkspace.OpenConfiguration()
          if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor")
          {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            onClose()
          }
        }
        .buttonStyle(.borderless)
        .help("Open Activity Monitor for more process details")
        Menu {
          Button("Select All") { model.checkedIDs = Set(model.rows.map(\.id)) }
            .disabled(model.rows.isEmpty || model.isRestarting)
          Button("Deselect All") { model.checkedIDs.removeAll() }
            .disabled(selectionCount == 0 || model.isRestarting)
          Divider()
          Button("Quit AppManager") { NSApp.terminate(nil) }
            .disabled(model.isRestarting)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options")
        .help("Selection options and Quit AppManager")
      }
      .font(.system(size: 11))
      .padding(.horizontal, 16)
      .frame(height: 36)
    }
    .frame(width: 360)
    .fixedSize(horizontal: false, vertical: true)
    .background(VisualEffectView())
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .onChange(of: model.rows.count) { _, _ in onContentChanged() }
    .onChange(of: model.status?.message) { _, _ in onContentChanged() }
    .onExitCommand(perform: onClose)
  }
}

func dropdownFrame(anchor: NSRect, contentSize: NSSize, visibleFrame: NSRect) -> NSRect {
  let bounds = visibleFrame.insetBy(dx: 4, dy: 4)
  let width = min(contentSize.width, bounds.width)
  let height = contentSize.height
  let x = max(bounds.minX, min(anchor.midX - width / 2, bounds.maxX - width))
  let y = min(anchor.minY, bounds.maxY) - height
  return NSRect(x: x, y: y, width: width, height: height)
}

@MainActor
final class DropdownWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    // Preserve the full content height, even when it exceeds the display.
    frameRect
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var dropdown: NSWindow?
  private var eventMonitor: Any?
  private var statusItem: NSStatusItem?
  private lazy var model = AppDropdownModel()

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
      let image = NSImage(systemSymbolName: "power", accessibilityDescription: "AppManager")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "AppManager: view, quit, or restart running apps"
      button.setAccessibilityLabel("AppManager")
      button.target = self
      button.action = #selector(toggleDropdown)
      button.sendAction(on: .leftMouseDown)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    closeDropdown()
  }

  @objc private func toggleDropdown() {
    if dropdown != nil {
      closeDropdown()
      return
    }
    guard let button = statusItem?.button, let buttonWindow = button.window,
      let screen = buttonWindow.screen
    else { return }
    model.refreshApps()
    let hosting = NSHostingView(
      rootView: AppDropdownView(
        model: model,
        onClose: { [weak self] in self?.closeDropdown() },
        onContentChanged: { [weak self] in self?.scheduleResize() }
      ))
    hosting.layoutSubtreeIfNeeded()
    let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let frame = dropdownFrame(
      anchor: anchor, contentSize: hosting.fittingSize, visibleFrame: screen.visibleFrame)
    let window = DropdownWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.title = "AppManager"
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.level = .statusBar
    window.hasShadow = true
    window.backgroundColor = .clear
    window.isOpaque = false
    dropdown = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    model.start()

    eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      guard let self, !self.isPointerOverStatusButton else { return }
      self.closeDropdown()
    }
  }

  private var isPointerOverStatusButton: Bool {
    guard let button = statusItem?.button, let window = button.window else { return false }
    let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
    // The button owns these clicks. Dismissing here as well can close the panel
    // before its action runs, causing that same click to open it again.
    return buttonFrame.contains(NSEvent.mouseLocation)
  }

  private func closeDropdown() {
    model.stop()
    dropdown?.close()
    dropdown = nil
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func scheduleResize() {
    DispatchQueue.main.async { [weak self] in self?.resizeDropdownToContent() }
  }

  private func resizeDropdownToContent() {
    guard let window = dropdown, let content = window.contentView,
      let button = statusItem?.button, let buttonWindow = button.window,
      let screen = buttonWindow.screen
    else { return }
    content.layoutSubtreeIfNeeded()
    let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    window.setFrame(
      dropdownFrame(
        anchor: anchor, contentSize: content.fittingSize, visibleFrame: screen.visibleFrame),
      display: true
    )
  }
}

#if !APPMANAGER_TEST
  @main
  @MainActor
  struct AppManagerMain {
    static func main() {
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      let delegate = AppDelegate()
      app.delegate = delegate
      withExtendedLifetime(delegate) { app.run() }
    }
  }
#endif
