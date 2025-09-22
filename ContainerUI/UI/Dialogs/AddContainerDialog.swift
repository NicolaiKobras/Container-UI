import SwiftUI

struct AddContainerDialog: View {
    @Binding var isPresented: Bool
    @Binding var newContainerName: String
    @Binding var useCustomImage: Bool
    @Binding var selectedImageRef: String
    @Binding var selectedVolumeTargets: [String: String]
    @Binding var isPresentingInlineCreateVolume: Bool
    
    @EnvironmentObject private var vm: ContainerViewModel
    
    var body: some View {
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
                Button("Cancel") { 
                    isPresented = false 
                }
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
                        isPresented = false
                    }
                }
                .disabled(newContainerName.trimmingCharacters(in: .whitespaces).isEmpty || (useCustomImage ? selectedImageRef.trimmingCharacters(in: .whitespaces).isEmpty : selectedImageRef.isEmpty))
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 520, minHeight: 520)
        .padding()
    }
}