import SwiftUI
import Foundation
import Combine

private let containerBinary = "/usr/local/bin/container" // adjust this

// MARK: - Models

struct ContainerModel: Identifiable, Equatable {
    let id: String
    let image: String
    let os: String?
    let arch: String?
    let state: String
    let running: Bool
    let addr: String?
    let mounts: [ContainerMount]
}

struct ContainerMount: Equatable, Identifiable {
    let id = UUID()
    let source: String?
    let destination: String?
    let volumeName: String?
    let format: String?
}

struct ImageModel: Identifiable, Equatable {
    let id: String
    let size: String?
}

struct VolumeModel: Identifiable, Equatable {
    let id: String
    let mountpoint: String?
    let source: String?
    let driver: String?
    let labels: [String: String]?
    let options: [String: String]?
    let createdAt: TimeInterval?
    let format: String?
}

// MARK: - Service (CLI-based)

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

// MARK: - View Model

@MainActor
class ContainerViewModel: ObservableObject {
    @Published var containers: [ContainerModel] = []
    @Published var systemStatus: String = "Unknown"
    @Published var isSystemRunning: Bool = false
    @Published var errorMessage: String?

    @Published var images: [ImageModel] = []
    @Published var volumes: [VolumeModel] = []

    private let service = ContainerService()
    private var pollingTask: Task<Void, Never>? = nil

    func refresh() {
        Task {
            do {
                async let status = service.systemStatus()
                async let containers = service.listAllContainers()
                async let images = service.listAllImages()
                async let volumes = service.listAllVolumes()

                //let (s, c, imgs, vols) = try await (status, containers, images, volumes)

                self.systemStatus = try await status
                self.isSystemRunning = await self.service.isSystemRunning(from: self.systemStatus)
                self.containers = try await containers
                self.images = try await images
                self.volumes = try await volumes
                self.errorMessage = nil
            } catch {
                self.errorMessage = "\(error)"
                self.systemStatus = "Error"
                self.isSystemRunning = false
                self.containers = []
                self.images = []
                self.volumes = []
            }
        }
    }
    
    func getRunningContainersAmount() -> Int {
        return containers.filter { $0.running || $0.state.lowercased() == "running" }.count
    }
    
    func startPolling(interval seconds: TimeInterval = 1.0) {
        // Avoid multiple concurrent polling tasks
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            // Initial immediate refresh
            await MainActor.run { self?.refresh() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch { /* cancellation */ }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    func startSystem() {
        do {
            Task{
                _ = try await service.startSystem()
            }
        } catch {
            self.errorMessage = "Failed to start system: \(error)"
        }
        refresh()
    }
    
    func stopSystem() {
        do {
            Task {
                _ = try await service.stopSystem()
            }
        } catch {
            self.errorMessage = "Failed to stop system: \(error)"
        }
        refresh()
    }
    
    func startContainer(_ id: String) async {
        do {
            let container = containers.first(where: { $0.id == id })
            if container != nil {
                if(!container!.running) {
                    _ = try await service.startContainer(containerId: id)
                }
            } else {
                throw NSError(domain: "ContainerViewModel", code: 404, userInfo: [NSLocalizedDescriptionKey: "Container not found: \(id)"])
            }
        } catch {
            self.errorMessage = "Failed to start container: \(error)"
        }
        refresh()
    }
    
    func stopContainer(_ name: String) async {
        do {
            _ = try await service.stopContainer(containerId: name)
        } catch {
            self.errorMessage = "Failed to stop container: \(error)"
        }
        refresh()
    }
    
    func deleteContainer(_ name: String) async {
        do {
            _ = try await service.deleteContainer(containerId: name)
        } catch {
            self.errorMessage = "Failed to delete container: \(error)"
        }
        refresh()
    }
    
    func restartContainer(_ name: String) async {
        do {
            _ = try await service.stopContainer(containerId: name)
            _ = try await service.startContainer(containerId: name)
        } catch {
            self.errorMessage = "Failed to restart container: \(error)"
        }
        refresh()
    }
    
    func createVolume(name: String, size: String? = nil, options: [String] = [], labels: [String] = []) async {
        do {
            _ = try await service.createVolume(name: name, size: size, options: options, labels: labels)
        } catch {
            self.errorMessage = "Failed to create volume: \(error)"
        }
        refresh()
    }
    
    func deleteVolume(name: String) async {
        do {
            _ = try await service.deleteVolume(name: name)
        } catch {
            self.errorMessage = "Failed to delete volume: \(error)"
        }
        refresh()
    }
    
    func createContainer(name: String, image: String, volumeMappings: [String: String]) async {
        do {
            _ = try await service.createContainer(name: name, image: image, volumeMappings: volumeMappings)
        } catch {
            self.errorMessage = "Failed to create container: \(error)"
        }
        refresh()
    }
}

// MARK: - Sidebar Section Enum

enum SidebarSection: Hashable {
    case containers
    case images
    case volumes
}

// MARK: - SwiftUI Views

struct ContentView: View {
    @StateObject private var vm = ContainerViewModel()
    @State private var sidebarSelection: SidebarSection? = .containers
    @State private var selectedContainerID: String?
    @State private var selectedImageID: String?
    @State private var selectedVolumeID: String?
    @State private var isPresentingAddVolume: Bool = false
    @State private var newVolumeName: String = ""
    @State private var newVolumeSize: String = "" // optional
    @State private var newVolumeOptionsText: String = "" // comma-separated
    @State private var newVolumeLabelsText: String = "" // comma-separated key=value
    @State private var isConfirmingDeleteVolume: Bool = false
    
    // Add Container UI state
    @State private var isPresentingAddContainer: Bool = false
    @State private var newContainerName: String = ""
    @State private var useCustomImage: Bool = false
    @State private var selectedImageRef: String = ""
    @State private var selectedVolumeTargets: [String: String] = [:] // volume name -> target path
    @State private var isPresentingInlineCreateVolume: Bool = false

    var body: some View {
        NavigationSplitView {
            // Column 1: Sidebar categories
            List(selection: $sidebarSelection) {
                Section("Resources") {
                    Label("Containers", systemImage: "shippingbox").tag(SidebarSection.containers)
                    Label("Images", systemImage: "photo.on.rectangle").tag(SidebarSection.images)
                    Label("Volumes", systemImage: "externaldrive").tag(SidebarSection.volumes)
                }
            }
            .navigationTitle("Container UI")
            .toolbar { Button("Refresh") { vm.refresh() } }
        } content: {
            // Column 2: Lists based on sidebar selection
            switch sidebarSelection {
            case .containers, .none:
                List(vm.containers, selection: $selectedContainerID) { container in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(container.id).font(.headline).lineLimit(1)
                            HStack(spacing: 8) {
                                Text(container.image).font(.caption).foregroundColor(.secondary)
                                if let os = container.os, let arch = container.arch {
                                    Text("\(os)/\(arch)").font(.caption).foregroundColor(.secondary)
                                }
                                if let addr = container.addr { Text(addr).font(.caption2).foregroundColor(.secondary) }
                            }
                        }
                        Spacer()
                        Text(container.state)
                            .font(.subheadline)
                            .foregroundColor(container.state.lowercased() == "running" ? .green : .red)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                    }
                    .tag(container.id)
                    .contextMenu {
                        Button("Start") { Task { await vm.startContainer(container.id) } }
                        Button("Stop") { Task { await vm.stopContainer(container.id) } }
                        Button("Restart") { Task { await vm.restartContainer(container.id) } }
                        Divider()
                        Button(role: .destructive) { Task { await vm.deleteContainer(container.id) } } label: { Text("Delete") }
                    }
                }
                .navigationTitle("Containers")
                .toolbar {
                    Button {
                        isPresentingAddContainer = true
                    } label: {
                        Label("Add Container", systemImage: "plus")
                    }
                    Button("Refresh") { vm.refresh() }
                }
                .sheet(isPresented: $isPresentingAddContainer) {
                    VStack(alignment: .center) {
                        Text("Create Container").font(.title2).bold()
                        Spacer()
                        Form {
                            Spacer()
                            Section("Name") {
                                TextField("", text: $newContainerName)
                            }
                            Spacer()
                            Section("Image") {
                                
                                if useCustomImage {
                                    TextField("",text: $selectedImageRef)
                                } else {
                                    Picker("",selection: $selectedImageRef) {
                                        Text("Select…").tag("")
                                        ForEach(vm.images.map { $0.id }, id: \.self) { ref in
                                            Text(ref).tag(ref)
                                        }
                                    }
                                }
                                Toggle("Enter custom image", isOn: $useCustomImage)
                            }
                            Spacer()
                            Section("Volumes") {
                                VStack(alignment: .leading, spacing: 8) {
                                    // Picker-like Menu for multi-select volumes
                                    Menu {
                                        ForEach(vm.volumes.map { $0.id }, id: \.self) { v in
                                            Button(action: {
                                                if selectedVolumeTargets.keys.contains(v) {
                                                    selectedVolumeTargets.removeValue(forKey: v)
                                                } else {
                                                    // default suggested target path
                                                    let suggested = "/data/\(v)"
                                                    selectedVolumeTargets[v] = suggested
                                                }
                                            }) {
                                                HStack {
                                                    Text(v)
                                                    Spacer()
                                                    if selectedVolumeTargets.keys.contains(v) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            Text(selectedVolumeTargets.isEmpty ? "Select Volumes…" : "Selected (\(selectedVolumeTargets.count))")
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "chevron.down").foregroundStyle(.secondary)
                                        }
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
                                    }

                                    // For each selected volume, allow editing its target path
                                    if !selectedVolumeTargets.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(selectedVolumeTargets.keys.sorted(), id: \.self) { v in
                                                HStack(alignment: .firstTextBaseline) {
                                                    Text(v)
                                                        .font(.subheadline)
                                                    TextField("/path/in/container", text: Binding(
                                                        get: { selectedVolumeTargets[v] ?? "" },
                                                        set: { selectedVolumeTargets[v] = $0 }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(minWidth: 220)
                                                    Button(role: .destructive) {
                                                        selectedVolumeTargets.removeValue(forKey: v)
                                                    } label: {
                                                        Image(systemName: "xmark.circle").foregroundStyle(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                        .padding(.top, 4)
                                    }

                                    HStack {
                                        Spacer()
                                        Button {
                                            isPresentingInlineCreateVolume = true
                                        } label: {
                                            Label("Create New Volume", systemImage: "plus.circle")
                                        }
                                    }
                                }
                            }
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            Button("Cancel") { isPresentingAddContainer = false }
                            Button("Create") {
                                let name = newContainerName.trimmingCharacters(in: .whitespaces)
                                let image = selectedImageRef.trimmingCharacters(in: .whitespaces)
                                Task {
                                    await vm.createContainer(name: name, image: image, volumeMappings: selectedVolumeTargets)
                                    // reset and dismiss
                                    newContainerName = ""
                                    useCustomImage = false
                                    selectedImageRef = ""
                                    selectedVolumeTargets.removeAll()
                                    isPresentingAddContainer = false
                                }
                            }
                            .disabled(newContainerName.trimmingCharacters(in: .whitespaces).isEmpty || (useCustomImage ? selectedImageRef.trimmingCharacters(in: .whitespaces).isEmpty : selectedImageRef.isEmpty))
                        }
                        .padding([.horizontal, .bottom])
                    }
                    .frame(minWidth: 520, minHeight: 520)
                    .padding()
                    .sheet(isPresented: $isPresentingInlineCreateVolume) {
                        // Reuse existing volume create UI by presenting the same add volume sheet
                        VStack(alignment: .leading) {
                            Text("Create Volume").font(.title2).bold()
                            Form {
                                Section(header: Text("Required")) {
                                    TextField("Name", text: $newVolumeName)
                                }
                                Section(header: Text("Optional")) {
                                    TextField("Size (e.g., 1G, 512MB)", text: $newVolumeSize)
                                    TextField("Options (comma-separated)", text: $newVolumeOptionsText)
                                    TextField("Labels (comma-separated key=value)", text: $newVolumeLabelsText)
                                }
                            }
                            HStack {
                                Spacer()
                                Button("Cancel") { isPresentingInlineCreateVolume = false }
                                Button("Create") {
                                    let opts = newVolumeOptionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                    let labels = newVolumeLabelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                    let size = newVolumeSize.trimmingCharacters(in: .whitespaces)
                                    Task {
                                        await vm.createVolume(name: newVolumeName, size: size.isEmpty ? nil : size, options: opts, labels: labels)
                                        // if created, auto-select it
                                        selectedVolumeTargets[newVolumeName] = "/data/\(newVolumeName)"
                                        // reset and dismiss
                                        newVolumeName = ""
                                        newVolumeSize = ""
                                        newVolumeOptionsText = ""
                                        newVolumeLabelsText = ""
                                        isPresentingInlineCreateVolume = false
                                    }
                                }
                                .disabled(newVolumeName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding([.horizontal, .bottom])
                        }
                        .frame(minWidth: 420, minHeight: 360)
                        .padding()
                    }
                }

            case .images:
                List(vm.images, selection: $selectedImageID) { image in
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        VStack(alignment: .leading) {
                            Text(image.id).lineLimit(1)
                            if let size = image.size { Text(size).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    .tag(image.id)
                }
                .navigationTitle("Images")

            case .volumes:
                List(vm.volumes, selection: $selectedVolumeID) { volume in
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(volume.id).lineLimit(1)
                            if let mp = volume.mountpoint { Text(mp).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                    .tag(volume.id)
                }
                .navigationTitle("Volumes")
                .toolbar {
                    Button {
                        isPresentingAddVolume = true
                    } label: {
                        Label("Add Volume", systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        isConfirmingDeleteVolume = true
                    } label: {
                        Label("Delete Volume", systemImage: "trash")
                    }
                    .disabled(selectedVolumeID == nil)
                }
                .sheet(isPresented: $isPresentingAddVolume) {
                    VStack(alignment: .leading) {
                        Text("Create Volume").font(.title2).bold()
                        Form {
                            Section(header: Text("Required")) {
                                TextField("Name", text: $newVolumeName)
                            }
                            Section(header: Text("Optional")) {
                                TextField("Size (e.g., 1G, 512MB)", text: $newVolumeSize)
                                TextField("Options (comma-separated)", text: $newVolumeOptionsText)
                                TextField("Labels (comma-separated key=value)", text: $newVolumeLabelsText)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                isPresentingAddVolume = false
                            }
                            Button("Create") {
                                let opts = newVolumeOptionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                let labels = newVolumeLabelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                let size = newVolumeSize.trimmingCharacters(in: .whitespaces)
                                Task {
                                    await vm.createVolume(name: newVolumeName, size: size.isEmpty ? nil : size, options: opts, labels: labels)
                                    newVolumeName = ""
                                    newVolumeSize = ""
                                    newVolumeOptionsText = ""
                                    newVolumeLabelsText = ""
                                    isPresentingAddVolume = false
                                }
                                
                            }
                            .disabled(newVolumeName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding([.horizontal, .bottom])
                    }
                    .frame(minWidth: 420, minHeight: 360)
                    .padding()
                }
                .confirmationDialog(
                    selectedVolumeID.map { "Delete volume '\($0)'?" } ?? "Delete volume?",
                    isPresented: $isConfirmingDeleteVolume,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let id = selectedVolumeID {
                            Task {
                                await vm.deleteVolume(name: id)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This action cannot be undone.")
                }
            }
        } detail: {
            // Column 3: Details
            switch sidebarSelection {
            case .containers, .none:
                if let id = selectedContainerID, let container = vm.containers.first(where: { $0.id == id }) {
                    ContainerDetailView(container: container, onSelectVolume: { volName in
                        sidebarSelection = .volumes
                        selectedVolumeID = volName
                    })
                } else {
                    Text("Select a container to see details").foregroundColor(.secondary)
                }
            case .images:
                if let imgID = selectedImageID {
                    ImageDetailView(imageID: imgID)
                } else {
                    Text("Select an image to see details").foregroundColor(.secondary)
                }
            case .volumes:
                if let volID = selectedVolumeID, let volume = vm.volumes.first(where: { $0.id == volID }) {
                    VolumeDetailView(volume: volume, onSelectContainer: { cid in
                        sidebarSelection = .containers
                        selectedContainerID = cid
                    })
                    .environmentObject(vm)
                } else {
                    Text("Select a volume to see details").foregroundColor(.secondary)
                }
            }
        }
        .onAppear { vm.startPolling(interval: 1.0) }
        .onDisappear { vm.stopPolling(); NSApp.setActivationPolicy(.accessory) }
    }
}

struct ContainerDetailView: View {
    let container: ContainerModel
    var onSelectVolume: (String) -> Void = { _ in }
    @StateObject private var vm = ContainerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(container.id)
                    .font(.title2)
                    .bold()
                Spacer()
                HStack(spacing: 0) { // no spacing between buttons
                    // Start button (round left corners)
                    Button(action: {
                        Task { await vm.startContainer(container.id) }
                    }) {
                        Image(systemName: "play").foregroundStyle(Color.white)
                    }
                    .disabled(container.running)
                    .frame(height: 30)
                    .background(Color.green)
                    .clipShape(RoundedCorners(tl: 10, tr: 0, bl: 10, br: 0))

                    Divider()
                        .frame(width: 1, height: 30)

                    // Stop button (no rounded corners)
                    Button(action: {
                        Task { await vm.stopContainer(container.id) }
                    }) {
                        Image(systemName: "stop").foregroundStyle(Color.white)
                    }
                    .disabled(!container.running)
                    .frame(height: 30)
                    .background(Color.blue)

                    Divider()
                        .frame(width: 1, height: 30)

                    // Restart button (round right corners)
                    Button(action: {
                        Task { await vm.restartContainer(container.id) }
                    }) {
                        Image(systemName: "arrow.trianglehead.counterclockwise").foregroundStyle(Color.white)
                    }
                    .frame(height: 30)
                    .background(Color.blue)
                    .clipShape(RoundedCorners(tl: 0, tr: 10, bl: 0, br: 10))
                }
                Button(action: {
                    Task { await vm.deleteContainer(container.id) }
                }) {
                    Image(systemName: "trash").foregroundStyle(Color.white)
                }
                .frame(height: 30)
                .background(Color.red)
                .cornerRadius(5)
            }

            Group {
                HStack {
                    Text("Image:")
                    Text(container.image).bold()
                }
                if let os = container.os, let arch = container.arch {
                    HStack {
                        Text("Platform:")
                        Text("\(os)/\(arch)").bold()
                    }
                }
                HStack {
                    Text("State:")
                    Text(container.state)
                        .bold()
                        .foregroundColor(container.state.lowercased() == "running" ? .green : .red)
                }
                if let addr = container.addr {
                    HStack {
                        Text("Address:")
                        Text(addr).bold()
                    }
                }
            }

            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Volumes").font(.headline)
                if container.mounts.isEmpty {
                    Text("No volumes mounted.").foregroundColor(.secondary)
                } else {
                    ForEach(container.mounts) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "externaldrive")
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = m.volumeName, !name.isEmpty {
                                    Button(action: { onSelectVolume(name) }) {
                                        Text(name).bold().underline()
                                    }
                                } else if let src = m.source {
                                    Text(src).bold().textSelection(.enabled)
                                }
                                if let dest = m.destination { Text("→ \(dest)").font(.caption).foregroundColor(.secondary) }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(15)
    }
}

struct ImageDetailView: View {
    let imageID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(imageID)
                .font(.title2)
                .bold()
            Text("Image details go here.")
            Spacer()
        }
        .padding(15)
    }
}

struct VolumeDetailView: View {
    let volume: VolumeModel
    var onSelectContainer: (String) -> Void = { _ in }
    @EnvironmentObject private var vm: ContainerViewModel
    @Environment(\.openWindow) private var openWindow
    
    private func containersUsingVolume() -> [ContainerModel] {
        let volName = volume.id
        let volSourcePath = (volume.source?.removingPercentEncoding ?? volume.source) ?? volume.mountpoint
        return vm.containers.filter { c in
            c.mounts.contains { m in
                if let name = m.volumeName, !name.isEmpty, name == volName { return true }
                if let src = m.source, let vsrc = volSourcePath, !vsrc.isEmpty {
                    // Compare file paths by normalizing percent encoding
                    let lhs = src.removingPercentEncoding ?? src
                    return lhs == vsrc
                }
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(volume.id)
                    .font(.title2)
                    .bold()
                Spacer()
                if let src = volume.source, !src.isEmpty {
                    Button("Open in Finder") {
                        let path = src.removingPercentEncoding ?? src
                        let url = URL(fileURLWithPath: path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else if let mp = volume.mountpoint, !mp.isEmpty {
                    Button("Open in Finder") {
                        let path = mp.removingPercentEncoding ?? mp
                        let url = URL(fileURLWithPath: path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }

            Group {
                HStack { Text("Name:"); Text(volume.id).bold() }
                if let mp = volume.mountpoint, !mp.isEmpty {
                    HStack { Text("Mountpoint:"); Text(mp).bold() }
                } else {
                    HStack { Text("Mountpoint:"); Text("(not mounted)").foregroundColor(.secondary) }
                }
                if let src = volume.source { HStack { Text("Source:"); Text(src).bold().textSelection(.enabled) } }
                if let drv = volume.driver { HStack { Text("Driver:"); Text(drv).bold() } }
                if let fmt = volume.format { HStack { Text("Format:"); Text(fmt).bold() } }
                if let ts = volume.createdAt {
                    let date = Date(timeIntervalSince1970: ts)
                    HStack { Text("Created:"); Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)).bold() }
                }
                if let labels = volume.labels, !labels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Labels:").bold()
                        ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            HStack { Text(k + ":"); Text(v).bold() }
                        }
                    }
                }
                if let opts = volume.options, !opts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Options:").bold()
                        ForEach(opts.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            HStack { Text(k + ":"); Text(v).bold() }
                        }
                    }
                }
            }
            
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Used by Containers").font(.headline)
                let used = containersUsingVolume()
                if used.isEmpty {
                    Text("No containers referencing this volume found.").foregroundColor(.secondary)
                } else {
                    ForEach(used) { c in
                        Button(action: { onSelectContainer(c.id) }) {
                            HStack {
                                Image(systemName: "shippingbox")
                                Text(c.id).underline()
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(15)
    }
}

struct RoundedCorners: Shape {
    var tl: CGFloat = 0
    var tr: CGFloat = 0
    var bl: CGFloat = 0
    var br: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath()
        
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                   controlPoint1: CGPoint(x: rect.maxX, y: rect.minY),
                   controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.curve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                   controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY),
                   controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.curve(to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                   controlPoint1: CGPoint(x: rect.minX, y: rect.maxY),
                   controlPoint2: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.curve(to: CGPoint(x: rect.minX + tl, y: rect.minY),
                   controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                   controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
        
        return Path(path.cgPath)
    }
}

// MARK: - Previews

#if DEBUG
import SwiftUI

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 1000, height: 500)
    }
}
#endif

