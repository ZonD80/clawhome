//
//  Automator+Keyboard.swift
//  VZAutomation
//
//  Created by Jordan Pittman on 8/17/24.
//

import AppKit

// MARK: - Simulating the keyboard
extension VZAutomator {
  public func type(_ str: String) async throws {
    for scalar in str.unicodeScalars {
      if scalar == "\n" || scalar == "\r" {
        // Linux VMs need the actual newline character in the event, not just keyCode.
        // Key-code-only events (characters: "") are not interpreted correctly by Linux terminals.
        try await view.sendCharacter("\n", keyCode: UInt16(kVK_Return))
      } else {
        let keys = Key.from(scalar)
        if !keys.isEmpty {
          try await press(keys: keys)
        }
      }
    }
  }

  public func press(keys: [Key]) async throws {
    for key in keys {
      try await press(key: key)
      try await Task.sleep(for: .milliseconds(8))
    }
  }

  public func press(key: Key, times: Int = 1) async throws {
    for _ in 0..<times {
      await view.hold(key: key)
      await view.release(key: key)
    }
  }

  public func hold(key: Key) async throws {
    await view.hold(key: key)
  }

  public func release(key: Key) async throws {
    await view.release(key: key)
  }
}

@MainActor
extension NSView {
  typealias Key = VZAutomator.Key

  fileprivate func hold(key: Key) async {
    for event in events(type: .keyDown, for: key) {
      keyDown(with: event)
    }
  }

  fileprivate func release(key: Key) async {
    for event in events(type: .keyUp, for: key) {
      keyUp(with: event)
    }
  }

  fileprivate func events(
    type: NSEvent.EventType,
    for key: Key
  ) -> [NSEvent] {
    var list: [NSEvent] = []

    list.append(
      contentsOf: type == .keyDown
        ? events(type: type, for: key.modifiers)
        : []
    )

    list.append(contentsOf: events(type: type, flags: [], keyCode: key.code))

    list.append(
      contentsOf: type == .keyUp
        ? events(type: type, for: key.modifiers)
        : []
    )

    return list
  }

  fileprivate func events(
    type: NSEvent.EventType,
    for modifiers: VZAutomator.Modifiers
  ) -> [NSEvent] {
    var keys: [Key] = []

    keys.append(contentsOf: modifiers.contains(.shift) ? [.keyboardLeftShift] : [])
    keys.append(contentsOf: modifiers.contains(.control) ? [.keyboardLeftControl] : [])
    keys.append(contentsOf: modifiers.contains(.alt) ? [.keyboardLeftAlt] : [])
    keys.append(contentsOf: modifiers.contains(.command) ? [.keyboardLeftCommand] : [])
    keys.append(contentsOf: modifiers.contains(.fn) ? [.keyboardFunction] : [])

    return keys.flatMap { key in
      events(type: type, flags: [], keyCode: key.code)
    }
  }

  fileprivate func events(
    type: NSEvent.EventType,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16,
    characters: String = ""
  ) -> [NSEvent] {
    let event = NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: flags,
      timestamp: NSDate.now.timeIntervalSince1970,
      windowNumber: self.window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )

    guard let event else {
      return []
    }

    return [event]
  }

  /// Sends key events with the actual character string. Linux VMs need this for \n/\r
  /// because key-code-only events are not interpreted correctly by terminals.
  fileprivate func sendCharacter(_ chars: String, keyCode: UInt16) async throws {
    for event in events(type: .keyDown, flags: [], keyCode: keyCode, characters: chars) {
      keyDown(with: event)
    }
    try await Task.sleep(for: .milliseconds(8))
    for event in events(type: .keyUp, flags: [], keyCode: keyCode, characters: chars) {
      keyUp(with: event)
    }
  }
}

// MARK: - Helpers
import Carbon.HIToolbox.Events

extension VZAutomator {
  struct Modifiers: OptionSet {
    let rawValue: UInt16

    static var none: Self    = []
    static var shift: Self   = Self(rawValue: 1 << 0)
    static var control: Self = Self(rawValue: 1 << 1)
    static var alt: Self     = Self(rawValue: 1 << 2)
    static var command: Self = Self(rawValue: 1 << 3)
    static var fn: Self      = Self(rawValue: 1 << 4)
  }

  struct Key {
    let code: UInt16
    let modifiers: Modifiers

    init(code: UInt16, modifiers: Modifiers = .none) {
      self.code = code
      self.modifiers = modifiers
    }

    init(code: Int) {
      self.init(code: UInt16(code))
    }
  }
}

extension VZAutomator.Modifiers {
  var flags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []

    flags.insert(contains(.shift) ? .shift : [])
    flags.insert(contains(.control) ? .control : [])
    flags.insert(contains(.alt) ? .option : [])
    flags.insert(contains(.command) ? .command : [])
    flags.insert(contains(.fn) ? .function : [])

    return flags
  }
}

extension VZAutomator.Key {
  var control: Self { modify(.control) }
  var shift: Self { modify(.shift) }
  var alt: Self { modify(.alt) }
  var fn: Self { modify(.fn) }

  func modify(_ keys: VZAutomator.Modifiers) -> Self {
    Self(code: code, modifiers: modifiers.union(keys))
  }
}

extension VZAutomator.Key: ExpressibleByArrayLiteral {
  init(arrayLiteral elements: Int...) {
    self.init(code: elements[0])
  }
}

/// Having most of these be prefixed with `keyboard` is kinda annoying but its intended to match
/// the more modern `UIKeyboardHIDUsage` constants from UIKit — unfortunately the values are not
/// the same and must be pulled from the Carbon framework. It may be worth it just hardcoding the
/// values for all of these and removing the reliance on `Carbon.HIToolbox` entirely.
extension VZAutomator.Key {
  /// Modifiers
  static var keyboardLeftControl: Self  = [kVK_Control]       /* Left Control */
  static var keyboardLeftShift: Self    = [kVK_Shift]         /* Left Shift */
  static var keyboardLeftAlt: Self      = [kVK_Option]        /* Left Alt */
  static var keyboardLeftCommand: Self  = [kVK_Command]       /* Left Command */
  static var keyboardRightControl: Self = [kVK_RightControl]  /* Right Control */
  static var keyboardRightShift: Self   = [kVK_RightShift]    /* Right Shift */
  static var keyboardRightAlt: Self     = [kVK_RightOption]   /* Right Alt */
  static var keyboardRightCommand: Self = [kVK_RightCommand]  /* Right Command */
  static var keyboardFunction: Self     = [kVK_Function]      /* Function */

  /// Media keys
  static var keyboardVolumeMute: Self = [kVK_Mute]       /* Mute */
  static var keyboardVolumeUp: Self   = [kVK_VolumeUp]   /* Volume Up */
  static var keyboardVolumeDown: Self = [kVK_VolumeDown] /* Volume Down */
  static var keyboardPower: Self     = [0x7F]            /* Power key (kVK_Power, for shutdown shortcut) */

  /// Navigation keys
  static var keyboardPageUp: Self     = [kVK_PageUp]     /* Page Up */
  static var keyboardPageDown: Self   = [kVK_PageDown]   /* Page Down */
  static var keyboardHome: Self       = [kVK_Home]       /* Home */
  static var keyboardEnd: Self        = [kVK_End]        /* End */
  static var keyboardUpArrow: Self    = [kVK_UpArrow]    /* Up Arrow */
  static var keyboardDownArrow: Self  = [kVK_DownArrow]  /* Down Arrow */
  static var keyboardLeftArrow: Self  = [kVK_LeftArrow]  /* Left Arrow */
  static var keyboardRightArrow: Self = [kVK_RightArrow] /* Right Arrow */

  /// Function keys
  static var keyboardEsc: Self = [kVK_Escape] /* Escape */
  static var keyboardF1: Self  = [kVK_F1]     /* F1 */
  static var keyboardF2: Self  = [kVK_F2]     /* F2 */
  static var keyboardF3: Self  = [kVK_F3]     /* F3 */
  static var keyboardF4: Self  = [kVK_F4]     /* F4 */
  static var keyboardF5: Self  = [kVK_F5]     /* F5 */
  static var keyboardF6: Self  = [kVK_F6]     /* F6 */
  static var keyboardF7: Self  = [kVK_F7]     /* F7 */
  static var keyboardF8: Self  = [kVK_F8]     /* F8 */
  static var keyboardF9: Self  = [kVK_F9]     /* F9 */
  static var keyboardF10: Self = [kVK_F10]    /* F10 */
  static var keyboardF11: Self = [kVK_F11]    /* F11 */
  static var keyboardF12: Self = [kVK_F12]    /* F12 */
  static var keyboardF13: Self = [kVK_F13]    /* F13 */
  static var keyboardF14: Self = [kVK_F14]    /* F14 */
  static var keyboardF15: Self = [kVK_F15]    /* F15 */
  static var keyboardF16: Self = [kVK_F16]    /* F16 */
  static var keyboardF17: Self = [kVK_F17]    /* F17 */
  static var keyboardF18: Self = [kVK_F18]    /* F18 */
  static var keyboardF19: Self = [kVK_F19]    /* F19 */
  static var keyboardF20: Self = [kVK_F20]    /* F20 */

  /// Alphanumeric keys
  static var keyboardA: Self = [kVK_ANSI_A] /* a or A */
  static var keyboardB: Self = [kVK_ANSI_B] /* b or B */
  static var keyboardC: Self = [kVK_ANSI_C] /* c or C */
  static var keyboardD: Self = [kVK_ANSI_D] /* d or D */
  static var keyboardE: Self = [kVK_ANSI_E] /* e or E */
  static var keyboardF: Self = [kVK_ANSI_F] /* f or F */
  static var keyboardG: Self = [kVK_ANSI_G] /* g or G */
  static var keyboardH: Self = [kVK_ANSI_H] /* h or H */
  static var keyboardI: Self = [kVK_ANSI_I] /* i or I */
  static var keyboardJ: Self = [kVK_ANSI_J] /* j or J */
  static var keyboardK: Self = [kVK_ANSI_K] /* k or K */
  static var keyboardL: Self = [kVK_ANSI_L] /* l or L */
  static var keyboardM: Self = [kVK_ANSI_M] /* m or M */
  static var keyboardN: Self = [kVK_ANSI_N] /* n or N */
  static var keyboardO: Self = [kVK_ANSI_O] /* o or O */
  static var keyboardP: Self = [kVK_ANSI_P] /* p or P */
  static var keyboardQ: Self = [kVK_ANSI_Q] /* q or Q */
  static var keyboardR: Self = [kVK_ANSI_R] /* r or R */
  static var keyboardS: Self = [kVK_ANSI_S] /* s or S */
  static var keyboardT: Self = [kVK_ANSI_T] /* t or T */
  static var keyboardU: Self = [kVK_ANSI_U] /* u or U */
  static var keyboardV: Self = [kVK_ANSI_V] /* v or V */
  static var keyboardW: Self = [kVK_ANSI_W] /* w or W */
  static var keyboardX: Self = [kVK_ANSI_X] /* x or X */
  static var keyboardY: Self = [kVK_ANSI_Y] /* y or Y */
  static var keyboardZ: Self = [kVK_ANSI_Z] /* z or Z */
  static var keyboard1: Self = [kVK_ANSI_1] /* 1 or ! */
  static var keyboard2: Self = [kVK_ANSI_2] /* 2 or @ */
  static var keyboard3: Self = [kVK_ANSI_3] /* 3 or # */
  static var keyboard4: Self = [kVK_ANSI_4] /* 4 or $ */
  static var keyboard5: Self = [kVK_ANSI_5] /* 5 or % */
  static var keyboard6: Self = [kVK_ANSI_6] /* 6 or ^ */
  static var keyboard7: Self = [kVK_ANSI_7] /* 7 or & */
  static var keyboard8: Self = [kVK_ANSI_8] /* 8 or * */
  static var keyboard9: Self = [kVK_ANSI_9] /* 9 or ( */
  static var keyboard0: Self = [kVK_ANSI_0] /* 0 or ) */

  /// Numeric Keypad
  static var keypadSlash: Self    = [kVK_ANSI_KeypadDivide]   /* Keypad / */
  static var keypadAsterisk: Self = [kVK_ANSI_KeypadMultiply] /* Keypad * */
  static var keypadHyphen: Self   = [kVK_ANSI_Minus]          /* Keypad - */
  static var keypadPlus: Self     = [kVK_ANSI_KeypadPlus]     /* Keypad + */
  static var keypadEnter: Self    = [kVK_ANSI_KeypadEnter]    /* Keypad Enter */
  static var keypad1: Self        = [kVK_ANSI_Keypad1]        /* Keypad 1 or End */
  static var keypad2: Self        = [kVK_ANSI_Keypad2]        /* Keypad 2 or Down Arrow */
  static var keypad3: Self        = [kVK_ANSI_Keypad3]        /* Keypad 3 or Page Down */
  static var keypad4: Self        = [kVK_ANSI_Keypad4]        /* Keypad 4 or Left Arrow */
  static var keypad5: Self        = [kVK_ANSI_Keypad5]        /* Keypad 5 */
  static var keypad6: Self        = [kVK_ANSI_Keypad6]        /* Keypad 6 or Right Arrow */
  static var keypad7: Self        = [kVK_ANSI_Keypad7]        /* Keypad 7 or Home */
  static var keypad8: Self        = [kVK_ANSI_Keypad8]        /* Keypad 8 or Up Arrow */
  static var keypad9: Self        = [kVK_ANSI_Keypad9]        /* Keypad 9 or Page Up */
  static var keypad0: Self        = [kVK_ANSI_Keypad0]        /* Keypad 0 or Insert */
  static var keypadPeriod: Self   = [kVK_ANSI_Period]         /* Keypad . or Delete */

  /// Special Keys
  static var keyboardTab: Self            = [kVK_Tab]               /* Tab */
  static var keyboardOpenBracket: Self   = [kVK_ANSI_LeftBracket]  /* [ or { */
  static var keyboardCloseBracket: Self  = [kVK_ANSI_RightBracket] /* ] or } */
  static var keyboardBackslash: Self     = [kVK_ANSI_Backslash]    /* \ or | */

  static var keyboardCapsLock: Self      = [kVK_CapsLock]          /* Caps Lock */
  static var keyboardSemicolon: Self     = [kVK_ANSI_Semicolon]    /* ; or : */
  static var keyboardQuote: Self         = [kVK_ANSI_Quote]        /* ' or " */
  static var keyboardReturn: Self        = [kVK_Return]            /* Return (Enter) */

  static var keyboardComma: Self         = [kVK_ANSI_Comma]        /* , or < */
  static var keyboardPeriod: Self        = [kVK_ANSI_Period]       /* . or > */
  static var keyboardSlash: Self         = [kVK_ANSI_Slash]        /* / or ? */

  static var keyboardGrave: Self         = [kVK_ANSI_Grave]        /* Grave Accent and Tilde */
  static var keyboardHyphen: Self        = [kVK_ANSI_Minus]        /* - or _ */
  static var keyboardEqualSign: Self     = [kVK_ANSI_Equal]        /* = or + */
  static var keyboardDelete: Self        = [kVK_Delete]            /* Delete (Backspace) */
  static var keyboardDeleteForward: Self = [kVK_ForwardDelete]     /* Delete Forward */

  static var keyboardSpacebar: Self      = [kVK_Space]             /* Spacebar */
}

extension VZAutomator.Key {
  static func from(_ str: String) -> [Self] {
    str.unicodeScalars.flatMap { scalar in
      Self.from(scalar)
    }
  }

  static func from(_ scalar: Unicode.Scalar) -> [Self] {
    switch scalar {
    case " ": [.keyboardSpacebar]
    case " ": [.keyboardSpacebar.alt]
    case "\t": [.keyboardTab]
    case "\n": [.keyboardReturn]

    case "0": [.keyboard0]
    case "1": [.keyboard1]
    case "2": [.keyboard2]
    case "3": [.keyboard3]
    case "4": [.keyboard4]
    case "5": [.keyboard5]
    case "6": [.keyboard6]
    case "7": [.keyboard7]
    case "8": [.keyboard8]
    case "9": [.keyboard9]

    case ")": [.keyboard0.shift]
    case "!": [.keyboard1.shift]
    case "@": [.keyboard2.shift]
    case "#": [.keyboard3.shift]
    case "$": [.keyboard4.shift]
    case "%": [.keyboard5.shift]
    case "^": [.keyboard6.shift]
    case "&": [.keyboard7.shift]
    case "*": [.keyboard8.shift]
    case "(": [.keyboard9.shift]

    case "-": [.keyboardHyphen]
    case "_": [.keyboardHyphen.shift]
    case "=": [.keyboardEqualSign]
    case "+": [.keyboardEqualSign.shift]
    case "[": [.keyboardOpenBracket]
    case "{": [.keyboardOpenBracket.shift]
    case "]": [.keyboardCloseBracket]
    case "}": [.keyboardCloseBracket.shift]
    case "\\": [.keyboardBackslash]
    case "|": [.keyboardBackslash.shift]
    case ";": [.keyboardSemicolon]
    case ":": [.keyboardSemicolon.shift]
    case "'": [.keyboardQuote]
    case "\"": [.keyboardQuote.shift]
    case ",": [.keyboardComma]
    case "<": [.keyboardComma.shift]
    case ".": [.keyboardPeriod]
    case ">": [.keyboardPeriod.shift]
    case "/": [.keyboardSlash]
    case "?": [.keyboardSlash.shift]
    case "`": [.keyboardGrave]
    case "~": [.keyboardGrave.shift]

    case "º": [.keyboard0.alt]
    case "¡": [.keyboard1.alt]
    case "™": [.keyboard2.alt]
    case "£": [.keyboard3.alt]
    case "¢": [.keyboard4.alt]
    case "∞": [.keyboard5.alt]
    case "§": [.keyboard6.alt]
    case "¶": [.keyboard7.alt]
    case "•": [.keyboard8.alt]
    case "ª": [.keyboard9.alt]

    case "‚": [.keyboard0.shift.alt]
    case "⁄": [.keyboard1.shift.alt]
    case "€": [.keyboard2.shift.alt]
    case "‹": [.keyboard3.shift.alt]
    case "›": [.keyboard4.shift.alt]
    case "ﬁ": [.keyboard5.shift.alt]
    case "ﬂ": [.keyboard6.shift.alt]
    case "‡": [.keyboard7.shift.alt]
    case "°": [.keyboard8.shift.alt]
    case "·": [.keyboard9.shift.alt]

    case "a": [.keyboardA]
    case "b": [.keyboardB]
    case "c": [.keyboardC]
    case "d": [.keyboardD]
    case "e": [.keyboardE]
    case "f": [.keyboardF]
    case "g": [.keyboardG]
    case "h": [.keyboardH]
    case "i": [.keyboardI]
    case "j": [.keyboardJ]
    case "k": [.keyboardK]
    case "l": [.keyboardL]
    case "m": [.keyboardM]
    case "n": [.keyboardN]
    case "o": [.keyboardO]
    case "p": [.keyboardP]
    case "q": [.keyboardQ]
    case "r": [.keyboardR]
    case "s": [.keyboardS]
    case "t": [.keyboardT]
    case "u": [.keyboardU]
    case "v": [.keyboardV]
    case "w": [.keyboardW]
    case "x": [.keyboardX]
    case "y": [.keyboardY]
    case "z": [.keyboardZ]

    case "A": [.keyboardA.shift]
    case "B": [.keyboardB.shift]
    case "C": [.keyboardC.shift]
    case "D": [.keyboardD.shift]
    case "E": [.keyboardE.shift]
    case "F": [.keyboardF.shift]
    case "G": [.keyboardG.shift]
    case "H": [.keyboardH.shift]
    case "I": [.keyboardI.shift]
    case "J": [.keyboardJ.shift]
    case "K": [.keyboardK.shift]
    case "L": [.keyboardL.shift]
    case "M": [.keyboardM.shift]
    case "N": [.keyboardN.shift]
    case "O": [.keyboardO.shift]
    case "P": [.keyboardP.shift]
    case "Q": [.keyboardQ.shift]
    case "R": [.keyboardR.shift]
    case "S": [.keyboardS.shift]
    case "T": [.keyboardT.shift]
    case "U": [.keyboardU.shift]
    case "V": [.keyboardV.shift]
    case "W": [.keyboardW.shift]
    case "X": [.keyboardX.shift]
    case "Y": [.keyboardY.shift]
    case "Z": [.keyboardZ.shift]

    default: []
    }
  }
}
