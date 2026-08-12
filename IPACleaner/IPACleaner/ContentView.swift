import SwiftUI

struct ContentView: View {
    @StateObject private var model = CleanerModel()
    @State private var showPicker = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header

                if model.files.isEmpty {
                    Spacer()
                    emptyState
                    Spacer()
                } else {
                    List(model.files) { file in
                        Button {
                            model.toggle(file)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(1)
                                    Text(file.url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(file.sizeText)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)

                    controls
                }
            }
            .padding(.top, 8)
            .navigationTitle("IPA Cleaner")
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    showPicker = false
                    model.setFolder(url)
                }
            }
            .alert("Удалить выбранные IPA?", isPresented: $showDeleteAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) {
                    model.deleteSelected()
                }
            } message: {
                Text("Будет удалено файлов: \(model.selectedFiles.count), размер: \(ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file)).")
            }
            .alert("Ошибка", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "Неизвестная ошибка")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status)
                        .font(.headline)
                    if !model.files.isEmpty {
                        Text("Всего: \(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isScanning {
                    ProgressView()
                }
            }

            Button {
                showPicker = true
            } label: {
                Label("Выбрать папку и найти IPA", systemImage: "folder.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning)
        }
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Поиск IPA-файлов")
                .font(.title3.weight(.bold))
            Text("Приложение ищет .ipa рекурсивно внутри папки, которую вы разрешите открыть через приложение «Файлы».")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Button("Выбрать папку") {
                showPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button(model.selected.count == model.files.count ? "Снять выбор" : "Выбрать все") {
                    if model.selected.count == model.files.count {
                        model.clearSelection()
                    } else {
                        model.selectAll()
                    }
                }
                Spacer()
                Text("Выбрано: \(model.selected.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Удалить выбранные", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selected.isEmpty || model.isScanning)
        }
        .padding()
    }
}
