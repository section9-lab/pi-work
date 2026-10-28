import CryptoKit
import Darwin
import Foundation
import MachO

enum AgentRuntimeArchive {
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ installation: AgentRuntimeInstallation) throws {
        let manager = FileManager.default
        let requestedDirectory = installation.directory
        guard try requestedDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AgentRuntimeError.integrity
        }
        // Foundation normalizes /private/var to /var, whereas its directory
        // enumerator returns /private/var. POSIX gives both paths one spelling.
        guard let resolved = realpath(requestedDirectory.path, nil) else { throw AgentRuntimeError.integrity }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        guard
              let enumerator = manager.enumerator(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                options: [], errorHandler: { _, _ in false }
              ) else { throw AgentRuntimeError.integrity }
        var found = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw AgentRuntimeError.integrity }
            guard url.path.hasPrefix(directory.path + "/") else { throw AgentRuntimeError.integrity }
            let path = String(url.path.dropFirst(directory.path.count + 1))
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw AgentRuntimeError.integrity }
            if path == "installed.json" { continue }
            guard let expected = installation.manifest.files[path],
                  try digest(of: url) == expected else { throw AgentRuntimeError.integrity }
            found.insert(path)
        }
        guard found == Set(installation.manifest.files.keys),
              manager.isExecutableFile(atPath: installation.executableURL.path),
              manager.isExecutableFile(atPath: installation.bunURL.path)
        else { throw AgentRuntimeError.integrity }
        for executable in [installation.executableURL, installation.bunURL] {
            guard try supportsArchitecture(executable, architecture: installation.manifest.architecture) else {
                throw AgentRuntimeError.incompatible
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--strict", "--all-architectures", executable.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AgentRuntimeError.integrity }
        }
    }

    /// Inspect the platform format directly: lipo is a developer-tool shim and
    /// must not cause end users to be asked to install Xcode Command Line Tools.
    private static func supportsArchitecture(_ executable: URL, architecture: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4096) else { return false }
        let bytes = Array(data)
        func word(_ offset: Int, littleEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let positions = littleEndian ? Array((offset..<offset + 4).reversed()) : Array(offset..<offset + 4)
            return positions.reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }
        }
        let expected = UInt32(bitPattern: architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64)
        guard let magic = word(0) else { return false }
        switch magic {
        case MH_MAGIC_64, MH_CIGAM_64:
            return word(4, littleEndian: magic == MH_CIGAM_64) == expected
        case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
            let littleEndian = magic == FAT_CIGAM || magic == FAT_CIGAM_64
            let stride = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64 ? 32 : 20
            guard let count = word(4, littleEndian: littleEndian), count > 0, count <= 64,
                  8 + Int(count) * stride <= bytes.count else { return false }
            return (0..<Int(count)).contains { word(8 + $0 * stride, littleEndian: littleEndian) == expected }
        default:
            return false
        }
    }

    /// Read the publisher's USTAR stream ourselves so links, devices, duplicate
    /// entries and path traversal are rejected *before* anything is extracted.
    /// gzip is the OS implementation; no downloaded archiver is executed.
    static func extract(_ archive: URL, to directory: URL, manifest: AgentRuntimeManifest) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", archive.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var reader = TarReader(handle: pipe.fileHandleForReading)
        var found = Set<String>()
        while true {
            let header = try reader.read(512)
            if header.allSatisfy({ $0 == 0 }) {
                guard try reader.read(512).allSatisfy({ $0 == 0 }),
                      found == Set(manifest.files.keys) else { throw AgentRuntimeError.invalidArchive }
                // USTAR writers may pad their last record with zero blocks.
                while let padding = try pipe.fileHandleForReading.read(upToCount: 512), !padding.isEmpty {
                    reader.consumed += padding.count
                    guard reader.consumed <= AgentRuntimeManifest.maximumExpandedBytes,
                          padding.allSatisfy({ $0 == 0 }) else { throw AgentRuntimeError.invalidArchive }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AgentRuntimeError.invalidArchive }
                return
            }
            guard String(bytes: header[257..<262], encoding: .ascii) == "ustar" else {
                throw AgentRuntimeError.invalidArchive
            }
            let checksum = try reader.octal(header[148..<156])
            var checkHeader = header
            checkHeader.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
            guard checkHeader.reduce(0, { $0 + Int($1) }) == checksum else {
                throw AgentRuntimeError.invalidArchive
            }
            let name = try reader.string(header[0..<100])
            let prefix = try reader.string(header[345..<500])
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let size = try reader.octal(header[124..<136])
            // Packages deliberately contain only regular files, never directories or links.
            guard header[156] == 0 || header[156] == 48,
                  AgentRuntimeManifest.isPayloadPath(path),
                  manifest.files[path] != nil, found.insert(path).inserted,
                  size <= AgentRuntimeManifest.maximumExpandedBytes - reader.consumed
            else { throw AgentRuntimeError.invalidArchive }
            let destination = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw AgentRuntimeError.invalidArchive
            }
            let output = try FileHandle(forWritingTo: destination)
            do {
                var remaining = size
                while remaining > 0 {
                    let length = min(remaining, 1024 * 1024)
                    try output.write(contentsOf: Data(try reader.read(length)))
                    remaining -= length
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            _ = try reader.read((512 - size % 512) % 512)
            try FileManager.default.setAttributes(
                [.posixPermissions: [AgentHostExecutable.filename, AgentHostExecutable.bunFilename].contains(path) ? 0o755 : 0o644],
                ofItemAtPath: destination.path
            )
        }
    }

    private struct TarReader {
        let handle: FileHandle
        var consumed = 0

        mutating func read(_ count: Int) throws -> [UInt8] {
            try Task.checkCancellation()
            guard count >= 0, count <= AgentRuntimeManifest.maximumExpandedBytes - consumed else {
                throw AgentRuntimeError.invalidArchive
            }
            var data = Data()
            while data.count < count {
                guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                    throw AgentRuntimeError.invalidArchive
                }
                data.append(next)
            }
            consumed += count
            return Array(data)
        }

        func string(_ bytes: ArraySlice<UInt8>) throws -> String {
            guard let string = String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) else {
                throw AgentRuntimeError.invalidArchive
            }
            return string
        }

        func octal(_ bytes: ArraySlice<UInt8>) throws -> Int {
            let text = try string(bytes).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.allSatisfy({ ("0"..."7").contains(String($0)) }),
                  let value = Int(text, radix: 8) else { throw AgentRuntimeError.invalidArchive }
            return value
        }
    }
}
