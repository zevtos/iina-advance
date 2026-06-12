//
//  SubChooseViewController.swift
//  iina
//
//  Created by Collider LI on 4/3/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class SubChooseViewController: NSViewController {
  override var nibName: NSNib.Name {
    return NSNib.Name("SubChooseViewController")
  }

  @IBOutlet weak var tableView: NSTableView!
  @IBOutlet weak var downloadBtn: NSButton!

  var subtitles: [OnlineSubtitle] = []

  var userDoneAction: (([OnlineSubtitle]) -> Void)?
  var userCanceledAction: Callback?

  var context: Any?

  override func viewDidLoad() {
    super.viewDidLoad()

    if let scrollView = tableView.enclosingScrollView {
      scrollView.wantsLayer = true
      if #available(macOS 26, *) {
        scrollView.layer?.cornerRadius = 10
      } else {
        scrollView.layer?.cornerRadius = 6
      }

      // The scroll view has no intrinsic height. Its only height source in the XIB is a
      // priority-99 (>= 200) constraint on the root view, which loses to the OSD stack view's
      // vertical hugging (500), collapsing the table to zero height. Pin a minimum height with
      // a priority high enough to win against the stack view, but below the window's required
      // layout constraints.
      let minHeightConstraint = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 156)
      minHeightConstraint.priority = .init(600)
      minHeightConstraint.isActive = true
    }
    view.setContentCompressionResistancePriority(.init(600), for: .vertical)

    tableView.delegate = self
    tableView.dataSource = self

    // Download subtitle when table view row is double clicked
    tableView.target = self
    tableView.doubleAction = #selector(downloadBtnAction(_:))
  }

  @IBAction func downloadBtnAction(_ sender: Any) {
    guard let userDoneAction = userDoneAction else { return }
    userDoneAction(tableView.selectedRowIndexes.map { subtitles[$0] })
    PlayerManager.shared.activePlayer?.hideOSD()
    context = nil
  }

  @IBAction func cancelBtnAction(_ sender: Any) {
    guard let userCanceledAction = userCanceledAction else { return }
    userCanceledAction()
    PlayerManager.shared.activePlayer?.hideOSD()
    context = nil
  }
}


extension SubChooseViewController: NSTableViewDelegate, NSTableViewDataSource {

  func numberOfRows(in tableView: NSTableView) -> Int {
    return subtitles.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let (name, left, right) = subtitles[row].getDescription()
    return ["name": name, "left": left, "right": right]
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    return tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "SubCell"), owner: self)
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    downloadBtn.isEnabled = tableView.selectedRow != -1
  }
}
