import SwiftUI
import Foundation
import Combine

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
    @State private var isConfirmingDeleteContainer: Bool = false
    
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
                        Button(role: .destructive) { 
                            selectedContainerID = container.id
                            isConfirmingDeleteContainer = true 
                        } label: { Text("Delete") }
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
                    AddContainerDialog(
                        isPresented: $isPresentingAddContainer,
                        newContainerName: $newContainerName,
                        useCustomImage: $useCustomImage,
                        selectedImageRef: $selectedImageRef,
                        selectedVolumeTargets: $selectedVolumeTargets,
                        isPresentingInlineCreateVolume: $isPresentingInlineCreateVolume
                    )
                    .environmentObject(vm)
                    .sheet(isPresented: $isPresentingInlineCreateVolume) {
                        // Reuse existing volume create UI by presenting the same add volume sheet
                        AddVolumeDialog(
                            isPresented: $isPresentingInlineCreateVolume,
                            newVolumeName: $newVolumeName,
                            newVolumeSize: $newVolumeSize,
                            newVolumeOptionsText: $newVolumeOptionsText,
                            newVolumeLabelsText: $newVolumeLabelsText,
                            onVolumeCreated: { volumeName in
                                // Auto-select the created volume
                                selectedVolumeTargets[volumeName] = "/data/\(volumeName)"
                            }
                        )
                        .environmentObject(vm)
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
                    AddVolumeDialog(
                        isPresented: $isPresentingAddVolume,
                        newVolumeName: $newVolumeName,
                        newVolumeSize: $newVolumeSize,
                        newVolumeOptionsText: $newVolumeOptionsText,
                        newVolumeLabelsText: $newVolumeLabelsText
                    )
                    .environmentObject(vm)
                }
                
            DeleteVolumeConfirmationDialog(
                isPresented: $isConfirmingDeleteVolume,
                volumeID: selectedVolumeID
            )
            .environmentObject(vm)
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
        
        DeleteContainerConfirmationDialog(
            isPresented: $isConfirmingDeleteContainer,
            containerID: selectedContainerID
        )
        .environmentObject(vm)
        
        .onAppear { vm.startPolling(interval: 1.0) }
        .onDisappear { vm.stopPolling(); NSApp.setActivationPolicy(.accessory) }
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