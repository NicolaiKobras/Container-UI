import SwiftUI

struct AddVolumeDialog: View {
    @Binding var isPresented: Bool
    @Binding var newVolumeName: String
    @Binding var newVolumeSize: String
    @Binding var newVolumeOptionsText: String
    @Binding var newVolumeLabelsText: String
    
    // Optional closure to handle successful volume creation (for inline usage)
    var onVolumeCreated: ((String) -> Void)? = nil
    
    @EnvironmentObject private var vm: ContainerViewModel
    
    var body: some View {
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
                    isPresented = false
                }
                Button("Create") {
                    let opts = newVolumeOptionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let labels = newVolumeLabelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let size = newVolumeSize.trimmingCharacters(in: .whitespaces)
                    let volumeName = newVolumeName
                    Task {
                        await vm.createVolume(name: volumeName, size: size.isEmpty ? nil : size, options: opts, labels: labels)
                        // If callback provided, call it with the created volume name
                        onVolumeCreated?(volumeName)
                        newVolumeName = ""
                        newVolumeSize = ""
                        newVolumeOptionsText = ""
                        newVolumeLabelsText = ""
                        isPresented = false
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