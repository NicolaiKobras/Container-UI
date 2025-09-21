import Foundation
import SwiftUI

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