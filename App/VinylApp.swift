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
                    // WidgetKit normally activates its containing app for Link taps.
                    // We must explicitly hand the album off to Spotify.
                    if url.scheme == "vinyl-of-day" {
                        switch url.host {
                        case "shuffle-widget":
                            Task { await model.nextWidgetAlbum() }
                        case "open-spotify":
                            SpotifyWidgetRouter.openFromWidgetLink(url)
                        default:
                            break
                        }
                    } else if url.host?.lowercased() == "open.spotify.com" {
                        // Compatibility with existing widget snapshots using a
                        // direct Spotify URL instead of our explicit callback.
                        SpotifyWidgetRouter.openSpotifyAlbum(url)
                    }
                }
        }
    }
}

/// Routes taps from the WidgetKit extension to the corresponding Spotify album.
/// WidgetKit may foreground VINYL first; the host app then launches Spotify.
@MainActor
private enum SpotifyWidgetRouter {
    static func openFromWidgetLink(_ callback: URL) {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let raw = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let albumURL = URL(string: raw) else { return }
        openSpotifyAlbum(albumURL)
    }

    static func openSpotifyAlbum(_ target: URL) {
        guard target.scheme?.lowercased() == "https",
              target.host?.lowercased() == "open.spotify.com" else { return }
        let segments = target.pathComponents.filter { $0 != "/" }
        guard segments.count >= 2, segments[0] == "album" else { return }
        let albumID = segments[1]
        guard albumID.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
              let canonical = URL(string: "https://open.spotify.com/album/\(albumID)"),
              let spotifyApp = URL(string: "spotify:album:\(albumID)") else { return }

        // Opening spotify:album: directly uses Spotify if installed. If it is
        // absent, use the HTTPS album page as the safe fallback.
        UIApplication.shared.open(spotifyApp, options: [:]) { success in
            if !success {
                Task { @MainActor in
                    UIApplication.shared.open(canonical)
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
    @State private var reviewAlbum: VinylAlbum?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        Text("VINYL")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .tracking(-1.2)
                        Spacer()
                        Button { Task { await model.synchronize() } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 46, height: 46)
                        }
                        .modifier(VinylGlassButtonModifier())
                        .disabled(model.isLoading)
                        .accessibilityLabel("Синхронизировать Spotify")
                    }

                    // Only saved and recently played modes. Manually added links
                    // remain in Collection and participate in "Моя библиотека".
                    Picker("Источник", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(CollectionMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(5)
                    .vinylGlassSurface(cornerRadius: 17)

                    if let album = model.current {
                        VinylFeatureCard(album: album, accent: model.accent)

                        HStack(spacing: 12) {
                            Button { model.shuffle() } label: {
                                Label("Другой альбом", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .modifier(VinylGlassButtonModifier(prominent: true))
                            if let link = album.link {
                                Button { openURL(link) } label: {
                                    Label("Spotify", systemImage: "play.fill")
                                }
                                .modifier(VinylGlassButtonModifier())
                            }
                        }

                        Button { Task { await model.publishToWidget(album) } } label: {
                            Label(model.widgetBusy ? "Отправляем…" : "Добавить в виджет", systemImage: "plus.rectangle.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .modifier(VinylGlassButtonModifier())
                        .disabled(model.widgetBusy)

                        Button { reviewAlbum = album } label: {
                            HStack {
                                Label("Моя оценка", systemImage: "star")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(model.ratings[album.id].map { "\($0) / 10 · Открыть" } ?? "Оценить альбом")
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(17)
                            .vinylGlassSurface(cornerRadius: 23)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ContentUnavailableView("Нет альбомов", systemImage: "opticaldisc", description: Text("Подключи Spotify в настройках или добавь альбом через «Коллекция → +»."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                }
                .padding(.horizontal, 20)
                .padding(.top, 17)
                .padding(.bottom, 34)
            }
            .background(VinylBackdrop(accent: model.accent))
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $reviewAlbum) { album in
                AlbumReviewFlowView(album: album).environmentObject(model)
            }
        }
    }
}

struct VinylFeatureCard: View {
    let album: VinylAlbum
    let accent: RGBColor

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            RemoteArtwork(url: album.artwork)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
            Text(album.name)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.6)
            Text(album.artist).font(.title3).foregroundStyle(.white.opacity(0.86))
            Text(album.year).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .fill(LinearGradient(colors: [accent.swiftUIColor.opacity(0.92), Color.black.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .vinylGlassSurface(cornerRadius: 31)
    }
}

/// A shared tappable album row used in Library and Rated Albums.
struct AlbumListRow: View {
    let album: VinylAlbum
    let rating: Int?
    var reviewDate: Date? = nil

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(url: album.artwork).frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name).font(.headline).lineLimit(1)
                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let reviewDate {
                    Text("Оценён: " + reviewDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(album.year).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 5)
            if let rating {
                Text("\(rating)/10")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .vinylGlassSurface(cornerRadius: 16)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(13)
        .vinylGlassSurface(cornerRadius: 22)
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VinylBackdrop(accent: model.accent))
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
    @State private var reviewAlbum: VinylAlbum?
    @State private var search = ""

    private var filtered: [VinylAlbum] {
        model.ratedAlbums.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { album in
                    Button { reviewAlbum = album } label: {
                        AlbumListRow(album: album, rating: model.ratings[album.id],
                                     reviewDate: model.review(for: album)?.ratedAt)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VinylBackdrop(accent: model.accent))
            .searchable(text: $search, prompt: "Найти среди оценённых")
            .navigationTitle("Оценённые · \(model.ratedAlbums.count)")
            .fullScreenCover(item: $reviewAlbum) { album in
                AlbumReviewFlowView(album: album).environmentObject(model)
            }
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
    @State private var showReview = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RemoteArtwork(url: album.artwork)
                        .frame(width: 185, height: 185)
                    // Show a compact score on the right only for rated albums.
                    // Unrated albums keep the original centered title treatment.
                    if let score = model.ratings[album.id], (1...10).contains(score) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(album.name).font(.title2.weight(.bold))
                                    .multilineTextAlignment(.leading)
                                Text(album.artist).foregroundStyle(.secondary)
                                Text(album.year).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("\(score)/10")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .vinylGlassSurface(cornerRadius: 16)
                                .accessibilityLabel("Моя оценка: \(score) из 10")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 5)
                    } else {
                        VStack(spacing: 5) {
                            Text(album.name).font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                            Text(album.artist).foregroundStyle(.secondary)
                            Text(album.year).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 5)
                    }

                    Button {
                        Task {
                            await model.publishToWidget(album)
                            dismiss()
                        }
                    } label: {
                        Label(model.widgetBusy ? "Отправляем в виджет…" : "Добавить в виджет", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(VinylGlassButtonModifier(prominent: true))
                    .disabled(model.widgetBusy)

                    if let spotify = album.link {
                        Button {
                            openURL(spotify)
                        } label: {
                            Label("Открыть в Spotify", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .modifier(VinylGlassButtonModifier())
                    }

                    Button {
                        if model.saved.contains(where: { $0.id == album.id }) || model.manual.contains(where: { $0.id == album.id }) { model.setMode(.saved) }
                        else { model.setMode(.recent) }
                        model.select(album)
                        dismiss()
                    } label: {
                        Label("Показать на главном экране", systemImage: "square.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(VinylGlassButtonModifier())

                    Button { showReview = true } label: {
                        HStack {
                            Label(model.ratings[album.id] == nil ? "Оценить альбом" : "Моя рецензия", systemImage: "star")
                            Spacer()
                            Text(model.ratings[album.id].map { "\($0) / 10" } ?? "Открыть")
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding(14)
                        .vinylGlassSurface(cornerRadius: 17)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(VinylBackdrop(accent: model.accent))
            .navigationTitle("Альбом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.large])
        .fullScreenCover(isPresented: $showReview) {
            AlbumReviewFlowView(album: album).environmentObject(model)
        }
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
                    Text("VINYL 1.3 — Reviews & Liquid Glass. Неофициальное приложение, не связано со Spotify AB.")
                    Text("Оценки хранятся на iPhone. Spotify и GitHub токены — в Keychain.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(VinylBackdrop(accent: model.accent))
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
            .scrollContentBackground(.hidden)
            .background(VinylBackdrop(accent: model.accent))
            .navigationTitle("Альбом по ссылке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}
