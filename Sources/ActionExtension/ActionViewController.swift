//
//  ActionViewController.swift
//  UntrackerAction
//
//  Action Extension (com.apple.ui-services): appears in the share sheet's "Actions"
//  row and in Safari's action menu. iOS presents extension sheets at a large height
//  that the extension cannot control, so this variant does the work and closes
//  immediately — one tap puts the clean link on the clipboard, which is the closest
//  iOS equivalent of Android's "select text → Untrack".
//

import UIKit

final class ActionViewController: UntrackerExtensionViewController {
    override var copiesImmediately: Bool { true }
}