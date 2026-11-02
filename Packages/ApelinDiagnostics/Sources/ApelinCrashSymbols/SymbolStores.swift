// Ported from Xrash (XrashKit/Sources/XrashSymbols/SymbolStores.swift, owngoal-dev/Xrash at 9dcfb4d).
// Copyright (c) 2026 OwnGoal Studio. MIT License: see LICENSE beside this folder's sources.

import Foundation

/// Why a store could not take in what it was given.
public enum SymbolStoreFailure: Error, Equatable {
    /// Nothing under the path was a Mach-O with a UUID: the wrong folder, an
    /// archive that was never unpacked, a dSYM for another architecture.
    case noDebugSymbols
}

public struct DSYMRecord: Codable, Hashable, Sendable, Identifiable {
    /// The image UUID, uppercase and dashed — what reports are matched on.
    public var id: String
    /// `Fila` for `Fila.app.dSYM/Contents/Resources/DWARF/Fila`.
    public var binaryName: String
    public var arch: String
    public var byteCount: UInt64
    public var imported: Date

    public init(id: String, binaryName: String, arch: String, byteCount: UInt64, imported: Date) {
        self.id = id
        self.binaryName = binaryName
        self.arch = arch
        self.byteCount = byteCount
        self.imported = imported
    }
}

/// Imported dSYMs, copied into `directory` and indexed by UUID.
public final class DSYMStore: DSYMLookup, @unchecked Sendable {
    /// Posted after a mutation, outside the store lock, on the caller's thread.
    public static let didChangeNotification = Notification.Name("DSYMStore.didChange")

    private struct Index: Codable {
        var revision = 0
        var records = [DSYMRecord]()
    }

    private let directory: URL
    private let indexURL: URL
    // ponytail: one lock for the whole store. Imports are rare and a lookup is
    // a dictionary hit; per-record locking would buy nothing measurable.
    private let lock = NSLock()
    private var index = Index()

    public init(directory: URL) {
        self.directory = directory
        indexURL = directory.appendingPathComponent("index.plist")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            if let stored = try? PropertyListDecoder().decode(Index.self, from: data) {
                index = stored
            } else {
                // Never written over by the next import: kept beside it, and
                // the store starts afresh (its files are found again by UUID).
                let aside = indexURL.deletingLastPathComponent()
                    .appendingPathComponent("index.plist.unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: indexURL, to: aside)
            }
        }
    }

    /// Bumped by every import and removal; symbolication caches key on it.
    public var revision: Int {
        lock.withLock { index.revision }
    }

    public var records: [DSYMRecord] {
        lock.withLock { index.records }
    }

    /// A `.dSYM` bundle, a bare DWARF Mach-O, or a directory holding either.
    /// One record per architecture slice found.
    ///
    /// A zip is unpacked before it gets here: a store that also unpacked would
    /// own two ways of being wrong about a path. Pass the directory it was
    /// unpacked into.
    public func importDSYM(at url: URL) throws -> [DSYMRecord] {
        var imported = [DSYMRecord]()
        // A folder of dSYMs often holds the stripped binaries beside them, and
        // those carry the same UUID. Whichever the file system lists last would
        // otherwise win and take the line numbers with it.
        var uuidsWithDWARF = Set<String>()
        for candidate in Self.machOFiles(at: url, depth: 4) {
            guard let handle = try? FileHandle(forReadingFrom: candidate),
                  let data = try? Data.mapping(handle),
                  let slices = try? MachOSlice.slices(of: data)
            else { continue }
            for slice in slices {
                guard let uuid = slice.uuid else { continue }
                let debugLine = slice.section(segment: "__DWARF", name: "__debug_line") != nil
                guard debugLine || !uuidsWithDWARF.contains(uuid.uuidString) else { continue }
                if debugLine {
                    uuidsWithDWARF.insert(uuid.uuidString)
                }
                imported.removeAll { $0.id == uuid.uuidString }
                let stored = storedURL(for: uuid.uuidString)
                if slices.count == 1, slice.byteCount == UInt64(data.count) {
                    // The common case: a thin dSYM. Copying the file keeps its
                    // bytes off the heap, which matters for a large app's dSYM.
                    try? FileManager.default.removeItem(at: stored)
                    try FileManager.default.copyItem(at: candidate, to: stored)
                } else {
                    try slice.bytes.write(to: stored, options: .atomic)
                }
                imported.append(DSYMRecord(
                    id: uuid.uuidString,
                    binaryName: candidate.lastPathComponent,
                    arch: slice.arch,
                    byteCount: slice.byteCount,
                    imported: Date(),
                ))
            }
        }
        guard !imported.isEmpty else { throw SymbolStoreFailure.noDebugSymbols }

        lock.withLock {
            for record in imported {
                index.records.removeAll { $0.id == record.id }
                index.records.append(record)
            }
            index.revision += 1
            save()
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return imported
    }

    public func remove(uuid: String) throws {
        let changed = lock.withLock {
            guard index.records.contains(where: { $0.id == uuid }) else { return false }
            index.records.removeAll { $0.id == uuid }
            index.revision += 1
            save()
            try? FileManager.default.removeItem(at: storedURL(for: uuid))
            return true
        }
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The stored DWARF file for an image UUID.
    public func url(forUUID uuid: String) -> URL? {
        let uuid = uuid.uppercased()
        return lock.withLock {
            guard index.records.contains(where: { $0.id == uuid }) else { return nil }
            let url = storedURL(for: uuid)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func storedURL(for uuid: String) -> URL {
        directory.appendingPathComponent("\(uuid.uppercased()).dwarf")
    }

    private func save() {
        guard let data = try? PropertyListEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Everything under `url` that might be a Mach-O: the file itself, the
    /// `Contents/Resources/DWARF` of a `.dSYM`, or whatever a folder of dSYMs
    /// holds. Bounded, because a dropped folder can be the whole home directory.
    static func machOFiles(at url: URL, depth: Int) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }

        let dwarf = url.appendingPathComponent("Contents/Resources/DWARF")
        if manager.fileExists(atPath: dwarf.path) {
            return (try? manager.contentsOfDirectory(at: dwarf, includingPropertiesForKeys: nil)) ?? []
        }
        guard depth > 0 else { return [] }
        let children = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.prefix(256).flatMap { machOFiles(at: $0, depth: depth - 1) }
    }
}

// Apelin: Xrash's SystemSymbolStore (dyld shared cache extraction) is not
// ported. It is the only part that needed MachOKit, and Apelin symbolicates
// its own project images from the dSYM the build kept; system frames keep
// the names the report already carries.
