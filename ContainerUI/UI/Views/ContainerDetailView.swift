import SwiftUI

struct ContainerDetailView: View {
    let container: ContainerModel
    var onSelectVolume: (String) -> Void = { _ in }
    @StateObject private var vm = ContainerViewModel()
    @State private var isConfirmingDelete = false

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
                    isConfirmingDelete = true
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
        .confirmationDialog(
            "Delete container '\(container.id)'?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await vm.deleteContainer(container.id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}