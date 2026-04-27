//
//  VideoView_HDR.swift
//  iina
//
//  HDR detection, EDR activation, and tone-mapping configuration.
//  Extracted from VideoView.swift so subsequent commits can layer DV / HDR10+ /
//  SDR-on-EDR / subtitle-luminance handling without ballooning the host file.
//

import Cocoa

extension VideoView {

  /// See also: `refreshAllVideoDisplayState`. Cannot execute until player is started & file is loaded.
  @MainActor
  func refreshEdrMode() {
    guard player.pwc.loaded else { return }
    guard !AppDelegate.shared.isTerminating else {
      logHDR.verbose("Aborting HDR refresh: application is terminating")
      return
    }
    guard player.info.isFileLoaded else { return }
    guard let displayId = currentDisplay else { return }
    if let screen = self.window?.screen {
      NSScreen.logEDR("Refreshing HDR for \(player.label) on display\(displayId)",
                      screen, subsystem: logHDR)
    }
    player.mpv.queue.async { [self] in
      requestEdrMode(then: { [self] edrEnabled in
        DispatchQueue.main.execOrAsync { [self] in
          let edrAvailable = edrEnabled != false
          if player.info.hdrAvailable != edrAvailable {
            player.info.hdrAvailable = edrAvailable
            player.pwc.quickSettingView.setHdrAvailability(to: edrAvailable)
          }
          if edrEnabled != true { setICCProfile() }
        }
      })
    }
  }

  /// Inspects the current mpv stream to decide whether HDR/EDR rendering is
  /// warranted, and if so, configures the layer + mpv `target-*` properties
  /// accordingly.
  ///
  /// - Parameter doAfter: Receives `true` when EDR was activated, `false`
  ///   when SDR fallback was chosen, and `nil` when EDR is available but
  ///   the user has disabled HDR support or the layer cannot accept it.
  private func requestEdrMode(then doAfter: @escaping (Bool?) -> Void) {
    assert(DispatchQueue.isExecutingIn(player.mpv.queue))
    guard let mpv = player.mpv, player.state.isNotYet(.stopping) else { return }
    guard player.state.isAtLeast(.started), player.info.isFileLoaded else {
      return doAfter(false)
    }

    guard let primaries = mpv.getString(MPVProperty.videoParamsPrimaries),
          let gamma = mpv.getString(MPVProperty.videoParamsGamma) else {
      logHDR.debug("Video gamma and primaries not available")
      return doAfter(false)
    }

    let peak = mpv.getDouble(MPVProperty.videoParamsSigPeak)
    logHDR.debug("Video gamma=\(gamma), primaries=\(primaries), sig_peak=\(peak)")

    // HDR videos use a Hybrid Log Gamma (HLG) or a Perceptual Quantization (PQ) transfer function.
    guard gamma == "hlg" || gamma == "pq" else {
      return doAfter(false)
    }

    let name: CFString
    switch primaries {
    case "display-p3":
      name = CGColorSpace.displayP3_PQ

    case "bt.2020":
      name = CGColorSpace.itur_2100_PQ

    case "bt.709":
      // SDR
      return doAfter(false)

    default:
      logHDR.warn("Unsupported color space: gamma=\(gamma) primaries=\(primaries)")
      return doAfter(false)
    }

    DispatchQueue.main.async { [self] in
      guard let window = player.pwc.window else { return }
      let maxRangeEDR = window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
      guard maxRangeEDR > 1.0 else {
        logHDR.debug("HDR video was found but the display does not support EDR mode (maxEDR=\(maxRangeEDR))")
        return doAfter(false)
      }

      guard player.info.hdrEnabled else {
        return doAfter(nil)
      }

      guard let glLayer else {
        logHDR.verbose("Aborting HDR mode: no OpenGL layer")
        return doAfter(nil)
      }

      logHDR.debug("Using HDR color space instead of ICC profile (maxEDR=\(maxRangeEDR))")
      glLayer.wantsExtendedDynamicRangeContent = true
      glLayer.colorspace = CGColorSpace(name: name)

      player.mpv.queue.async { [self] in
        guard player.isActive else {
          return doAfter(false)
        }

        mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
        mpv.setString(MPVOption.GPURendererOptions.targetPrim, primaries)
        // PQ videos will be display as it was, HLG videos will be converted to PQ
        mpv.setString(MPVOption.GPURendererOptions.targetTrc, "pq")
        mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, true)

        // Composite subtitles into the video frame *before* tone-mapping, so
        // libass output is treated as SDR content (paper-white ~203 nits) and
        // doesn't bloom to display peak luminance on EDR.
        mpv.setString(MPVOption.GPURendererOptions.blendSubtitles, "video")

        if Preference.bool(for: .enableToneMapping) {
          var targetPeak = Preference.integer(for: .toneMappingTargetPeak)
          // If the target peak is set to zero then IINA attempts to determine peak brightness of the
          // display.
          if targetPeak == 0 {
            if let displayInfo = CoreDisplay_DisplayCreateInfoDictionary(currentDisplay!)?.takeRetainedValue() as? [String: AnyObject] {
              logHDR.debug("Successfully obtained information about the display")
              // Apple Silicon Macs use the key NonReferencePeakHDRLuminance.
              if let hdrLuminance = displayInfo["NonReferencePeakHDRLuminance"] as? Int {
                logHDR.debug("Found NonReferencePeakHDRLuminance: \(hdrLuminance)")
                targetPeak = hdrLuminance
              } else if let hdrLuminance = displayInfo["DisplayBacklight"] as? Int {
                // Intel Macs use the key DisplayBacklight.
                logHDR.debug("Found DisplayBacklight: \(hdrLuminance)")
                targetPeak = hdrLuminance
              } else {
                logHDR.debug("Didn't find NonReferencePeakHDRLuminance or DisplayBacklight, assuming HDR400")
                logHDR.debug("Display info dictionary: \(displayInfo)")
                targetPeak = 400
              }
            } else {
              logHDR.warn("Unable to obtain display information, assuming HDR400")
              targetPeak = 400
            }
          }
          let algorithm = String(describing: Preference.enum(for: .toneMappingAlgorithm) as
                                 Preference.ToneMappingAlgorithmOption)

          logHDR.debug("Will enable tone mapping: target-peak=\(targetPeak) algorithm=\(algorithm)")
          mpv.setInt(MPVOption.GPURendererOptions.targetPeak, targetPeak)
          mpv.setString(MPVOption.GPURendererOptions.toneMapping, algorithm)
        } else {
          mpv.setString(MPVOption.GPURendererOptions.targetPeak, "auto")
          mpv.setString(MPVOption.GPURendererOptions.toneMapping, "")
        }
      }
      return doAfter(true)
    }
  }
}
