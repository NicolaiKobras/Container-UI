import Foundation

private let containerBinary = "/usr/local/bin/container" // adjust this

actor ContainerService {
    enum ServiceError: Error {
        case commandFailed(exit: Int32, output: String)
        case parseError(String)
    }

    // Runs a shell command and returns stdout as String (throws if exit != 0)
    func runCommand(_ launchPath: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let out = String(decoding: outData, as: UTF8.self)
        let err = String(decoding: errData, as: UTF8.self)

        if process.terminationStatus != 0 {
            throw ServiceError.commandFailed(exit: process.terminationStatus, output: out + "\n" + err)
        }

        return out
    }

    // Parse `container list --all` output into models.
    // Example input line:
    // ID           IMAGE                             OS     ARCH   STATE    ADDR
    // pgvector-db  docker.io/pgvector/pgvector:pg17  linux  arm64  running  192.168.64.2
    func parseContainerList(_ text: String) -> [ContainerModel] {
        var lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 0 else { return [] }

        // If first line looks like a header, drop it
        if let first = lines.first,
           first.lowercased().contains("id") && first.lowercased().contains("image") {
            lines.removeFirst()
        }

        var models: [ContainerModel] = []

        // Split each row by whitespace, but the IMAGE column can contain spaces? Usually not — we will parse by fixed columns heuristic:
        // We'll use a regex that tries to parse: ID (whitespace) IMAGE (whitespace) OS (whitespace) ARCH (whitespace) STATE (whitespace) ADDR(optional)
        // Since IMAGE may contain ":" and "/" but no spaces, this is OK.
        let pattern = #"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(\S+))?$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        for raw in lines {
            if let regex = regex,
               let match = regex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: raw.utf16.count)) {
                func substring(_ idx: Int) -> String? {
                    guard idx <= match.numberOfRanges - 1 else { return nil }
                    let r = match.range(at: idx)
                    guard r.location != NSNotFound, let range = Range(r, in: raw) else { return nil }
                    return String(raw[range])
                }
                let id = substring(1) ?? ""
                let image = substring(2) ?? ""
                let os = substring(3)
                let arch = substring(4)
                let state = substring(5) ?? ""
                let addr = substring(6)

                let m = ContainerModel(id: id, image: image, os: os, arch: arch, state: state, running: state == "running", addr: addr, mounts: [])
                models.append(m)
                continue
            }

            // If regex didn't match try a whitespace split fallback (less strict)
            let parts = raw.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map { String($0) }
            if parts.count >= 5 {
                let id = parts[0]
                let image = parts[1]
                let os = parts[2]
                let arch = parts[3]
                let state = parts[4]
                let addr = parts.count >= 6 ? parts[5] : nil
                let m = ContainerModel(id: id, image: image, os: os, arch: arch, state: state, running: state=="running", addr: addr, mounts: [])
                models.append(m)
            } else {
                // skip unparseable line
                continue
            }
        }

        return models
    }

    // Parse system status output into readable string(s)
    // Example:
    // apiserver is running
    // application data root: /Users/...
    func parseSystemStatus(_ text: String) -> String {
        // Find the line containing "apiserver is"
        if let statusLine = text
            .split(separator: "\n")
            .first(where: { $0.lowercased().contains("apiserver is") }) {
            // Return the full line, trimmed of surrounding whitespace
            return statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback if no status line found
        return "unknown"
    }

    // Determine if the system is running based on status output
    func isSystemRunning(from text: String) -> Bool {
        // Normalize
        let lower = text.lowercased()
        // Consider running if we find "apiserver is running"
        if lower.contains("apiserver is running") { return true }
        // Explicitly handle the stopped example: "apiserver is not running and not registered with launchd"
        if lower.contains("apiserver is not running") { return false }
        // Fallback: unknown -> false
        return false
    }

    private struct ContainerJSON: Decodable {
        struct Platform: Decodable { let os: String?; let architecture: String? }
        struct Image: Decodable { let reference: String? }
        struct Network: Decodable { let address: String? }
        struct MountTypeVolume: Decodable { let format: String?; let name: String? }
        struct MountType: Decodable { let volume: MountTypeVolume? }
        struct Mount: Decodable { let options: [String]?; let source: String?; let type: MountType?; let destination: String? }
        struct Config: Decodable {
            let id: String?
            let platform: Platform?
            let image: Image?
            let networks: [Network]?
            let mounts: [Mount]?
        }
        let status: String?
        let networks: [Network]? // top-level networks (for gateway/address/hostname)
        let configuration: Config?
    }

    private struct ImageJSON: Decodable { let reference: String?; let size: String? }
    private struct VolumeJSON: Decodable {
        let name: String?
        let mountpoint: String?
        let source: String?
        let driver: String?
        let labels: [String: String]?
        let options: [String: String]?
        let createdAt: TimeInterval?
        let format: String?
    }

    // Public API: fetch containers list using the `container` CLI
    func listAllContainers() async throws -> [ContainerModel] {
        // Ask the CLI for structured JSON
        let output = try await runCommand(containerBinary, args: ["list", "--all", "--format", "json"])

        // Decode JSON array
        let data = Data(output.utf8)
        let decoder = JSONDecoder()

        let items: [ContainerJSON]
        do {
            items = try decoder.decode([ContainerJSON].self, from: data)
        } catch {
            // Fallback to legacy parsing if JSON decode fails
            return parseContainerList(output)
        }

        // Map into our lightweight view model
        let models: [ContainerModel] = items.map { item in
            // Prefer configuration fields, fall back to top-level if present
            let cfg = item.configuration
            let id = cfg?.id ?? ""
            let imageRef = cfg?.image?.reference ?? ""
            let os = cfg?.platform?.os
            let arch = cfg?.platform?.architecture
            let state = item.status ?? "unknown"

            // Best-effort address extraction: try top-level networks first, otherwise configuration networks
            let addr: String? = {
                if let n = item.networks?.first?.address, !n.isEmpty { return n }
                if let n = cfg?.networks?.first?.address, !n.isEmpty { return n }
                return nil
            }()

            let mounts: [ContainerMount] = (cfg?.mounts ?? []).map { m in
                let v = m.type?.volume
                return ContainerMount(
                    source: m.source,
                    destination: m.destination,
                    volumeName: v?.name,
                    format: v?.format
                )
            }

            return ContainerModel(id: id, image: imageRef, os: os, arch: arch, state: state, running: state == "running", addr: addr, mounts: mounts)
        }

        return models
    }

    func listAllImages() async throws -> [ImageModel] {
        let output = try await runCommand(containerBinary, args: ["images", "list", "--format", "json"])
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        do {
            let items = try decoder.decode([ImageJSON].self, from: data)
            return items.map { ImageModel(id: $0.reference ?? "", size: $0.size) }
        } catch {
            // Fallback: parse by lines (reference size)
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 1 else { return nil }
                let ref = String(parts[0])
                let size = parts.count > 1 ? String(parts[1]) : nil
                return ImageModel(id: ref, size: size)
            }
        }
    }

    func listAllVolumes() async throws -> [VolumeModel] {
        let output = try await runCommand(containerBinary, args: ["volume", "list", "--format", "json"])
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        do {
            let items = try decoder.decode([VolumeJSON].self, from: data)
            return items.map { VolumeModel(
                id: $0.name ?? "",
                mountpoint: $0.mountpoint,
                source: $0.source,
                driver: $0.driver,
                labels: $0.labels,
                options: $0.options,
                createdAt: $0.createdAt,
                format: $0.format
            ) }
        } catch {
            // Fallback: parse by whitespace columns: NAME MOUNTPOINT
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 1 else { return nil }
                let name = String(parts[0])
                let mp = parts.count > 1 ? String(parts[1]) : nil
                return VolumeModel(id: name, mountpoint: mp, source: nil, driver: nil, labels: nil, options: nil, createdAt: nil, format: nil)
            }
        }
    }

    // Public API: get system status
    func systemStatus() async throws -> String {
        let output = try await runCommand(containerBinary, args: ["system", "status"])
        return parseSystemStatus(output)
    }
    
    // Public API: stop container
    func stopContainer(containerId: String) async throws -> Bool {
        _ = try await runCommand(containerBinary, args: ["stop", containerId])
        return true
    }
    
    func deleteContainer(containerId: String) async throws -> Bool {
        _ = try await runCommand(containerBinary, args: ["delete", containerId])
        return true
    }
    
    // Public API: start container
    func startContainer(containerId: String) async throws -> Bool {
        
        _ = try await runCommand(containerBinary, args: ["start", containerId])
        return true
    }
    
    func startSystem() async throws -> Bool {
        _ = try await runCommand(containerBinary, args: ["system", "start"])
        return true
    }
    
    func stopSystem() async throws -> Bool {
        _ = try await runCommand(containerBinary, args: ["system", "stop"])
        return true
    }

    // Public API: create volume
    func createVolume(name: String, size: String? = nil, options: [String] = [], labels: [String] = []) async throws -> Bool {
        var args: [String] = ["volume", "create", name]
        if let size = size, !size.isEmpty {
            args.append(contentsOf: ["-s", size])
        }
        for opt in options where !opt.isEmpty {
            args.append(contentsOf: ["--opt", opt])
        }
        for label in labels where !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }
        print(args)
        _ = try await runCommand(containerBinary, args: args)
        return true
    }
    
    // Public API: delete volume
    func deleteVolume(name: String) async throws -> Bool {
        _ = try await runCommand(containerBinary, args: ["volume", "delete", name])
        return true
    }

    // Public API: create container (with volumes)
    func createContainer(name: String, image: String, volumeMappings: [String: String]) async throws -> Bool {
        // Build args using --volume <name>:<target>
        var args: [String] = ["create", "--name", name]
        for (vol, target) in volumeMappings.sorted(by: { $0.key < $1.key }) {
            let trimmedVol = vol.trimmingCharacters(in: .whitespaces)
            let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
            guard !trimmedVol.isEmpty, !trimmedTarget.isEmpty else { continue }
            args.append(contentsOf: ["--volume", "\(trimmedVol):\(trimmedTarget)"])
        }
        args.append(image)
        print(args)
        _ = try await runCommand(containerBinary, args: args)
        return true
    }
}