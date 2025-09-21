import SwiftUI

struct DeleteContainerConfirmationDialog: View {
    @Binding var isPresented: Bool
    let containerID: String?
    
    @EnvironmentObject private var vm: ContainerViewModel
    
    var body: some View {
        EmptyView()
            .confirmationDialog(
                containerID.map { "Delete container '\($0)'?" } ?? "Delete container?",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let id = containerID {
                        Task {
                            await vm.deleteContainer(id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone.")
            }
    }
}