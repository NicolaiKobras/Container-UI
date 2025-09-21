import SwiftUI

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