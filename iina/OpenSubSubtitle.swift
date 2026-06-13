//
//  OSSubtitle.swift
//  iina
//
//  Created by lhc on 11/3/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation
import Just
import PromiseKit

/// Downloader for [Open Subtitles](https://www.opensubtitles.com/).
/// - Important: This code **should not** be enhanced as the plan is to remove all built-in code for downloading subtitles and
///              replace it with plug-in implementations.
class OpenSub {
  final class Subtitle: OnlineSubtitle {

    private static let dateFormatter: DateFormatter = {
      let dateFormatter = DateFormatter()
      dateFormatter.dateStyle = .medium
      dateFormatter.timeStyle = .none
      return dateFormatter
    }()

    fileprivate let subtitle: OpenSubClient.Subtitle

    init(index: Int, subtitle: OpenSubClient.Subtitle) {
      self.subtitle = subtitle
      super.init(index: index)
    }

    /// Asynchronously download this subtitle.
    ///
    /// Downloading requires making two separate requests to [Open Subtitles](https://www.opensubtitles.com/).
    /// Despite its name, the
    /// [Download](https://opensubtitles.stoplight.io/docs/opensubtitles-api/6be7f6ae2d918-download)
    /// REST API method does not return the contents subtitle file. The response from this call contains details related to the quota
    /// imposed by `Open Subtitles` on downloads along with a link that can be used to download the subtitle file contents. Thus
    /// a second request is required to actually download the subtitle file contents.
    /// - Returns: A [URL](https://developer.apple.com/documentation/foundation/url) to the file containing
    ///            the downloaded subtitle.
    override func download() -> Promise<[URL]> {
      let fileId = subtitle.attributes.files[0].fileId
      return OpenSubClient.shared.download(fileId: fileId).then { downloadResponse in
        OpenSubClient.shared.downloadFileContents(downloadResponse.link).then { data in
          Promise { resolver in
            // This check was added after Open Subtitles returned a subtitle file of zero length.
            // Better to catch this error early to make it obvious what the problem is rather than
            // creating a zero length file that triggers a failure during loading.
            if data.isEmpty {
              resolver.reject(Error.emptyFile(
                "Subtitle file \"\(downloadResponse.fileName)\" with ID \(fileId) is empty, no contents"))
              return
            }
            let remaining = String(downloadResponse.remaining)
            let requests = String(downloadResponse.requests)
            log("Download #\(requests), remaining quota \(remaining), quota resets in \(downloadResponse.resetTime)")
            let subFilename = "[\(self.index)]\(downloadResponse.fileName)"
            guard let url = data.saveToFolder(Utility.tempDirURL, filename: subFilename) else {
              resolver.reject(OnlineSubtitle.CommonError.fsError)
              return
            }
            resolver.fulfill([url])
          }
        }
      }
    }

    /// Returns a description of this subtitle suitable for display to the user.
    /// - Returns: A tuple containing the name of this subtitle and the strings to display in the two other columns shown by the
    ///            view displayed to the user for choosing the subtitle files to download.
    override func getDescription() -> (name: String, left: String, right: String) {
      let attributes = subtitle.attributes
      var tokens: [String] = []

      tokens.append(attributes.language)

      if let releaseYear = attributes.featureDetails.year, releaseYear > 0 {
        tokens.append("(\(releaseYear))")
      }

      if let fps = attributes.fps, fps != 0 {
        tokens.append("\(fps.stringMaxFrac2) fps")
      }

      let downloadCount = "\u{2b07}\(attributes.downloadCount)"
      tokens.append(downloadCount)

      let fileName = attributes.files[0].fileName
      let description = tokens.joined(separator: "  ")
      let uploadDate = OpenSub.Subtitle.dateFormatter.string(from: attributes.uploadDate)
      return (fileName, description, uploadDate)
    }
  }

  enum Error: Swift.Error {
    // login failed (reason)
    case loginFailed(String)
    // file error
    case cannotReadFile(Swift.Error)
    case fileTooSmall(Int)
    // search failed (reason)
    case searchFailed(String)
    case emptyFile(String)
  }

  class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    typealias Subtitle = OpenSub.Subtitle

    /// `True` if currently logged in to [Open Subtitles](https://www.opensubtitles.com), `false` otherwise.
    override var loggedIn: Bool { OpenSubClient.shared.loggedIn }

    /// Minimum file size imposed by [Open Subtitles](https://www.opensubtitles.org).
    ///
    /// Open Subtitles limits the size of movies that it supports. This is documented on the wiki page
    /// [HashSourceCodes](https://trac.opensubtitles.org/projects/opensubtitles/wiki/HashSourceCodes):
    ///
    /// On opensubtitles.org is movie file size limited to **9000000000 > $moviebytesize > 131072 bytes**
    ///
    /// - Todo: Enforce the maximum file size.
    private static let minimumFileSize = 131072

    private let chunkSize: Int = 65536

    private let subChooseViewController = SubChooseViewController()

    private var languages: [String] = {
      guard let preferredLanguages = Preference.string(for: .subLang) else {
        Utility.showAlert("sub_lang_not_set")
        return ["en"]
      }
      return preferredLanguages.components(separatedBy: ",")
    }()

    /// The new OpenSubtitle API only supports a fixed set of language codes.
    /// Here we cache the result so `obtainLanguageCodes()` only needs to be called once.
    private static var supportedLanguages: [String] = []

    static let shared = Fetcher()

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      return login().then { _ in
        self.obtainLanguageCodes()
        }.then {
          self.filterLanguageCodes()
        }.then {
          self.hash(url)
        }.then { hash in
          // getMediaTitle must run on the mpv queue
          Promise<String> { resolver in
            player.mpv.queue.async {
              resolver.fulfill(player.getMediaTitle())
            }
          }.then { mediaTitle in
            self.searchForSubtitles(url, hash, mediaTitle)
          }
        }.then { subs in
          self.showSubSelectWindow(with: subs)
        }.get { [self] chosen in
          // Smart download: once the user installs a subtitle for this episode, install the same
          // release for every other episode of the series. Runs detached so it never blocks (or
          // fails) the download of the subtitle the user actually selected.
          if let representative = chosen.first {
            startSmartDownload(currentURL: url, chosen: representative, player: player)
          }
        }
    }

    /// Calculate an [Open Subtitles](https://www.opensubtitles.com/) hash code value.
    ///
    /// If a hash code is provided when searching for subtitles then `Open Subtitles` will return matching subtitles first in the
    /// response.
    ///
    /// Calculating the hash code is described in detail in the `Open Subtitles` wiki post
    /// [HashSourceCodes](https://trac.opensubtitles.org/projects/opensubtitles/wiki/HashSourceCodes).
    /// - Note: If the media is being streamed then it is not possible to calculate the hash code and `nil` will be returned.
    /// - Parameter url: Location of the media being played.
    /// - Returns: String containing the hash code or `nil`.
    func hash(_ url: URL) -> Promise<String?> {
      return Promise { resolver in
        guard url.isFileURL else {
          // Cannot create a hash when streaming.
          resolver.fulfill(nil)
          return
        }
        let file: FileHandle
        do {
          file = try FileHandle(forReadingFrom: url)
        } catch {
          resolver.reject(Error.cannotReadFile(error))
          return
        }
        defer { file.closeFile() }

        file.seekToEndOfFile()
        let fileSize = file.offsetInFile

        guard fileSize > OpenSub.Fetcher.minimumFileSize else {
          resolver.reject(Error.fileTooSmall(OpenSub.Fetcher.minimumFileSize))
          return
        }

        let offsets: [UInt64] = [0, fileSize - UInt64(chunkSize)]

        var hash = offsets.map { offset -> UInt64 in
          file.seek(toFileOffset: offset)
          return file.readData(ofLength: chunkSize).chksum64
          }.reduce(0, &+)

        hash += fileSize

        resolver.fulfill(String(format: "%016qx", hash))
      }
    }

    /// Log in to [Open Subtitles](https://www.opensubtitles.com/).
    ///
    /// The `username`/`password` parameters are used to test credentials when the user configuring the account on the
    /// `Subtitle` tab of IINA's settings. Normally the credentials will be retrieved from the macOS `Keychain`.
    ///
    /// This method detects if the user is already logged in and avoids needlessly creating a new user session.
    /// - Parameters:
    ///   - username: User name to test or `nil`.
    ///   - password: Password when testing credentials or `nil`.
    func login(testUser username: String? = nil, password: String? = nil) -> Promise<Void> {
      var finalUser: String? = username
      var finalPw: String? = password
      if finalUser == nil || finalPw == nil {
        // check logged in
        if OpenSubClient.shared.loggedIn {
          log("Already logged in to Open Subtitles")
          return .value
        }
        // read password
        if let udUsername = Preference.string(for: .openSubUsername), !udUsername.isEmpty {
          if let (_, readPassword) = try? KeychainAccess.read(username: udUsername, forService: .openSubAccount) {
            finalUser = udUsername
            finalPw = readPassword
          }
        }
      }
      guard let finalUser = finalUser, let finalPw = finalPw else {
        log("An Open Subtitles account has not been configured")
        return .value
      }
      return OpenSubClient.shared.login(username: finalUser, password: finalPw).then { response in
        Promise { resolver in
          let allowedDownloads = String(response.user.allowedDownloads)
          let vip = response.user.vip ? " as VIP" : ""
          log("Logged in to Open Subtitles\(vip), allowed downloads: \(allowedDownloads)")
          resolver.fulfill(())
        }
      }.recover { error in
        throw Error.loginFailed(error.localizedDescription)
      }
    }

    /// Obtain supported language codes.
    func obtainLanguageCodes() -> Promise<Void> {
      guard Fetcher.supportedLanguages.isEmpty else { return .value }
      return OpenSubClient.shared.languages().then { response in
        Promise { resolver in
          Fetcher.supportedLanguages = response.data.map { $0.languageCode }
          resolver.fulfill(())
        }
      }.recover { error in
        throw OnlineSubtitle.CommonError.networkError(error)
      }
    }

    /// Filter out unsupported language codes.
    ///
    /// IINA's `Preferred language` setting is used when automatically loading local subtitle files as well as when downloading
    /// from subtitle sites. As a result it may contain language codes not supported by Open Subtitles. When logging is enabled this
    /// method will log the language codes in the setting that are not supported by Open Subtitles and will be ignored. This is only
    /// done for ease of debugging.
    func filterLanguageCodes() -> Promise<Void> {
      let supportedCodes = Fetcher.supportedLanguages
      log("Preferred languages: \(languages.sorted().joined(separator: ","))")
      log("Supported languages: \(supportedCodes.sorted().joined(separator: ","))")

      var ignoredCodes: [String] = []
      var filteredCodes: [String] = []
      for language in languages {
        if supportedCodes.contains(language) {
          filteredCodes.append(language)
        } else {
          ignoredCodes.append(language)
        }
      }

      if filteredCodes.isEmpty {
        log("None of the preferred languages are supported: \(ignoredCodes); using en", level: .warning)
        filteredCodes = ["en"]
      } else if !ignoredCodes.isEmpty {
        log("The following preferred languages will be ignored: \(ignoredCodes)")
      } else {
        log("All preferred languages are supported")
      }
      languages = filteredCodes
      return .value
    }

    /// Logout of the user session.
    ///
    /// Open Subtitles requests that applications logout of of user sessions so that they can free resources. This is discussed in the
    /// [Best Practices](https://opensubtitles.stoplight.io/docs/opensubtitles-api/6ef2e232095c7-best-practices)
    /// section of the Open Subtitles REST API documentation.
    /// - Parameter timeout: The timeout to to use for the request.
    override func logout(timeout: TimeInterval? = nil) -> Promise<Void> {
      guard OpenSubClient.shared.loggedIn else {
        log("Not logged in to Open Subtitles")
        return .value
      }
      log("Logging out of Open Subtitles")
      return OpenSubClient.shared.logout(timeout: timeout).asVoid().done {
        log("Logged out of Open Subtitles")
      }
    }

    /// Search [Open Subtitles](https://www.opensubtitles.com/) for subtitles for the given movie.
    ///
    /// If no subtitles are found this method will fail with the error `noResult`.
    /// - Parameters:
    ///   - url: A [URL](https://developer.apple.com/documentation/foundation/url) to the movie to search
    ///          for subtitles for.
    ///   - hash: An [Open Subtitles](https://www.opensubtitles.com/) hash code value or `nil`.
    ///   - mediaTitle: The title of the movie.
    /// - Returns: An array containing one or more `Subtitle` objects.
    func searchForSubtitles(_ url: URL, _ hash: String?, _ mediaTitle: String) -> Promise<[Subtitle]> {
      // When streaming prefer the movie's title.
      let searchString = url.isFileURL ? url.deletingPathExtension().lastPathComponent : mediaTitle
      if let hash = hash {
        log("Searching for subtitles of movies with hash \(hash) and matching '\(searchString)'")
      } else {
        log("Searching for subtitles of movies matching '\(searchString)'")
      }
      return OpenSubClient.shared.subtitles(languages: languages, hash: hash, query: searchString).then { response in
        Promise { resolver in
          guard response.totalCount != 0 else {
            resolver.reject(OnlineSubtitle.CommonError.noResult)
            return
          }
          var result: [Subtitle] = []
          for (index, subData) in response.data.enumerated() {
            guard subData.type == "subtitle" else {
              log("Ignoring result with unexpected type: \(subData.type), subtitle ID: \(subData.id)",
                  level: .warning)
              continue
            }
            guard !subData.attributes.files.isEmpty else {
              // Should not occur according to the Open Subtitles REST API documentation which
              // indicates this array must contain at least one entry. However results returned
              // have sometimes violated other documented behavior so it is critical to validate
              // the data returned.
              log("Ignoring result missing file information, subtitle ID: \(subData.id)",
                  level: .warning)
              continue
            }
            result.append(Subtitle(index: index, subtitle: subData))
          }
          guard !result.isEmpty else {
            // The normal case where no subtitles were found is caught above. The subtitles returned
            // must have been ignored.
            resolver.reject(OnlineSubtitle.CommonError.noResult)
            return
          }
          resolver.fulfill((result))
        }
      }.recover { error -> Promise<[Subtitle]> in
        switch error {
        case OnlineSubtitle.CommonError.noResult:
          throw error
        default:
          throw Error.searchFailed(error.localizedDescription)
        }
      }
    }

    func showSubSelectWindow(with subs: [Subtitle]) -> Promise<[Subtitle]> {
      return Promise { resolver in
        // return when found 0 or 1 sub
        if subs.count <= 1 {
          resolver.fulfill(subs)
          return
        }
        subChooseViewController.loadIfNeeded()
        subChooseViewController.subtitles = subs
        subChooseViewController.context = self

        subChooseViewController.userDoneAction = { subs in
          resolver.fulfill(subs as! [Subtitle])
        }
        subChooseViewController.userCanceledAction = {
          resolver.reject(OnlineSubtitle.CommonError.canceled)
        }
        DispatchQueue.main.async { [self] in
          PlayerManager.shared.activePlayer?.sendOSD(.foundSub(subs.count), autoHide: false, accessoryViewController: subChooseViewController)
          subChooseViewController.tableView.reloadData()
        }
      }
    }

    // MARK: - Smart Download

    /// After the user installs a subtitle for the current episode, automatically install the same
    /// release for every other episode of the series found in the playlist or the current file's
    /// folder, saving each next to its video file so IINA auto-loads it on playback.
    ///
    /// Each episode costs one search + one download against the Open Subtitles quota; processing is
    /// sequential to respect the API rate limiter, idempotent (episodes that already have a subtitle
    /// are skipped), and best-effort (a failure for one episode never aborts the rest).
    func startSmartDownload(currentURL: URL, chosen: Subtitle, player: PlayerCore) {
      guard currentURL.isFileURL else { return }
      let chosenName = chosen.subtitle.attributes.files[0].fileName
      let playlistURLs = player.info.playlist.map { $0.url }.filter { $0.isFileURL }
      let siblings = Fetcher.gatherSiblings(of: currentURL, playlistURLs: playlistURLs)
      guard !siblings.isEmpty else {
        OpenSub.log("Smart download: no sibling episodes found for \(currentURL.lastPathComponent.pii.quoted)")
        return
      }
      OpenSub.log("Smart download: \(siblings.count) sibling episode(s) to process")

      var installed = 0
      var chain: Promise<Void> = .value
      for sib in siblings {
        chain = chain.then { [self] _ -> Promise<Void> in
          if Fetcher.adjacentSubtitleExists(for: sib) {
            OpenSub.log("Smart download: \(sib.lastPathComponent.pii.quoted) already has a subtitle, skipping")
            return .value
          }
          return installMatchingSubtitle(forSibling: sib, chosenName: chosenName)
            .get { savedURL in
              guard let savedURL else { return }
              installed += 1
              // IINA only scans the folder for matching subs once (when a single file is opened to
              // build the playlist), with mpv's own `sub-auto` disabled. A sibling already in the
              // playlist would therefore never see this just-written file. Register it directly so
              // the existing external-sub load path picks it up — and auto-selects it — when that
              // episode starts. Keyed by the same path `getMatchedSubs` reads (`PlaybackID.path`).
              player.info.$matchedSubs.withLock { $0[sib.path, default: []].append(savedURL) }
            }
            .asVoid()
            .recover { error -> Promise<Void> in
              OpenSub.log("Smart download failed for \(sib.lastPathComponent.pii.quoted): "
                          + "\(error.localizedDescription)", level: .warning)
              return .value
            }
        }
      }
      chain.done {
        OpenSub.log("Smart download complete: installed \(installed) subtitle(s)")
        guard installed > 0 else { return }
        let count = installed
        DispatchQueue.main.async {
          player.sendOSD(.downloadedSub(
            "Smart download: installed subtitles for \(count) more episode\(count == 1 ? "" : "s")"))
        }
      }.cauterize()
    }

    /// Search Open Subtitles for `sibling` (by hash + filename) and save the best matching release
    /// next to it. Returns the saved subtitle URL, or `nil` if nothing was installed.
    private func installMatchingSubtitle(forSibling sibling: URL, chosenName: String) -> Promise<URL?> {
      return hash(sibling).recover { _ in Promise<String?>.value(nil) }.then { [self] hash -> Promise<URL?> in
        let query = sibling.deletingPathExtension().lastPathComponent
        return OpenSubClient.shared.subtitles(languages: languages, hash: hash, query: query)
          .then { response -> Promise<URL?> in
            let candidates = response.data.filter { $0.type == "subtitle" && !$0.attributes.files.isEmpty }
            guard let best = Fetcher.bestCandidate(among: candidates, matching: chosenName) else {
              OpenSub.log("Smart download: no usable subtitle for \(sibling.lastPathComponent.pii.quoted)")
              return .value(nil)
            }
            return self.downloadAndSave(best, nextTo: sibling)
          }
      }
    }

    /// Download the contents of `candidate` and write it next to `video` using the video's base name
    /// (so IINA matches it). Returns the saved file URL, or `nil` on failure.
    private func downloadAndSave(_ candidate: OpenSubClient.Subtitle, nextTo video: URL) -> Promise<URL?> {
      let file = candidate.attributes.files[0]
      return OpenSubClient.shared.download(fileId: file.fileId).then { downloadResponse in
        OpenSubClient.shared.downloadFileContents(downloadResponse.link).map { data -> URL? in
          guard !data.isEmpty else { return nil }
          var ext = (file.fileName as NSString).pathExtension.lowercased()
          if ext.isEmpty || !(Utility.supportedFileExt[.sub]?.contains(ext) ?? false) {
            ext = "srt"
          }
          let base = video.deletingPathExtension().lastPathComponent
          let target = video.deletingLastPathComponent().appendingPathComponent("\(base).\(ext)")
          do {
            try data.write(to: target)
          } catch {
            OpenSub.log("Smart download: cannot write \(target.lastPathComponent.pii.quoted): "
                        + "\(error.localizedDescription)", level: .warning)
            return nil
          }
          OpenSub.log("Smart download: installed \(target.lastPathComponent.pii.quoted)")
          return target
        }
      }
    }

    /// Collect file URLs that are the same series as `currentURL` but a different episode, gathered
    /// from the playlist and the current file's directory, deduplicated and excluding the current
    /// file itself.
    static func gatherSiblings(of currentURL: URL, playlistURLs: [URL]) -> [URL] {
      let currentName = currentURL.deletingPathExtension().lastPathComponent
      let videoExts = Utility.supportedFileExt[.video] ?? []
      var seen = Set<String>([currentURL.standardizedFileURL.path])
      var result: [URL] = []

      func consider(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !seen.contains(path),
              videoExts.contains(url.pathExtension.lowercased()),
              SmartSubtitleMatcher.isSameSeriesDifferentEpisode(
                currentName, url.deletingPathExtension().lastPathComponent) else { return }
        seen.insert(path)
        result.append(url)
      }

      playlistURLs.forEach(consider)

      let dir = currentURL.deletingLastPathComponent()
      if let entries = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        entries.forEach(consider)
      }
      return result
    }

    /// `true` if a subtitle file with the same base name as `video` already sits next to it.
    static func adjacentSubtitleExists(for video: URL) -> Bool {
      let base = video.deletingPathExtension().lastPathComponent.lowercased()
      let subExts = Utility.supportedFileExt[.sub] ?? []
      let dir = video.deletingLastPathComponent()
      guard let entries = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
      return entries.contains { url in
        subExts.contains(url.pathExtension.lowercased())
          && url.deletingPathExtension().lastPathComponent.lowercased() == base
      }
    }

    /// Pick, among an episode's search results (already correct for that episode because the search
    /// is keyed on the file's hash & name), the one whose release best matches the user's chosen
    /// subtitle. Ties break toward the more popular subtitle.
    static func bestCandidate(among candidates: [OpenSubClient.Subtitle],
                              matching chosenName: String) -> OpenSubClient.Subtitle? {
      guard !candidates.isEmpty else { return nil }
      return candidates.max { a, b in
        let sa = SmartSubtitleMatcher.releaseSimilarity(chosenName, a.attributes.files[0].fileName)
        let sb = SmartSubtitleMatcher.releaseSimilarity(chosenName, b.attributes.files[0].fileName)
        if sa != sb { return sa < sb }
        return a.attributes.downloadCount < b.attributes.downloadCount
      }
    }
  }

  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.opensub)
  }
}

extension Logger.Sub {
  static let opensub = Logger.makeSubsystem("opensub")
}
