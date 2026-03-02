//
//  Automator+VM.swift
//  VZAutomation
//
//  Created by Jordan Pittman on 8/17/24.
//

import Virtualization

// MARK: - Waiting for the VM
extension VZAutomator {
  /// Wait for the VM to be in a given state
  public func wait(forState state: VZVirtualMachine.State) async throws {
    try await wait {
      await view.virtualMachine?.state == state
    }
  }
}
