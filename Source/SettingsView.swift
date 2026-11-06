import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: WallpaperManager

    private var screen: ScreenRow? {
        manager.screens.first { $0.id == manager.selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 224)
            Divider()
            if let screen {
                ScrollView {
                    detail(for: screen)
                        .padding(24)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top)
            } else {
                ContentUnavailableView(
                    "Нет доступных дисплеев",
                    systemImage: "display",
                    description: Text("Подключите дисплей, чтобы настроить его обои.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text("Живые обои")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(16)

            List(selection: $manager.selectedID) {
                Section("Дисплеи") {
                    ForEach(manager.screens) { screen in
                        screenRow(screen)
                            .tag(screen.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Дисплеи")

            Divider()
            globalControls
        }
        .background(.regularMaterial)
    }

    private func screenRow(_ screen: ScreenRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: screen.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(screen.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var globalControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { manager.launchAtLogin },
                set: { manager.setLaunchAtLogin($0) }
            )) {
                Text("Запуск при входе")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Открывать приложение после входа в macOS.")

            if let error = manager.launchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: manager.togglePaused) {
                Label(
                    manager.isPaused ? "Продолжить на всех" : "Пауза на всех",
                    systemImage: manager.isPaused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Управляет воспроизведением видео на всех дисплеях.")
        }
        .padding(16)
    }

    private func detail(for screen: ScreenRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(screen.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(screen.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Обои приложения", isOn: Binding(
                    get: { manager.state.isEnabled },
                    set: { manager.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Выключите, чтобы на этом дисплее показывались обои macOS.")
            }

            mediaCard

            if !manager.state.isEnabled {
                Label("На этом дисплее сейчас используются обои macOS.", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            displayControls
        }
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.state.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(manager.state.title)
                        Text(manager.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: manager.chooseFile) {
                        Label("Выбрать файл…", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.state.isLoading)
                    .help("Выберите видео или изображение для этого дисплея.")
                }
                HStack(spacing: 16) {
                    Button(action: manager.applyToAllDisplays) {
                        Label("На все экраны", systemImage: "rectangle.on.rectangle")
                    }
                    .disabled(manager.screens.count < 2 || !manager.state.hasWallpaper
                              || manager.state.isLoading || manager.state.error != nil)
                    .help("Установить эти обои на все подключённые дисплеи. Настройки звука каждого дисплея сохранятся.")

                    Button(action: manager.useDefault) {
                        Label(manager.state.resetTitle, systemImage: "arrow.uturn.backward")
                    }
                    .disabled((manager.state.isUsingDefault && manager.state.error == nil) || manager.state.isLoading)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)

                if let error = manager.state.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                if let image = manager.state.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: manager.state.fit == .fill ? .fill : .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }

                Text("Предпросмотр")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)

                if manager.state.isLoading {
                    ProgressView()
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Загрузка файла")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(height: 168)
    }

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Масштаб")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Масштаб", selection: Binding(
                    get: { manager.state.fit },
                    set: { manager.setFit($0) }
                )) {
                    Text("Заполнить").tag(WallpaperFit.fill)
                    Text("Вписать").tag(WallpaperFit.fit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 192)
                .help("«Заполнить» покрывает весь экран и может обрезать края. «Вписать» показывает весь кадр.")
            }
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { manager.state.hasAudio && manager.state.soundEnabled },
                    set: { manager.setSoundEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Звук")
                            .font(.subheadline.weight(.medium))
                        if !manager.state.hasAudio {
                            Text("В файле нет звуковой дорожки")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!manager.state.hasAudio)

                HStack(spacing: 12) {
                    let percentage = "\(Int((manager.state.volume * 100).rounded()))%"
                    Text("Громкость")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Slider(value: Binding(
                        get: { manager.state.volume },
                        set: { manager.setVolume($0) }
                    ), in: 0...1, step: 0.01) {
                        Text("Громкость")
                    }
                    .labelsHidden()
                    .frame(width: 144)
                    .accessibilityValue(percentage)

                    Text(percentage)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .disabled(!manager.state.hasAudio)
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
    }
}
