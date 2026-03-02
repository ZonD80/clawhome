//
//  Automator+Display.swift
//  VZAutomation
//
//  Created by Jordan Pittman on 8/17/24.
//

import AppKit
import QuartzCore
import CoreGraphics
import CoreImage
import Metal

// MARK: - Detecting that the display is active
extension VZAutomator {
  /// Wait for the display to be active (frame buffer available)
  public func waitForDisplay() async throws {
    try await wait {
      await frameBuffer != nil
    }
  }
}

// MARK: - Screenshots
extension VZAutomator {
  /// Take a screenshot of the display
  @MainActor
  public func screenshot(rect: CGRect? = nil) async throws -> NSImage? {
    try await withSurface { surface in
      var display = CIImage(ioSurface: surface)

      if let rect {
        display = display.cropped(to: rect)
      }

      let context: CIContext
      if let device = MTLCreateSystemDefaultDevice() {
        context = CIContext(mtlDevice: device)
      } else {
        context = CIContext(options: [.useSoftwareRenderer: false])
      }
      guard let cgImage = context.createCGImage(display, from: display.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
      else {
        let rep = NSCIImageRep(ciImage: display)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
      }
      let bitmap = NSBitmapImageRep(cgImage: cgImage)
      let image = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
      image.addRepresentation(bitmap)
      return image
    }
  }
}

// MARK: - Helpers
extension VZAutomator {
  @MainActor
  var frameBuffer: IOSurface? {
    return view.subviews.first?.layer?.contents as? IOSurface
  }

  /// Lock required for CPU access to IOSurface: synchronizes GPU-rendered framebuffer to CPU-visible
  /// memory. Without it, reading pixel data could return stale or partially-updated frames.
  @MainActor
  private func withSurface<T>(_ cb: (IOSurface) async throws -> T) async throws -> T? {
    guard
      let frameBufferView = view.subviews.first,
      let surface = frameBufferView.layer?.contents as? IOSurface
    else {
      return nil
    }

    surface.lock(options: .readOnly, seed: nil)

    let result = try await cb(surface)

    surface.unlock(options: .readOnly, seed: nil)

    return result
  }
}
