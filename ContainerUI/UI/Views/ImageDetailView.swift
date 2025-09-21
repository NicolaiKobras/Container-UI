import SwiftUI

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