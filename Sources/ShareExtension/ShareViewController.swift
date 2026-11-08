//
//  ShareViewController.swift
//  UntrackerShare
//
//  Share Extension (com.apple.share-services): appears in the share sheet's app row.
//  This is the one-tap copy path: no UI at all, the clean link goes straight to the
//  clipboard with a success haptic, and the share sheet closes by itself. The bottom
//  quick action (Action Extension) is the one that shows the review panel.
//

import UIKit

final class ShareViewController: UntrackerExtensionViewController {
    /// One tap from the app row is the whole interaction: copy and get out of the way.
    override var copiesImmediately: Bool { true }
}
