//
//  FsWatcher.swift
//  Logseq
//
//  Created by Mono Wang on 2/17/R4.
//

import Foundation
import Capacitor

// MARK: Watcher Plugin

@objc(FsWatcher)
public class FsWatcher: CAPPlugin, PollingWatcherDelegate {
    private var watcher: PollingWatcher? = nil
    private var baseUrl: URL? = nil
    
    override public func load() {
        print("debug FsWatcher iOS plugin loaded!")
    }
    
    @objc func watch(_ call: CAPPluginCall) {
        if let path = call.getString("path") {
            guard let url = URL(string: path) else {
                call.reject("can not parse url")
                return
            }
            self.baseUrl = url
            self.watcher = PollingWatcher(at: url)
            self.watcher?.delegate = self
            
            call.resolve(["ok": true])
            
        } else {
            call.reject("missing path string parameter")
        }
    }
    
    @objc func unwatch(_ call: CAPPluginCall) {
        watcher?.stop()
        watcher = nil
        baseUrl = nil
        
        call.resolve()
    }
    
    public func recevedNotification(_ url: URL, _ event: PollingWatcherEvent, _ metadata: SimpleFileMetadata?) {
        // NOTE: Event in js {dir path content stat{mtime}}
        switch event {
        case .Unlink:
            self.notifyListeners("watcher", data: ["event": "unlink",
                                                   "dir": baseUrl?.description as Any,
                                                   "path": url.description,
                                                  ])
        case .Add:
            let content = try? String(contentsOf: url, encoding: .utf8)
            self.notifyListeners("watcher", data: ["event": "add",
                                                   "dir": baseUrl?.description as Any,
                                                   "path": url.description,
                                                   "content": content as Any,
                                                   "stat": ["mtime": metadata?.contentModificationTimestamp,
                                                            "ctime": metadata?.creationTimestamp]
                                                  ])
        case .Change:
            let content = try? String(contentsOf: url, encoding: .utf8)
            self.notifyListeners("watcher", data: ["event": "change",
                                                   "dir": baseUrl?.description as Any,
                                                   "path": url.description,
                                                   "content": content as Any,
                                                   "stat": ["mtime": metadata?.contentModificationTimestamp,
                                                            "ctime": metadata?.creationTimestamp]])
        case .Error:
            // TODO: handle error?
            break
        }
    }
}

// MARK: URL extension

extension URL {
    func isSkipped() -> Bool {
        // skip hidden file
        if self.lastPathComponent.starts(with: ".") {
            return true
        }
        // NOTE: used by file-sync
        if self.lastPathComponent == "graphs-txid.edn" {
            return true
        }
        let allowedPathExtensions: Set = ["md", "markdown", "org", "css", "edn", "excalidraw"]
        if allowedPathExtensions.contains(self.pathExtension.lowercased()) {
            return false
        }
        // skip for other file types
        return true
    }
    
    func isICloudPlaceholder() -> Bool {
        if self.lastPathComponent.starts(with: ".") && self.pathExtension.lowercased() == "icloud" {
            return true
        }
        return false
    }
}

// MARK: PollingWatcher

public protocol PollingWatcherDelegate {
    func recevedNotification(_ url: URL, _ event: PollingWatcherEvent, _ metadata: SimpleFileMetadata?)
}

public enum PollingWatcherEvent: String {
    case Add
    case Change
    case Unlink
    case Error
}

public struct SimpleFileMetadata: CustomStringConvertible, Equatable {
    var contentModificationTimestamp: Double
    var creationTimestamp: Double
    var fileSize: Int
    
    public init?(of fileURL: URL) {
        do {
            let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
            if fileAttributes.isRegularFile! {
                contentModificationTimestamp = fileAttributes.contentModificationDate?.timeIntervalSince1970 ?? 0.0
                creationTimestamp = fileAttributes.creationDate?.timeIntervalSince1970 ?? 0.0
                fileSize = fileAttributes.fileSize ?? 0
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }
    
    public var description: String {
        return "Meta(size=\(self.fileSize), mtime=\(self.contentModificationTimestamp), ctime=\(self.creationTimestamp)"
    }
}

public class PollingWatcher {
    private let url: URL
    private var timer: DispatchSourceTimer?
    public var delegate: PollingWatcherDelegate? = nil
    private var metaDb: [URL: SimpleFileMetadata] = [:]
    
    public init?(at: URL) {
        url = at
        
        let queue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".timer")
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer!.setEventHandler(qos: .background, flags: []) { [weak self] in
            self?.tick()
        }
        timer!.schedule(deadline: .now())
        timer!.resume()
        
    }
    
    deinit {
        self.stop()
    }
    
    public func stop() {
        timer?.cancel()
        timer = nil
    }
    
    private func tick() {
        // let startTime = DispatchTime.now()
        
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey],
            // NOTE: icloud downloading requires non-skipsHiddenFiles
            options: [.skipsPackageDescendants]) {
            
            var newMetaDb: [URL: SimpleFileMetadata] = [:]
            
            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey]),
                      let isDirectory = resourceValues.isDirectory,
                      let isRegularFile = resourceValues.isRegularFile,
                      let name = resourceValues.name
                else {
                    continue
                }
                
                if isDirectory {
                    // NOTE: URL.path won't end with a `/`
                    if fileURL.path.hasSuffix("/logseq/bak") || name == ".recycle" || name.hasPrefix(".") || name == "node_modules" {
                        enumerator.skipDescendants()
                    }
                }
            
                if isRegularFile && !fileURL.isSkipped() {
                    if let meta = SimpleFileMetadata(of: fileURL) {
                        newMetaDb[fileURL] = meta
                    }
                } else if fileURL.isICloudPlaceholder() {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                }
            }
            
            self.updateMetaDb(with: newMetaDb)
        }
        
        // let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        // let elapsedInMs = Double(elapsedNanoseconds) / 1_000_000
        // print("debug ticker elapsed=\(elapsedInMs)ms")
        
        if #available(iOS 13.0, *) {
            timer?.schedule(deadline: .now().advanced(by: .seconds(2)), leeway: .milliseconds(100))
        } else {
            // Fallback on earlier versions
            timer?.schedule(deadline: .now() + 2.0, leeway: .milliseconds(100))
        }
    }
    
    // TODO: batch?
    private func updateMetaDb(with newMetaDb: [URL: SimpleFileMetadata]) {
        for (url, meta) in newMetaDb {
            if let idx = self.metaDb.index(forKey: url) {
                let (_, oldMeta) = self.metaDb.remove(at: idx)
                if oldMeta != meta {
                    self.delegate?.recevedNotification(url, .Change, meta)
                }
            } else {
                self.delegate?.recevedNotification(url, .Add, meta)
            }
        }
        for url in self.metaDb.keys {
            self.delegate?.recevedNotification(url, .Unlink, nil)
        }
        self.metaDb = newMetaDb
    }
}
