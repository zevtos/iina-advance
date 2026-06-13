//
//  SmartSubtitleMatcher.swift
//  iina
//
//  Filename heuristics for "smart download": once the user installs a subtitle for one episode,
//  IINA can match the same release to every other episode of the series.
//

import Foundation

/// The core operation is a *structural diff* of two filenames. Two episodes of the same series,
/// named by the same release, differ only in a single run of digits — the episode number. This is
/// far more reliable than guessing an `SxxExx` pattern, and naturally covers `S01E05`/`S01E06`,
/// `1x05`/`1x06`, `EP05`/`EP06`, and anime `- 05`/`- 06` naming alike.
enum SmartSubtitleMatcher {

  /// Split a string into maximal alternating runs of digit / non-digit characters.
  private static func tokenize(_ s: String) -> [(text: Substring, isDigits: Bool)] {
    var tokens: [(Substring, Bool)] = []
    var i = s.startIndex
    while i < s.endIndex {
      let isDigit = s[i].isASCII && s[i].isNumber
      var j = i
      while j < s.endIndex, (s[j].isASCII && s[j].isNumber) == isDigit {
        j = s.index(after: j)
      }
      tokens.append((s[i..<j], isDigit))
      i = j
    }
    return tokens
  }

  /// If `a` and `b` are the same series named the same way, differing in exactly one numeric run,
  /// returns the episode numbers `(inA, inB)`. Otherwise `nil`.
  ///
  /// Comparison is case-insensitive. Pass names *without* file extension for best results.
  static func episodeDifference(_ a: String, _ b: String) -> (Int, Int)? {
    let ta = tokenize(a.lowercased())
    let tb = tokenize(b.lowercased())
    guard ta.count == tb.count, !ta.isEmpty else { return nil }

    var diffIndex: Int?
    for k in 0..<ta.count {
      guard ta[k].isDigits == tb[k].isDigits else { return nil }
      if ta[k].text == tb[k].text { continue }
      // A non-digit run differs → different release or series. Reject.
      guard ta[k].isDigits else { return nil }
      // More than one differing digit run → ambiguous (e.g. season + episode both changed). Reject.
      guard diffIndex == nil else { return nil }
      diffIndex = k
    }
    guard let d = diffIndex, let ea = Int(ta[d].text), let eb = Int(tb[d].text) else { return nil }
    return (ea, eb)
  }

  /// `true` if `a` and `b` are the same series, same release, but a different episode.
  static func isSameSeriesDifferentEpisode(_ a: String, _ b: String) -> Bool {
    guard let (ea, eb) = episodeDifference(a, b) else { return false }
    return ea != eb
  }

  /// Lowercased alphanumeric tokens of length ≥ 2 that are not pure numbers — i.e. the parts of a
  /// release name that stay constant across episodes (group, resolution, codec, source…).
  static func releaseTokens(_ name: String) -> Set<String> {
    var tokens = Set<String>()
    var current = ""
    func flush() {
      if current.count >= 2, current.contains(where: { !$0.isNumber }) {
        tokens.insert(current)
      }
      current = ""
    }
    for ch in name.lowercased() {
      if ch.isLetter || ch.isNumber {
        current.append(ch)
      } else {
        flush()
      }
    }
    flush()
    return tokens
  }

  /// `true` if `name` references `episode` in an episode context — `E04`/`E4`, `EP04`, `1x04`, or a
  /// dash form like `- 04`. Deliberately does NOT match a bare season (`S04`) or resolution (`x264`,
  /// `1080`), so it won't confuse the season number with the episode number.
  static func containsEpisodeNumber(_ name: String, _ episode: Int) -> Bool {
    let pattern = "(?:e|ep|x|[-–])\\s?0*\(episode)(?!\\d)"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return false
    }
    let range = NSRange(name.startIndex..., in: name)
    return re.firstMatch(in: name, options: [], range: range) != nil
  }

  /// Similarity in `[0, 1]` between two subtitle/release filenames, ignoring episode/season numbers.
  /// Used to pick, among an episode's search results, the one matching the user's chosen release.
  static func releaseSimilarity(_ a: String, _ b: String) -> Double {
    let sa = releaseTokens(a), sb = releaseTokens(b)
    guard !sa.isEmpty, !sb.isEmpty else { return 0 }
    let shared = sa.intersection(sb).count
    return Double(shared) / Double(max(sa.count, sb.count))
  }
}
