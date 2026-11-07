import Foundation
import IOKit.pwr_mgt

public struct PowerSnapshot: Codable, Equatable, Sendable {
  public var lidClosed: Bool?
  public var sleepDisabled: Bool?
  public var preventsSystemSleep: Bool?
  public var preventsIdleSleep: Bool?
  public var preventsDisplaySleep: Bool?
  public var userActive: Bool?
  public static func read() -> Self {
    var dictionary: Unmanaged<CFDictionary>?
    let result = IOPMCopyAssertionsStatus(&dictionary)
    let values = dictionary?.takeRetainedValue()
    let assertions = result == kIOReturnSuccess ? values as? [String: Int] : nil
    return Self(
      lidClosed: Power.lidClosed(), sleepDisabled: Power.flag("SleepDisabled"),
      preventsSystemSleep: assertions?[kIOPMAssertionTypePreventSystemSleep].map { $0 != 0 },
      preventsIdleSleep: assertions?[kIOPMAssertionTypePreventUserIdleSystemSleep].map { $0 != 0 },
      preventsDisplaySleep: assertions?[kIOPMAssertionTypePreventUserIdleDisplaySleep].map {
        $0 != 0
      },
      userActive: assertions?["UserIsActive"].map { $0 != 0 })
  }
}
