//
//  Platform.swift
//  BrightMove
//
//  Cross-platform (AppKit / UIKit) type aliases and helpers so the MapKit
//  bridging code can compile on both macOS and iOS.
//

import SwiftUI

extension Color {
    /// The standard control / card background, mapped per platform.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

#if os(macOS)
import AppKit

typealias PlatformView = NSView
typealias PlatformColor = NSColor
typealias PlatformEdgeInsets = NSEdgeInsets
typealias PlatformHostingController = NSHostingController

/// A view that hosts SwiftUI content and sizes itself to fit.
typealias PlatformHostingView = NSHostingView

extension NSColor {
    /// The system accent / tint colour, spelled the same on both platforms.
    static var platformAccent: NSColor { .controlAccentColor }
}

extension NSView {
    /// The view's preferred size for the current content.
    var platformFittingSize: CGSize { fittingSize }
}

#else
import UIKit

typealias PlatformView = UIView
typealias PlatformColor = UIColor
typealias PlatformEdgeInsets = UIEdgeInsets
typealias PlatformHostingController = UIHostingController

extension UIColor {
    static var platformAccent: UIColor { .tintColor }
}

/// A UIKit equivalent of `NSHostingView`: a `UIView` that embeds a SwiftUI
/// `rootView` via a child `UIHostingController` and adopts its intrinsic size.
final class PlatformHostingView<Content: View>: UIView {
    private let hostingController: UIHostingController<Content>

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var rootView: Content {
        get { hostingController.rootView }
        set { hostingController.rootView = newValue }
    }

    /// Size that fits the hosted SwiftUI content.
    var fittingSize: CGSize {
        hostingController.sizeThatFits(in: UIView.layoutFittingCompressedSize)
    }
}

extension UIView {
    var platformFittingSize: CGSize {
        systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    /// The frontmost view controller able to present, walking up from this
    /// view's window. Used to present popovers/sheets from a UIKit-backed
    /// `UIViewRepresentable` that has no direct view-controller reference.
    var topmostViewController: UIViewController? {
        var root = window?.rootViewController
        while let presented = root?.presentedViewController {
            root = presented
        }
        return root
    }
}
#endif
