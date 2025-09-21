import SwiftUI

struct DeleteVolumeConfirmationDialog: View {
    @Binding var isPresented: Bool
    let volumeID: String?
    
    @EnvironmentObject private var vm: ContainerViewModel
    
    var body: some View {
        EmptyView()
            .confirmationDialog(
                volumeID.map { "Delete volume '\($0)'?" } ?? "Delete volume?",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let id = volumeID {
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
}