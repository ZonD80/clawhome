//
//  Automator.swift
//  VZAutomation
//
//  Created by Jordan Pittman on 8/17/24.
//

import Virtualization

/// Automates a virtual machine attached to a `VZVirtualMachineView`
actor VZAutomator {
  let view: VZVirtualMachineView
  let clock = ContinuousClock()

  init(view: VZVirtualMachineView) {
    self.view = view
  }
}
