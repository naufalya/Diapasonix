// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Launch presentation only: users remain free to resize in either direction.
/// SwiftUI's defaultSize alone is superseded by macOS window restoration.
struct WorkspaceWindowPresentation: NSViewRepresentable {
  func makeNSView(context: Context) -> LaunchView { LaunchView() }
  func updateNSView(_ view: LaunchView, context: Context) {}

  final class LaunchView: NSView {
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !Self.configuredWindows.contains(window) else { return }
      Self.configuredWindows.add(window)
      // Let AppKit present the registered asset-catalog icon. Assigning the
      // raw ICNS to applicationIconImage bypasses the native Dock treatment.
      DispatchQueue.main.async { [weak window] in
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(1_440, visible.width, visible.height * 16 / 9)
        let height = width * 9 / 16
        window.setFrame(NSRect(x: visible.midX - width / 2,
          y: visible.midY - height / 2, width: width, height: height), display: true)
      }
    }
  }
}
