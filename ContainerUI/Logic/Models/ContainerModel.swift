import Foundation

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