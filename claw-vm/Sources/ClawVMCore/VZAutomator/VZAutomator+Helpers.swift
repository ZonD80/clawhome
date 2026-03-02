//
//  Automator+Utils.swift
//  VZAutomation
//
//  Created by Jordan Pittman on 8/17/24.
//

// MARK: - Helpers
extension VZAutomator {
  /// Wait for a callback to return true
  internal func wait(until callback: () async throws -> Bool) async throws {
    while true {
      try await clock.sleep(for: .milliseconds(50))

      if try await callback() {
        return
      }
    }
  }
}
