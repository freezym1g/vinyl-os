import SwiftUI

@main
struct VinylOfTheDayApp: App {
    @StateObject private var model = VinylModel()

    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if url.scheme == "vinyl-of-day" && url.host == "shuffle-widget" {
                        Task { await model.nextWidgetAlbum() }
                    }
                }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: VinylModel
    var body: some View {
        TabView {
            TodayView().tabItem { Label("Сегодня", systemImage: "square.stack") }
            LibraryView().tabItem { Label("Коллекция", systemImage: "square.grid.2x2") }
            RatedAlbumsView().tabItem { Label("Оценённые", systemImage: "star.fill") }
            SettingsView().tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .tint(.white)
        .alert("VINYL", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

struct RemoteArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .empty: ZStack { Color.white.opacity(0.06); ProgressView().tint(.white) }
            case .failure: ZStack { Color.white.opacity(0.06); Image(systemName: "opticaldisc").font(.largeTitle) }
            @unknown default: Color.black
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

struct TodayView: View {
    @EnvironmentObject var model: VinylModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("VINYL").font(.system(size: 33, weight: .black, design: .rounded))
                        Spacer()
                        Button { Task { await model.synchronize() } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.isLoading)
                        .accessibilityLabel("Синхронизировать Spotify")
                    }
                    Picker("Источник", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(CollectionMode.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented)
                    if let album = model.current {
                        VinylFeatureCard(album: album, accent: model.accent)
                        HStack(spacing: 14) {
                            Button { model.shuffle() } label: {
                                Label("Другой альбом", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(.gray.opacity(0.35))
                            if let link = album.link {
                                Button { openURL(link) } label: {
                                    Label("Spotify", systemImage: "play.fill")
                                }.buttonStyle(.borderedProminent).tint(.green)
                            }
                        }
                        Button {
                            Task { await model.publishToWidget(album) }
                        } label: {
                            Label(model.widgetBusy ? "Отправляем…" : "Добавить в виджет", systemImage: "plus.rectangle.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.widgetBusy)
                        HStack {
                            Text("Моя оценка")
                            Spacer()
                            Menu {
                                ForEach(1...10, id: \.self) { value in
                                    Button("\(value) / 10") { model.rate(value, album: album) }
                                }
                                Button("Убрать оценку") { model.rate(0, album: album) }
                            } label: {
                                Text(model.ratings[album.id].map { "\($0) / 10" } ?? "Оценить")
                                    .bold().padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                        }
                    } else {
                        ContentUnavailableView("Нет альбомов", systemImage: "opticaldisc", description: Text("Подключи Spotify в настройках или добавь альбом по ссылке в «Коллекции»."))
                    }
                    Text("Для синхронизации с виджетом настрой GitHub Gist в «Настройки → Виджет». Бесплатная подпись не поддерживает общее хранилище приложения и виджета.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.085))
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct VinylFeatureCard: View {
    let album: VinylAlbum
    let accent: RGBColor
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            RemoteArtwork(url: album.artwork)
            Text("TODAY’S RECORD").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.5).opacity(0.65)
            Text(album.name).font(.system(size: 34, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
            Text(album.artist).font(.title3).opacity(0.88)
            Text(album.year).foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(23)
        .background(accent.swiftUIColor, in: RoundedRectangle(cornerRadius: 28))
    }
}

/// A shared tappable album row used in Library and Rated Albums.
struct AlbumListRow: View {
    let album: VinylAlbum
    let rating: Int?

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(url: album.artwork).frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name).font(.headline).lineLimit(1)
                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(album.year).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 5)
            if let rating {
                Text("\(rating)/10")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.11), in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: VinylModel
    @State private var search = ""
    @State private var showAdd = false
    @State private var actionAlbum: VinylAlbum?

    private var filtered: [VinylAlbum] {
        model.allAlbums.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { album in
                    Button { actionAlbum = album } label: {
                        AlbumListRow(album: album, rating: model.ratings[album.id])
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.045))
                }
            }
            .searchable(text: $search, prompt: "Альбом или исполнитель")
            .navigationTitle("Коллекция · \(filtered.count)")
            .toolbar { Button { showAdd = true } label: { Label("Добавить ссылку Spotify", systemImage: "plus") } }
            .sheet(isPresented: $showAdd) { AddSpotifyLinkView().environmentObject(model) }
            .sheet(item: $actionAlbum) { AlbumActionsSheet(album: $0).environmentObject(model) }
            .overlay {
                if model.allAlbums.isEmpty {
                    ContentUnavailableView("Коллекция пуста", systemImage: "square.stack", description: Text("Добавь ссылку на альбом кнопкой + или подключи Spotify."))
                }
            }
        }
    }
}

struct RatedAlbumsView: View {
    @EnvironmentObject var model: VinylModel
    @State private var actionAlbum: VinylAlbum?
    @State private var search = ""

    private var filtered: [VinylAlbum] {
        model.ratedAlbums.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { album in
                    Button { actionAlbum = album } label: {
                        AlbumListRow(album: album, rating: model.ratings[album.id])
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.045))
                }
            }
            .searchable(text: $search, prompt: "Найти среди оценённых")
            .navigationTitle("Оценённые · \(model.ratedAlbums.count)")
            .sheet(item: $actionAlbum) { AlbumActionsSheet(album: $0).environmentObject(model) }
            .overlay {
                if model.ratedAlbums.isEmpty {
                    ContentUnavailableView("Пока нет оценок", systemImage: "star", description: Text("Открой альбом в «Коллекции» и поставь ему оценку от 1 до 10."))
                }
            }
        }
    }
}

struct AlbumActionsSheet: View {
    let album: VinylAlbum
    @EnvironmentObject var model: VinylModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RemoteArtwork(url: album.artwork)
                        .frame(width: 185, height: 185)
                    VStack(spacing: 5) {
                        Text(album.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(album.artist).foregroundStyle(.secondary)
                        Text(album.year).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 5)

                    Button {
                        Task {
                            await model.publishToWidget(album)
                            dismiss()
                        }
                    } label: {
                        Label(model.widgetBusy ? "Отправляем в виджет…" : "Добавить в виджет", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.21))
                    .disabled(model.widgetBusy)

                    if let spotify = album.link {
                        Button {
                            openURL(spotify)
                        } label: {
                            Label("Открыть в Spotify", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        if model.saved.contains(where: { $0.id == album.id }) { model.setMode(.saved) }
                        else if model.manual.contains(where: { $0.id == album.id }) { model.setMode(.manual) }
                        else { model.setMode(.recent) }
                        model.select(album)
                        dismiss()
                    } label: {
                        Label("Показать на главном экране", systemImage: "square.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        ForEach(1...10, id: \.self) { rating in
                            Button("\(rating) / 10") { model.rate(rating, album: album) }
                        }
                        if model.ratings[album.id] != nil {
                            Button("Убрать оценку", role: .destructive) { model.rate(0, album: album) }
                        }
                    } label: {
                        HStack {
                            Label("Моя оценка", systemImage: "star")
                            Spacer()
                            Text(model.ratings[album.id].map { "\($0)/10" } ?? "Выбрать")
                        }
                        .padding(14)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.085))
            .navigationTitle("Альбом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: VinylModel
    @State private var githubToken = ""
    @State private var savedToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Spotify Developer") {
                    TextField("Client ID", text: $model.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сохранить Client ID") { model.setClientID() }
                    LabeledContent("Redirect URI", value: SpotifyAPI.redirectURI)
                    Text("Добавь этот Redirect URI в Spotify Developer Dashboard. Client Secret не нужен: авторизация использует PKCE.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Подключение") {
                    Button(model.connected ? "Переподключить Spotify" : "Войти через Spotify") {
                        Task { await model.login() }
                    }
                    Button("Синхронизировать альбомы") { Task { await model.synchronize() } }
                        .disabled(!model.connected || model.isLoading)
                    Button("Отключить Spotify", role: .destructive) { model.logout() }
                        .disabled(!model.connected)
                    if model.isLoading { ProgressView() }
                }
                Section("Виджет · бесплатная синхронизация") {
                    Text("Для работы без платного Apple Developer используем unlisted Gist на GitHub. Туда отправляется только выбранный альбом: название, исполнитель, год, ссылка и обложка. Вся библиотека, оценки и Spotify-токены остаются на iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Создать GitHub Gist-токен", destination: URL(string: "https://github.com/settings/tokens/new")!)
                    Text("Создай Personal access token (classic), отметь только разрешение «gist». Никому не отправляй этот токен и не загружай его в репозиторий.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SecureField("GitHub-токен (ghp_…)", text: $githubToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сохранить GitHub-токен") {
                        model.saveGitHubToken(githubToken)
                        savedToken = GistWidgetSync.shared.hasToken
                        githubToken = ""
                    }
                    .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    LabeledContent("Токен", value: savedToken ? "Сохранён" : "Не настроен")
                    if !model.widgetGistID.isEmpty {
                        Text("Gist ID: \(model.widgetGistID)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Скопировать Gist ID") {
                            UIPasteboard.general.string = model.widgetGistID
                        }
                    }
                    Text("После первой кнопки «Добавить в виджет» зажми виджет VINYL на домашнем экране → «Изменить виджет» → вставь Gist ID. Без ID виджет показывает 4 демо-альбома.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Gist не индексируется как публичный, но любой, кто получит ссылку, сможет увидеть выбранный альбом. Для обновления требуется интернет; iOS решает, когда перерисовать виджет.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("О приложении") {
                    Text("VINYL 1.1 — бесплатная локальная сборка. Неофициальное приложение, не связано со Spotify AB.")
                    Text("Оценки хранятся на iPhone. Spotify и GitHub токены — в Keychain.")
                }
            }
            .navigationTitle("Настройки")
            .onAppear { savedToken = GistWidgetSync.shared.hasToken }
        }
    }
}

struct AddSpotifyLinkView: View {
    @EnvironmentObject var model: VinylModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ссылка Spotify") {
                    TextField("https://open.spotify.com/album/...", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Необязательно") {
                    TextField("Название альбома", text: $title)
                    TextField("Исполнитель", text: $artist)
                    TextField("Год", text: $year)
                    Text("Если не укажешь название, приложение попробует получить его и обложку из Spotify oEmbed. Исполнителя и год при необходимости можно указать вручную.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(adding ? "Добавляем…" : "Добавить альбом") {
                    adding = true
                    Task {
                        await model.addManual(spotifyLink: link, title: title, artist: artist, year: year)
                        adding = false
                        if model.manual.contains(where: { $0.id == (URL(string: link)?.pathComponents.last ?? "") }) {
                            dismiss()
                        }
                    }
                }
                .disabled(link.isEmpty || adding)
            }
            .navigationTitle("Альбом по ссылке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}
