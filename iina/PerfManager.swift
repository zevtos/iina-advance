//
//  PerfManager.swift
//  iina
//
//  Tracks power source and thermal pressure. Emits a notification so player
//  cores can throttle expensive GPU work (heavy GLSL shaders, RIFE-style
//  vapoursynth filters) when the laptop is on battery or running hot.
//
//  Phase 1d release blocker per docs/phase1a/architecture.md §7.
//

import Cocoa
import IOKit.ps

extension Notification.Name {
  /// Posted by `PerfManager` whenever the active power/thermal profile changes.
  /// `userInfo["profile"]` is the new `PerfManager.Profile` raw value.
  static let iinaPerfProfileChanged = Notification.Name("iinaPerfProfileChanged")
}

final class PerfManager {

  /// Output profile. Higher cases imply more aggressive throttling.
  enum Profile: Int, Comparable {
    case full = 0          // AC + nominal: leave user config alone
    case batterySaver = 1  // unplugged: clear shaders, disable RIFE
    case thermalWarn = 2   // thermalState ≥ .serious: + simpler tone-map
    case emergency = 3     // thermalState == .critical: kill GPU work

    var shouldClearShaders: Bool { self >= .batterySaver }
    var shouldDisableRIFE: Bool  { self >= .batterySaver }
    var shouldUseSimpleToneMap: Bool { self >= .thermalWarn }
    var shouldDisableHDR: Bool { self == .emergency }

    static func < (lhs: Profile, rhs: Profile) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short label for OSC indicator, e.g. "🔋", "🌡️", "⚠️", "" (none).
    var oscBadge: String {
      switch self {
      case .full: return ""
      case .batterySaver: return "🔋"
      case .thermalWarn: return "🌡️"
      case .emergency: return "⚠️"
      }
    }
  }

  /// User-facing override.
  enum UserMode: Int {
    case auto = 0          // follow battery/thermal automatically
    case alwaysFull = 1    // ignore battery/thermal
    case alwaysSaver = 2   // permanently in batterySaver+ regardless of state

    init(prefValue: Int) {
      self = UserMode(rawValue: prefValue) ?? .auto
    }
  }

  static let shared = PerfManager()

  private(set) var currentProfile: Profile = .full

  private var powerSourceRunLoopSource: CFRunLoopSource?
  private var thermalObserver: NSObjectProtocol?
  private var prefObserver: NSObjectProtocol?
  private var hasStarted = false

  private init() {}

  // MARK: - Lifecycle

  /// Begin observing power and thermal state. Idempotent.
  func startObserving() {
    guard !hasStarted else { return }
    hasStarted = true

    // Power source. IOPSNotificationCreateRunLoopSource fires on every change
    // (battery <-> AC, % drained, etc); we re-evaluate on each tick.
    let context = Unmanaged.passUnretained(self).toOpaque()
    let src = IOPSNotificationCreateRunLoopSource({ ctx in
      guard let ctx = ctx else { return }
      Unmanaged<PerfManager>.fromOpaque(ctx).takeUnretainedValue().reevaluate()
    }, context).takeRetainedValue()
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    powerSourceRunLoopSource = src

    // Thermal pressure.
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.reevaluate() }

    // User pref override.
    prefObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.reevaluate() }

    reevaluate()
  }

  func stopObserving() {
    if let src = powerSourceRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
      powerSourceRunLoopSource = nil
    }
    if let obs = thermalObserver {
      NotificationCenter.default.removeObserver(obs)
      thermalObserver = nil
    }
    if let obs = prefObserver {
      NotificationCenter.default.removeObserver(obs)
      prefObserver = nil
    }
    hasStarted = false
  }

  // MARK: - State

  /// `true` when the system reports running on battery, false on AC or unknown.
  static var isOnBattery: Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
    let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    return (providing as String?) == kIOPSBatteryPowerValue
  }

  // MARK: - Decision

  /// Recompute the desired profile from current power/thermal/pref state and
  /// emit the change notification if it differs from the previous profile.
  func reevaluate() {
    let userMode = UserMode(prefValue: Preference.integer(for: .batteryMode))
    let battery = Self.isOnBattery
    let thermal = ProcessInfo.processInfo.thermalState

    let newProfile: Profile
    switch userMode {
    case .alwaysFull:
      newProfile = .full
    case .alwaysSaver:
      newProfile = max(.batterySaver, thermalProfile(thermal))
    case .auto:
      let powerProfile: Profile = battery ? .batterySaver : .full
      newProfile = max(powerProfile, thermalProfile(thermal))
    }

    guard newProfile != currentProfile else { return }
    let oldProfile = currentProfile
    currentProfile = newProfile

    Logger.log.verbose("Perf profile changed: \(oldProfile) → \(newProfile) "
                       + "(battery=\(battery), thermal=\(thermal.rawValue), userMode=\(userMode.rawValue))")

    NotificationCenter.default.post(
      name: .iinaPerfProfileChanged, object: self,
      userInfo: ["profile": newProfile.rawValue, "previous": oldProfile.rawValue]
    )
  }

  private func thermalProfile(_ state: ProcessInfo.ThermalState) -> Profile {
    switch state {
    case .nominal, .fair: return .full
    case .serious: return .thermalWarn
    case .critical: return .emergency
    @unknown default: return .full
    }
  }
}
