//
//  ChapterSkip.swift
//  iina
//
//  Smart classification of chapters as opening / ending / credits, used by the auto-skip toggles.
//

import Foundation

/// Decides whether a chapter is an opening, ending, or credits section so it can be auto-skipped.
///
/// Detection is primarily by chapter **title** — releases that bother to mark chapters almost always
/// name them ("Opening", "OP", "ED", "Ending", "Credits", "NCOP"…). A rich, multilingual keyword set
/// plus prefix/version handling (`OP`, `OP1`, `op_v2`, `Opening 2`, `NCED`…) covers the overwhelming
/// majority of real files.
///
/// When a chapter has a generic or empty title (`Chapter 3`, `Part B`, `5`, …) a **conservative**
/// positional fallback is used: a short chapter at the very start may be an opening; a short chapter
/// at the very end may be credits. Thresholds are deliberately tight to avoid skipping real content.
enum ChapterSkip {

  enum Kind: String, CustomStringConvertible {
    case opening, ending, credits
    var description: String { rawValue }

    var preferenceKey: Preference.Key {
      switch self {
      case .opening: return .autoSkipOpening
      case .ending: return .autoSkipEnding
      case .credits: return .autoSkipCredits
      }
    }
  }

  /// Information about one chapter, all readable on the mpv queue.
  struct ChapterInfo {
    let title: String?
    let index: Int
    let startTime: Double
    /// End of this chapter = start of the next chapter, or the file duration for the last chapter.
    let endTime: Double
    let chapterCount: Int
    let duration: Double
  }

  // MARK: Keyword sets (normalized: lowercased, separators → spaces)

  /// Whole-word tokens, or a `keyword` followed by an optional version/number (`op`, `op2`, `opv2`).
  private static let openingKeywords: Set<String> = [
    "op", "ncop", "opening", "intro", "avant",
    "опенинг", "оп", "вступление", "заставка", "интро"
  ]
  private static let endingKeywords: Set<String> = [
    "ed", "nced", "ending", "outro", "closing",
    "эндинг", "концовка", "аутро"
  ]
  private static let creditsKeywords: Set<String> = [
    "credits", "credit", "staff", "staffroll", "endcard", "endcards",
    "титры", "субтитры"  // note: "субтитры" (subtitles) is rare as a chapter name; harmless if matched under the credits toggle
  ]

  /// Generic, content-free titles that carry no information ("Chapter 3", "Part B", "5", "").
  private static func isGenericTitle(_ normalized: String) -> Bool {
    if normalized.isEmpty { return true }
    let tokens = normalized.split(separator: " ").map(String.init)
    // Drop leading "chapter"/"part"/"глава"/"часть" markers, then anything left must be a plain number/letter.
    let markers: Set<String> = ["chapter", "ch", "part", "глава", "гл", "часть"]
    let rest = tokens.filter { !markers.contains($0) }
    if rest.isEmpty { return true }
    return rest.allSatisfy { tok in
      tok.allSatisfy { $0.isNumber } || (tok.count == 1 && tok.first!.isLetter)
    }
  }

  // MARK: Detection

  /// Result of classifying a chapter. `viaHeuristic` is `true` when the kind was inferred from
  /// position/duration rather than the title — an *untitled* end section in particular can't be
  /// told apart as ending vs credits, so the caller treats a heuristic `.credits` as satisfying
  /// either the ending or the credits toggle.
  struct Match {
    let kind: Kind
    let viaHeuristic: Bool
  }

  /// Returns the skip classification for a chapter, or `nil` if it should not be auto-skipped.
  static func classify(_ chapter: ChapterInfo) -> Match? {
    let normalized = normalize(chapter.title ?? "")

    // 1) Title keyword match — the reliable path, and the only way to tell ending from credits.
    if let kind = keywordKind(of: normalized) {
      return Match(kind: kind, viaHeuristic: false)
    }

    // 2) Conservative positional fallback for untitled / generic chapters only.
    guard isGenericTitle(normalized), chapter.duration > 0, chapter.chapterCount >= 2 else {
      return nil
    }
    let chapterLength = chapter.endTime - chapter.startTime
    guard chapterLength > 0 else { return nil }

    // Classic opening: a short (≤ 2 min) chapter that begins within the first 6 minutes and is not
    // the only thing at the start (there is real content after it).
    if chapterLength <= 120, chapter.startTime <= 360, chapter.index < chapter.chapterCount - 1 {
      return Match(kind: .opening, viaHeuristic: true)
    }
    // Classic end section: a short-ish chapter in the last 15% of the file that runs to its end.
    // Untitled, so it could be the ED, the credits, or both — reported as `.credits` + heuristic.
    let nearEnd = chapter.startTime >= chapter.duration * 0.85
    let runsToEnd = chapter.endTime >= chapter.duration - 1
    if nearEnd, runsToEnd, chapterLength <= 300 {
      return Match(kind: .credits, viaHeuristic: true)
    }
    return nil
  }

  /// Whether `match` should be skipped given the current toggle preferences. An untitled end section
  /// (heuristic `.credits`) is skipped when *either* the ending or the credits toggle is enabled.
  static func shouldSkip(_ match: Match) -> Bool {
    if match.viaHeuristic, match.kind == .credits {
      return Preference.bool(for: .autoSkipCredits) || Preference.bool(for: .autoSkipEnding)
    }
    return Preference.bool(for: match.kind.preferenceKey)
  }

  /// Lowercase, turn separators (`._-`, brackets) into spaces, collapse runs of spaces, trim.
  static func normalize(_ title: String) -> String {
    var out = ""
    out.reserveCapacity(title.count)
    for ch in title.lowercased() {
      if ch.isLetter || ch.isNumber {
        out.append(ch)
      } else {
        out.append(" ")
      }
    }
    return out.split(separator: " ").joined(separator: " ")
  }

  /// Match any token against a keyword set, allowing a trailing version/number and an optional `v`
  /// (so `op`, `op2`, `opv2`, `opening1`, `nced` all match).
  private static func keywordKind(of normalized: String) -> Kind? {
    let tokens = normalized.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }
    for token in tokens {
      let core = stripTrailingVersion(token)
      if openingKeywords.contains(core) { return .opening }
      if endingKeywords.contains(core) { return .ending }
      if creditsKeywords.contains(core) { return .credits }
    }
    return nil
  }

  /// `opv2` → `op`, `opening1` → `opening`, `ed02` → `ed`. Leaves non-versioned tokens untouched.
  private static func stripTrailingVersion(_ token: String) -> String {
    var end = token.endIndex
    // Strip trailing digits.
    while end > token.startIndex, token[token.index(before: end)].isNumber {
      end = token.index(before: end)
    }
    // Strip a single trailing 'v' (version marker) if it left digits behind it.
    if end < token.endIndex, end > token.startIndex, token[token.index(before: end)] == "v" {
      end = token.index(before: end)
    }
    let core = String(token[token.startIndex..<end])
    return core.isEmpty ? token : core
  }
}
