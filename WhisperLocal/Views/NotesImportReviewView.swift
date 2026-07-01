import SwiftUI

struct NotesImportReviewView: View {
    @Binding var importedText: String
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void
    
    @State private var title: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Título") {
                    TextField("Mi nota importada", text: $title)
                        .autocapitalization(.sentences)
                }
                
                Section("Vista previa") {
                    Text(importedText)
                        .font(.caption)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                
                Section("Info") {
                    HStack {
                        Text("Caracteres")
                        Spacer()
                        Text("\(importedText.count)")
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Palabras")
                        Spacer()
                        Text("\(importedText.split(separator: " ").count)")
                            .fontWeight(.medium)
                    }
                }
            }
            .navigationTitle("Importar desde Notas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onSave(title.isEmpty ? "Nota importada" : title)
                        dismiss()
                    }
                }
            }
        }
    }
}
