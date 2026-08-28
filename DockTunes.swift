import AppKit
import Accelerate
import CoreServices
import ApplicationServices
import AudioToolbox
import CoreAudio
import CryptoKit
import Network
import ServiceManagement

// MARK: - Spotify-Anbindung

private struct Track: Equatable {
    var spotifyRunning = false
    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var artworkURL = ""
    var uri = ""
    var duration: TimeInterval = 0     // Sekunden
    var position: TimeInterval = 0     // Sekunden

    var hasTrack: Bool { spotifyRunning && !title.isEmpty }
}

private enum Spotify {
    /// AppleScript ist nicht thread-sicher – alle Aufrufe laufen hier hintereinander.
    private static let queue = DispatchQueue(label: "de.jancko.docktunes.spotify")
    private static let bundleID = "com.spotify.client"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func load(_ completion: @escaping (Track) -> Void) {
        queue.async {
            var track = Track()
            guard isRunning else {
                DispatchQueue.main.async { completion(track) }
                return
            }
            track.spotifyRunning = true
            let source = """
            tell application "Spotify"
              set playerStatus to (player state as text)
              set trackName to name of current track
              set trackArtist to artist of current track
              set trackAlbum to album of current track
              set coverURL to artwork url of current track
              set trackLength to duration of current track
              set playPos to player position
              set trackURI to spotify url of current track
              return playerStatus & "\\n" & trackName & "\\n" & trackArtist & "\\n" & coverURL ¬
                & "\\n" & trackLength & "\\n" & playPos & "\\n" & trackURI & "\\n" & trackAlbum
            end tell
            """
            if let raw = runCached(source) {
                let parts = raw.components(separatedBy: "\n")
                if parts.count >= 7 {
                    track.isPlaying = parts[0] == "playing"
                    track.title = parts[1]
                    track.artist = parts[2]
                    track.artworkURL = parts[3]
                    if parts.count >= 8 { track.album = parts[7] }
                    // Länge kommt in Millisekunden, Position in Sekunden.
                    track.duration = (number(parts[4]) ?? 0) / 1000
                    track.position = number(parts[5]) ?? 0
                    track.uri = parts[6]
                }
            }
            DispatchQueue.main.async { completion(track) }
        }
    }

    /// AppleScript liefert je nach Sprache "43,04" oder "43.04".
    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    static func send(_ command: String) {
        queue.async { _ = run("tell application \"Spotify\" to \(command)") }
    }

    /// Ganze Sekunden – so bleibt die Zahl unabhängig vom Dezimaltrennzeichen.
    static func seek(to seconds: TimeInterval) {
        send("set player position to \(Int(max(0, seconds.rounded())))")
    }

    /// Setzt die Lautstaerke unmittelbar.
    static func setVolume(_ level: Int) {
        send("set sound volume to \(max(0, min(100, level)))")
    }

    /// Liest den aktuellen Stand.
    static func readVolume(_ completion: @escaping (Int?) -> Void) {
        queue.async {
            let value = Int(run("tell application \"Spotify\" to return sound volume") ?? "")
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Spotifys eigener Regler – meldet den neuen Stand zurueck.
    /// AppleScript kennt kein max/min als Operator, deshalb ausgeschrieben.
    static func changeSpotifyVolume(by delta: Int, completion: @escaping (Int) -> Void) {
        queue.async {
            let source = """
            tell application "Spotify"
              set newLevel to (sound volume) + (\(delta))
              if newLevel < 0 then set newLevel to 0
              if newLevel > 100 then set newLevel to 100
              set sound volume to newLevel
              return newLevel
            end tell
            """
            let level = Int(run(source) ?? "") ?? -1
            DispatchQueue.main.async { completion(max(0, level)) }
        }
    }

    /// Systemlautstaerke, wenn in den Einstellungen gewaehlt.
    static func changeSystemVolume(by delta: Int) {
        queue.async {
            let source = "set volume output volume (max(0, min(100, (output volume of (get volume settings)) + (\(delta)))))"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    static func activate() {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.activate()
    }

    /// -1743 = Steuern nicht erlaubt. Wird hier nebenbei mitgelesen; eine eigene
    /// Berechtigungsanfrage per AEDeterminePermissionToAutomateTarget haengt
    /// aus einem Nebenthread heraus dauerhaft und ist deshalb keine Option.
    private(set) static var permissionDenied = false

    /// Das Übersetzen des Skripts kostet rund ein Viertel der Laufzeit –
    /// einmal übersetzt und behalten.
    private static var cachedScript: NSAppleScript?

    private static func runCached(_ source: String) -> String? {
        if cachedScript == nil { cachedScript = NSAppleScript(source: source) }
        var error: NSDictionary?
        let result = cachedScript?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            permissionDenied = (code == -1743)
            return nil
        }
        permissionDenied = false
        return result?.stringValue
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            permissionDenied = (code == -1743)
            return nil
        }
        permissionDenied = false
        return result?.stringValue
    }
}

// MARK: - Spotifys Web-Schnittstelle

/// Zum Einsortieren in Playlists reicht AppleScript nicht – das kann nur die
/// Web-Schnittstelle. Angemeldet wird mit PKCE, damit kein Client-Geheimnis
/// in der App liegen muss; nötig ist allein die Client-ID.
private enum SpotifyWeb {
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = "playlist-read-private playlist-modify-private playlist-modify-public"

    struct Playlist: Codable, Equatable {
        let id: String
        let name: String
    }

    // MARK: Ablage

    static var clientID: String? {
        get { UserDefaults.standard.string(forKey: "spotifyClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyClientID") }
    }
    static var defaultPlaylist: Playlist? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "defaultPlaylist") else { return nil }
            return try? JSONDecoder().decode(Playlist.self, from: data)
        }
        set {
            let data = newValue.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "defaultPlaylist")
        }
    }

    /// Zugangsdaten liegen in einer nur fuer den Benutzer lesbaren Datei
    /// (~/Library/Application Support/DockTunes/credentials.json, Rechte 0600).
    ///
    /// Der Schluessebund waere der schoenere Ort, ist hier aber unpraktikabel:
    /// Sein Eintrag haengt an der konkreten Programmdatei, weshalb macOS nach
    /// jedem Neubau nachfragt; und der rueckfragefreie Data-Protection-Bereich
    /// steht Apps ohne Apple-Entwicklerberechtigungen nicht offen (nachgeprueft).
    /// Gespeichert wird ein Spotify-Auffrischungstoken, dessen Rechte auf das
    /// Lesen und Aendern von Playlists beschraenkt sind.
    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockTunes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("credentials.json")
    }

    private static func loadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func keychainSet(_ value: String?, for account: String) {
        var store = loadStore()
        if let value { store[account] = value } else { store.removeValue(forKey: account) }
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private static func keychainGet(_ account: String) -> String? {
        loadStore()[account]
    }

    private(set) static var accessToken: String? {
        get { keychainGet("accessToken") }
        set { keychainSet(newValue, for: "accessToken") }
    }
    private(set) static var refreshToken: String? {
        get { keychainGet("refreshToken") }
        set { keychainSet(newValue, for: "refreshToken") }
    }
    private static var tokenExpiry: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "tokenExpiry")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "tokenExpiry") }
    }

    /// Absichtlich ohne Schlüsselbund-Zugriff: den beim Start abzufragen löst
    /// eine Rückfrage von macOS aus, die die App blockiert. Der Schlüsselbund
    /// wird erst gelesen, wenn wirklich eine Anfrage ansteht.
    static var isLinked: Bool {
        UserDefaults.standard.bool(forKey: "spotifyLinked") && clientID != nil
    }

    /// Schreibt und liest einen Testeintrag – zeigt, ob die Ablage nutzbar ist.
    static func storageCheck() -> String {
        keychainSet("probe", for: "selftest")
        let readBack = keychainGet("selftest")
        keychainSet(nil, for: "selftest")
        return readBack == "probe" ? "nutzbar" : "NICHT nutzbar"
    }
    private static func setLinked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "spotifyLinked")
    }

    static func unlink() {
        setLinked(false)
        keychainSet(nil, for: "accessToken")
        keychainSet(nil, for: "refreshToken")
        defaultPlaylist = nil
    }

    // MARK: Anmeldung (PKCE)

    private static var verifier = ""
    private static var listener: CallbackListener?

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Öffnet die Spotify-Anmeldung im Browser und wartet auf die Rückleitung.
    static func authorize(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let clientID else {
            completion(.failure(SimpleError("Es ist noch keine Client-ID hinterlegt.")))
            return
        }
        verifier = randomString(64)
        let state = randomString(16)

        listener = CallbackListener(port: 8888) { code, returnedState in
            listener?.stop()
            listener = nil
            guard returnedState == state else {
                DispatchQueue.main.async { completion(.failure(SimpleError("Antwort passt nicht zur Anfrage."))) }
                return
            }
            guard let code else {
                DispatchQueue.main.async { completion(.failure(SimpleError("Die Anmeldung wurde abgebrochen."))) }
                return
            }
            exchange(code: code, clientID: clientID, completion: completion)
        }
        guard listener?.start() == true else {
            completion(.failure(SimpleError("Port 8888 ist belegt – die Rückleitung kann nicht empfangen werden.")))
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge(for: verifier)),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    private static func exchange(code: String, clientID: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = json["access_token"] as? String else {
                    completion(.failure(SimpleError("Spotify hat keinen Zugang ausgestellt.")))
                    return
                }
                accessToken = access
                refreshToken = (json["refresh_token"] as? String) ?? refreshToken
                tokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
                setLinked(true)
                completion(.success(()))
            }
        }.resume()
    }

    private static func refreshIfNeeded(completion: @escaping (String?) -> Void) {
        if let token = accessToken, Date() < tokenExpiry.addingTimeInterval(-60) {
            completion(token)
            return
        }
        guard let refreshToken, let clientID else { completion(nil); return }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientID)".data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            accessToken = access
            if let newRefresh = json["refresh_token"] as? String { self.refreshToken = newRefresh }
            tokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
            DispatchQueue.main.async { completion(access) }
        }.resume()
    }

    // MARK: Abfragen

    private static func call(_ path: String, method: String = "GET", body: Data? = nil,
                             completion: @escaping (Result<Data, Error>) -> Void) {
        refreshIfNeeded { token in
            guard let token else {
                completion(.failure(SimpleError("Nicht mit Spotify verbunden.")))
                return
            }
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/" + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    if let error { completion(.failure(error)); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        completion(.failure(SimpleError("Spotify antwortete mit Fehler \(status).")))
                        return
                    }
                    completion(.success(data ?? Data()))
                }
            }.resume()
        }
    }

    static func loadPlaylists(completion: @escaping (Result<[Playlist], Error>) -> Void) {
        call("me/playlists?limit=50") { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    completion(.failure(SimpleError("Playlists konnten nicht gelesen werden.")))
                    return
                }
                let playlists = items.compactMap { item -> Playlist? in
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                    return Playlist(id: id, name: name)
                }
                completion(.success(playlists))
            }
        }
    }

    static func add(trackURI: String, to playlist: Playlist,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        let body = try? JSONSerialization.data(withJSONObject: ["uris": [trackURI]])
        call("playlists/\(playlist.id)/tracks", method: "POST", body: body) { result in
            completion(result.map { _ in () })
        }
    }
}

private struct SimpleError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Nimmt die Rückleitung der Spotify-Anmeldung auf 127.0.0.1 entgegen.
private final class CallbackListener {
    private let port: UInt16
    private let onCode: (String?, String?) -> Void
    private var listener: NWListener?

    init(port: UInt16, onCode: @escaping (String?, String?) -> Void) {
        self.port = port
        self.onCode = onCode
    }

    func start() -> Bool {
        guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { return false }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
                let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let components = URLComponents(string: "http://127.0.0.1" + path)
                let code = components?.queryItems?.first { $0.name == "code" }?.value
                let state = components?.queryItems?.first { $0.name == "state" }?.value

                let page = code != nil
                    ? "<h2>Fertig.</h2><p>DockTunes ist jetzt mit Spotify verbunden. Dieses Fenster kann geschlossen werden.</p>"
                    : "<h2>Abgebrochen.</h2><p>Es wurde kein Zugang erteilt.</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
                    + "<html><body style=\"font-family:-apple-system;padding:3em\">" + page + "</body></html>"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self.onCode(code, state)
            }
        }
        listener.start(queue: .global())
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Playlist-Auswahl

/// Zaehlt y von oben – so laesst sich eine Liste ohne Rechnerei anordnen.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ListView: FlippedView {}


/// Eigenes Fenster statt eines langen Systemmenüs: Favoriten oben, Suchfeld,
/// der Rest darunter.
private final class PlaylistPicker: NSPanel, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let list = ListView()
    private let scroll = NSScrollView()
    private var all: [SpotifyWeb.Playlist] = []
    private var showsAll = false
    private let previewCount = 3
    private let onPick: (SpotifyWeb.Playlist) -> Void
    var onClose: (() -> Void)?

    static var favorites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "favoritePlaylists") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "favoritePlaylists") }
    }

    init(playlists: [SpotifyWeb.Playlist], onPick: @escaping (SpotifyWeb.Playlist) -> Void) {
        self.all = playlists
        self.onPick = onPick
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient]
        isMovableByWindowBackground = false

        let container = NSView(frame: contentLayoutRect)
        container.wantsLayer = true

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let tint = UserDefaults.standard.object(forKey: isDark ? "tintDark" : "tintLight") as? Double
                ?? (isDark ? 0.30 : 0.34)
            let white = UserDefaults.standard.object(forKey: isDark ? "whiteDark" : "whiteLight") as? Double
                ?? (isDark ? 0.16 : 0.97)
            glass.tintColor = NSColor(calibratedWhite: white, alpha: tint)
            glass.contentView = NSView()
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            if let forced = UserDefaults.standard.object(forKey: "materialDark") as? Bool {
                effect.appearance = NSAppearance(named: forced ? .darkAqua : .aqua)
            }
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
            background = effect
        }
        // Dieselben Werte wie beim Panel, damit beides aus einem Guss wirkt.
        let dark = container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shade = NSView(frame: container.bounds)
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        let opacity = UserDefaults.standard.object(forKey: dark ? "fillDark" : "fillLight") as? Double
            ?? (dark ? 0.14 : 0.10)
        let shadeWhite = UserDefaults.standard.object(forKey: dark ? "shadeDark" : "shadeLight") as? Double
            ?? (dark ? 0.18 : 0.70)
        shade.layer?.backgroundColor = NSColor(calibratedWhite: shadeWhite, alpha: opacity).cgColor
        shade.layer?.cornerRadius = 16
        shade.layer?.masksToBounds = true
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)
        container.addSubview(shade)

        searchField.placeholderString = "Playlist suchen"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.frame = NSRect(x: 12, y: container.bounds.height - 38, width: 276, height: 24)
        searchField.autoresizingMask = [.width, .minYMargin]
        container.addSubview(searchField)


        scroll.frame = NSRect(x: 6, y: 6, width: 288, height: container.bounds.height - 50)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        // Nur zeigen, wenn wirklich mehr da ist, als hineinpasst – bei der
        // gekuerzten Vorschau ist das nie der Fall.
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = list
        container.addSubview(scroll)

        // Beim Scrollen kommt kein mouseExited – ohne das bliebe die
        // Hervorhebung auf der Zeile kleben, die vorher unter dem Zeiger lag.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.refreshHoverStates()
        }

        contentView = container
        rebuild(filter: "")
    }

    override var canBecomeKey: Bool { true }

    func controlTextDidChange(_ obj: Notification) {
        rebuild(filter: searchField.stringValue)
    }

    /// Nach dem Scrollen neu bestimmen, welche Zeile wirklich unter dem Zeiger liegt.
    private func refreshHoverStates() {
        let mouse = list.convert(NSEvent.mouseLocation, from: nil)
        let inWindow = contentView?.convert(NSEvent.mouseLocation, from: nil)
        for case let row as PickerRow in list.subviews {
            let inside = row.frame.contains(mouse) && (inWindow.map { scroll.frame.contains($0) } ?? false)
            row.setHovered(inside)
        }
    }

    private func rebuild(filter: String) {
        list.subviews.forEach { $0.removeFromSuperview() }
        let favorites = Self.favorites
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? all : all.filter { $0.name.lowercased().contains(needle) }
        let favored = matching.filter { favorites.contains($0.id) }
        let others = matching.filter { !favorites.contains($0.id) }

        // Beim Suchen immer alles zeigen, sonst nur eine kurze Vorschau.
        let expanded = showsAll || !needle.isEmpty
        let shown = expanded ? others : Array(others.prefix(previewCount))
        let hidden = others.count - shown.count

        let width = scroll.contentSize.width
        var y: CGFloat = 4
        func place(_ view: NSView, height: CGFloat) {
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            list.addSubview(view)
            y += height
        }
        if !favored.isEmpty {
            place(header("Favoriten"), height: 20)
            favored.forEach { place(row(for: $0, isFavorite: true), height: 27) }
        }
        if !shown.isEmpty {
            if !favored.isEmpty { place(header("Weitere"), height: 22) }
            shown.forEach { place(row(for: $0, isFavorite: false), height: 27) }
        }
        if hidden > 0 {
            place(moreRow(count: hidden), height: 26)
        }
        if matching.isEmpty { place(header("Nichts gefunden"), height: 22) }

        let contentHeight = y + 4
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(contentHeight, scroll.contentSize.height))
        scroll.documentView?.scroll(NSPoint(x: 0, y: 0))
        fitHeight(contentHeight: contentHeight)
    }

    /// Fenster nur so hoch wie noetig – hoechstens aber bildschirmvertraeglich.
    private func fitHeight(contentHeight: CGFloat) {
        let chrome: CGFloat = 50
        let wanted = min(max(contentHeight + chrome, 140), 460)
        // Leiste nur, wenn tatsaechlich mehr da ist als hineinpasst
        scroll.hasVerticalScroller = contentHeight > wanted - chrome + 1
        guard abs(frame.height - wanted) > 1 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - wanted, width: frame.width, height: wanted), display: true)
    }

    private func moreRow(count: Int) -> NSView {
        let row = PickerRow(frame: NSRect(x: 0, y: 0, width: 288, height: 26))
        row.playlist = SpotifyWeb.Playlist(id: "__more__", name: "\(count) weitere anzeigen …")
        row.isMoreRow = true
        row.onPick = { [weak self] in
            self?.showsAll = true
            self?.rebuild(filter: self?.searchField.stringValue ?? "")
        }
        return row
    }

    private func header(_ title: String) -> NSView {
        let holder = FlippedView()
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 12, y: 4, width: 240, height: 14)
        holder.addSubview(label)
        return holder
    }

    private func row(for playlist: SpotifyWeb.Playlist, isFavorite: Bool) -> NSView {
        let row = PickerRow(frame: NSRect(x: 0, y: 0, width: 288, height: 27))
        row.playlist = playlist
        row.isFavorite = isFavorite
        row.onPick = { [weak self] in self?.onPick(playlist); self?.close() }
        row.onToggleFavorite = { [weak self] in
            var favorites = Self.favorites
            if favorites.contains(playlist.id) { favorites.remove(playlist.id) }
            else { favorites.insert(playlist.id) }
            Self.favorites = favorites
            self?.rebuild(filter: self?.searchField.stringValue ?? "")
        }
        return row
    }

    func show(near point: NSPoint) {
        var origin = point
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            origin.x = min(max(screen.frame.minX + 8, origin.x - frame.width / 2), screen.frame.maxX - frame.width - 8)
            origin.y = max(screen.frame.minY + 8, origin.y)
        }
        setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        super.close()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Eine Zeile: Stern zum Merken, Name zum Auswählen.
private final class PickerRow: FlippedView {
    var playlist: SpotifyWeb.Playlist?
    var onPick: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var isFavorite = false { didSet { star.image = starImage } }
    var isMoreRow = false { didSet { star.isHidden = isMoreRow; needsDisplay = true } }

    private let star = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }

    func setHovered(_ value: Bool) { hovered = value }
    private var tracking: NSTrackingArea?

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = isDark ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
        star.contentTintColor = isDark ? NSColor(white: 1, alpha: 0.6) : NSColor(calibratedWhite: 0.4, alpha: 1)
    }

    private var starImage: NSImage? {
        NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                accessibilityDescription: isFavorite ? "Favorit entfernen" : "Als Favorit merken")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        star.isBordered = false
        star.bezelStyle = .regularSquare
        star.imageScaling = .scaleProportionallyDown
        star.contentTintColor = .secondaryLabelColor
        star.target = self
        star.action = #selector(toggleFavorite)
        star.frame = NSRect(x: 9, y: 5, width: 16, height: 16)
        addSubview(star)

        label.font = .systemFont(ofSize: 12)
        label.textColor = isDark ? .white : NSColor(calibratedWhite: 0.12, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 32, y: 4, width: 244, height: 17)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 288, height: 26) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        label.stringValue = playlist?.name ?? ""
        star.image = starImage
        if isMoreRow {
            label.frame = NSRect(x: 12, y: 4, width: 264, height: 17)
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = isDark ? NSColor(white: 1, alpha: 0.6) : NSColor(calibratedWhite: 0.4, alpha: 1)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onPick?() }

    @objc private func toggleFavorite() { onToggleFavorite?() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

// MARK: - Liedtexte

/// Zeitsynchrone Texte von lrclib.net – einem offenen Verzeichnis ohne Anmeldung.
/// Dorthin gehen Titel und Interpret des laufenden Songs, sonst nichts.
private enum Lyrics {
    struct Line {
        let time: TimeInterval
        let text: String
    }

    private static var cache: [String: [Line]] = [:]
    private static var missing: Set<String> = []
    private static var pending: Set<String> = []

    /// nil = noch nicht geladen, leeres Feld = es gibt keinen synchronen Text
    static func lines(for track: Track, completion: @escaping ([Line]) -> Void) {
        let key = track.uri
        guard !key.isEmpty, !track.title.isEmpty else { completion([]); return }
        if let cached = cache[key] { completion(cached); return }
        if missing.contains(key) { completion([]); return }
        guard !pending.contains(key) else { return }
        pending.insert(key)

        fetch(path: "get", track: track) { direct in
            if !direct.isEmpty { finish(key, direct, completion); return }
            // Der Standardeintrag hat oft keine Zeitstempel, andere Fassungen
            // desselben Songs schon. Also die Trefferliste durchsehen.
            fetch(path: "search", track: track) { found in
                finish(key, found, completion)
            }
        }
    }

    private static func finish(_ key: String, _ lines: [Line], _ completion: @escaping ([Line]) -> Void) {
        pending.remove(key)
        if lines.isEmpty { missing.insert(key) } else { cache[key] = lines }
        if cache.count > 30 { cache.removeAll() }
        completion(lines)
    }

    private static func fetch(path: String, track: Track, completion: @escaping ([Line]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/" + path)!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
        ]
        guard let url = components.url else { completion([]); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("DockTunes/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            // Die Laufzeit muss passen, nicht nur am besten von mehreren sein:
            // Gleichnamige Stuecke anderer Interpreten landen sonst als Treffer
            // im Panel (beobachtet: "Jenny" von LOTTE, 275 s, gegen "Jenny" von
            // Kurt Weill, 244 s). Ohne passende Fassung lieber keinen Text.
            let tolerance: TimeInterval = 4
            func fits(_ entry: [String: Any]) -> Bool {
                guard track.duration > 0, let d = entry["duration"] as? Double,
                      abs(d - track.duration) <= tolerance else { return false }
                // Auch der Interpret muss passen: gleichnamige Stuecke anderer
                // Kuenstler haben mitunter zufaellig aehnliche Laufzeiten.
                guard let found = entry["artistName"] as? String else { return true }
                return Lyrics.artistsMatch(found, track.artist)
            }
            var parsed: [Line] = []
            if let data, let raw = try? JSONSerialization.jsonObject(with: data) {
                if let single = raw as? [String: Any] {
                    if fits(single) { parsed = parse((single["syncedLyrics"] as? String) ?? "") }
                } else if let list = raw as? [[String: Any]] {
                    let candidates = list.filter {
                        ($0["syncedLyrics"] as? String)?.isEmpty == false && fits($0)
                    }
                    let best = candidates.min { a, b in
                        let da = abs(((a["duration"] as? Double) ?? 0) - track.duration)
                        let db = abs(((b["duration"] as? Double) ?? 0) - track.duration)
                        return da < db
                    }
                    parsed = parse((best?["syncedLyrics"] as? String) ?? "")
                }
            }
            DispatchQueue.main.async { completion(parsed) }
        }.resume()
    }

    /// Vergleicht Interpretennamen nachsichtig: Gross- und Kleinschreibung,
    /// Zusaetze wie "feat." und Trennzeichen sollen nicht zum Fehlschlag fuehren.
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        func normalise(_ text: String) -> String {
            let lowered = text.lowercased()
                .replacingOccurrences(of: "&", with: " ")
                .replacingOccurrences(of: "feat.", with: " ")
                .replacingOccurrences(of: "featuring", with: " ")
            let allowed = lowered.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == " "
            }
            return String(String.UnicodeScalarView(allowed))
                .split(separator: " ").joined(separator: " ")
        }
        let left = normalise(a), right = normalise(b)
        guard !left.isEmpty, !right.isEmpty else { return true }
        if left == right { return true }
        // Ein Name darf im anderen stecken (z. B. "Berq" in "Berq, Alli Neumann")
        if left.contains(right) || right.contains(left) { return true }
        // Oder wenigstens der erste Namensteil stimmt ueberein
        let leftFirst = left.split(separator: " ").first ?? ""
        let rightFirst = right.split(separator: " ").first ?? ""
        return !leftFirst.isEmpty && leftFirst == rightFirst
    }

    /// Zeilen im Format "[mm:ss.hh] Text"
    private static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        for raw in lrc.split(separator: "\n") {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let stamp = raw[raw.index(after: raw.startIndex)..<close]
            let parts = stamp.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { continue }
            let text = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
            lines.append(Line(time: minutes * 60 + seconds, text: String(text)))
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Aktuelle und nächste Zeile zur Wiedergabeposition.
    static func at(_ position: TimeInterval, in lines: [Line]) -> (current: String, next: String) {
        guard !lines.isEmpty else { return ("", "") }
        var index = -1
        for (i, line) in lines.enumerated() where line.time <= position + 0.25 { index = i }
        let current = index >= 0 ? lines[index].text : ""
        let next = index + 1 < lines.count ? lines[index + 1].text : ""
        // Instrumentalpausen haben leere Zeilen – dann die nächste vorziehen
        if current.isEmpty && !next.isEmpty { return (next, "") }
        return (current, next)
    }
}

// MARK: - Position des Docks

private enum Dock {
    /// Das sichtbare Dock-Glas sitzt konstant 5 Punkte tiefer als die Symbolliste,
    /// die die Bedienungshilfen melden – nachgemessen bei Dock-Größe 35, 50 und 70.
    static let glassOffsetY: CGFloat = 5

    private static var cachedPID: pid_t = 0
    private static var cachedElement: AXUIElement?
    private static var lastLookup = Date.distantPast

    /// Die Prozessliste zu durchsuchen kostet 0,2 ms – bei 60 Abfragen je Sekunde
    /// ist das der teuerste Posten. Der Dock-Prozess wechselt praktisch nie,
    /// also reicht ein Blick alle zwei Sekunden.
    private static func element() -> AXUIElement? {
        let now = Date()
        if let cachedElement, now.timeIntervalSince(lastLookup) < 2 { return cachedElement }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })
        else { return nil }
        lastLookup = now
        if app.processIdentifier != cachedPID || cachedElement == nil {
            cachedPID = app.processIdentifier
            cachedElement = AXUIElementCreateApplication(app.processIdentifier)
        }
        return cachedElement
    }

    /// Rechteck des sichtbaren Dock-Glases in Fensterkoordinaten.
    static func frame() -> CGRect? {
        guard let dock = element() else { return nil }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children {
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
            guard (roleValue as? String) == kAXListRole as String else { continue }

            var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success
            else { continue }

            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            guard size.width > 1, size.height > 1 else { continue }

            let list = CGRect(origin: origin, size: size)
            let referenceMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            // AX zählt y von oben, Fenster von unten – und das Glas liegt tiefer.
            return CGRect(x: list.minX,
                          y: referenceMaxY - list.maxY - glassOffsetY,
                          width: list.width,
                          height: list.height)
        }
        return nil
    }
}

// MARK: - Zeitleiste

private final class ProgressBar: NSView {
    // Wie bei den Balken: gezeichnet wuerde jeder Tick die Glasflaeche neu
    // mischen. Als Ebenen kostet die Leiste im Hover fast nichts.
    private let groove = CALayer()
    private let filled = CALayer()
    private let knob = CALayer()

    /// Bei drei Minuten Spielzeit und 190 Punkten Breite wandert der Strich
    /// alle anderthalb Sekunden um einen Punkt. Zehnmal je Sekunde neu zu
    /// setzen laesst die Glasflaeche zehnmal neu mischen, fuer nichts.
    var progress: Double = 0 {
        didSet { if filledWidth(progress) != filledWidth(oldValue) { apply() } }
    }

    private func filledWidth(_ value: Double) -> CGFloat {
        round(bounds.width * CGFloat(min(1, max(0, value))))
    }
    var tone: NSColor = .labelColor { didSet { apply() } }
    var showsVolume = false
    var onScrub: ((Double) -> Void)?      // während des Ziehens
    var onSeek: ((Double) -> Void)?       // beim Loslassen
    private var dragging = false { didSet { apply() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sub in [groove, filled, knob] { layer?.addSublayer(sub) }
        knob.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("nicht verwendet") }

    override func layout() {
        super.layout()
        apply()
    }

    private func apply() {
        guard bounds.width > 1 else { return }
        let barHeight: CGFloat = 3
        // Mittig im Feld – so liegt der Strich auf einer Linie mit den Zeiten
        // links und rechts davon. Der Rest des Feldes bleibt Trefferbereich.
        let y = (bounds.height - barHeight) / 2
        let width = bounds.width * CGFloat(min(1, max(0, progress)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groove.frame = CGRect(x: 0, y: y, width: bounds.width, height: barHeight)
        groove.cornerRadius = barHeight / 2
        groove.backgroundColor = tone.withAlphaComponent(0.22).cgColor
        filled.frame = CGRect(x: 0, y: y, width: max(barHeight, width), height: barHeight)
        filled.cornerRadius = barHeight / 2
        filled.backgroundColor = tone.withAlphaComponent(0.85).cgColor
        knob.isHidden = !dragging
        if dragging {
            knob.frame = CGRect(x: filled.frame.maxX - 4, y: y + barHeight / 2 - 4, width: 8, height: 8)
            knob.cornerRadius = 4
            knob.backgroundColor = tone.cgColor
        }
        CATransaction.commit()
    }

    private func fraction(for event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        return Double(min(max(0, x / max(1, bounds.width)), 1))
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        let f = fraction(for: event)
        progress = f
        onScrub?(f)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let f = fraction(for: event)
        progress = f
        onScrub?(f)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let f = fraction(for: event)
        progress = f
        onSeek?(f)
    }
}


// MARK: - Tonanalyse

/// Liest Spotifys Ausgabesignal über einen Core-Audio-Prozess-Tap mit und
/// zerlegt es per FFT in Frequenzbänder. Die Ausschläge sitzen dadurch auf dem
/// echten Ton – nicht auf einer geschätzten Taktzahl.
private final class AudioSpectrum {
    static let bandCount = 7

    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var ring: [Float]
    private var writeIndex = 0
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    private var levels = [Float](repeating: 0, count: bandCount)

    // Feste Puffer statt neuer bei jedem Durchlauf: 30 Durchlaeufe je Sekunde
    // mal vier Anlagen sind 120 Speicheranforderungen je Sekunde fuer nichts.
    private var samples: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private let log2n: vDSP_Length
    // Bandgrenzen logarithmisch: Bass links, Hoehen rechts
    private static let edges = [1, 3, 6, 12, 24, 48, 96, 256]

    init() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize * 2)
        samples = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imaginary = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    private func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var inputPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &inputPID, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    @discardableResult
    func start(pid: pid_t) -> Bool {
        guard !isRunning, let procObject = processObject(for: pid) else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: [procObject])
        description.name = "DockTunes Analyse"
        description.isPrivate = true
        description.muteBehavior = .unmuted        // nur mithören, nichts stummschalten
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "DockTunes Analyse",
            kAudioAggregateDeviceUIDKey as String: "de.jancko.docktunes.tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let raw = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.bindMemory(to: Float.self, capacity: count)
            self.lock.lock()
            for i in 0..<count {
                self.ring[self.writeIndex] = samples[i]
                self.writeIndex = (self.writeIndex + 1) % self.ring.count
            }
            self.lock.unlock()
        }
        guard status == noErr, let procID else { stop(); return false }
        AudioDeviceStart(aggregateID, procID)
        isRunning = true
        return true
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        levels = [Float](repeating: 0, count: Self.bandCount)
    }

    /// Frequenzbänder, 0…1. Schnell im Anstieg, träge im Abfall – so bleiben Schläge sichtbar.
    func currentBands() -> [Float] {
        guard isRunning, let fftSetup else { return levels }

        // Der Ring ist doppelt so lang wie ein Fenster, die gesuchten Werte
        // liegen also in hoechstens zwei Stuecken am Stueck. Blockweise kopieren
        // statt Wert fuer Wert mit Modulo – das war die teuerste Schleife.
        lock.lock()
        let start = (writeIndex + fftSize) % ring.count
        let head = min(fftSize, ring.count - start)
        samples.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + start, count: head)
                if head < fftSize {
                    (dst.baseAddress! + head).update(from: src.baseAddress!, count: fftSize - head)
                }
            }
        }
        lock.unlock()

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP liefert unskaliert – ohne das hier stehen alle Balken am Anschlag.
                var scale = Float(1.0 / Double(2 * fftSize))
                vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(fftSize / 2))
                vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(fftSize / 2))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let edges = Self.edges
        for band in 0..<Self.bandCount {
            let from = edges[band], to = min(edges[band + 1], magnitudes.count)
            guard to > from else { continue }
            var sum: Float = 0
            for i in from..<to { sum += magnitudes[i] }
            let mean = sum / Float(to - from)
            // Musik fällt zu den Höhen hin natürlich ab (rund 6 dB je Band).
            // Ohne diesen Ausgleich blieben die rechten Balken dauerhaft flach.
            // Bereich -60…-15 dB nach Messung an echtem Material.
            let db = 10 * log10f(max(mean, 1e-12)) + Float(band) * 6
            let normalized = min(1, max(0, (db + 60) / 45))
            levels[band] = normalized > levels[band] ? normalized : levels[band] * 0.82 + normalized * 0.18
        }
        return levels
    }
}

// MARK: - Balkenanzeige

private final class SpectrumView: NSView {
    // Die Balken sitzen im Glas. Jedes draw(_:) dort laesst die ganze Flaeche
    // neu mischen – gemessen 1,7 ms je Durchlauf, bei 30 Durchlaeufen je
    // Sekunde also fuenf Prozent Rechenzeit. Als Ebenen genuegt es, Hoehe und
    // Deckkraft zu setzen; das erledigt der Compositor.
    private var bars: [CALayer] = []

    var bands: [Float] = [] {
        didSet {
            guard bands.count == oldValue.count else { rebuild(); return }
            // Unter einem Achtel Punkt ist der Unterschied nicht zu sehen.
            guard zip(bands, oldValue).contains(where: { abs($0 - $1) > 0.004 }) else { return }
            apply()
        }
    }
    var tone: NSColor = .labelColor { didSet { apply() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("nicht verwendet") }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        guard bands.count != bars.count else { apply(); return }
        bars.forEach { $0.removeFromSuperlayer() }
        bars = bands.map { _ in
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            return bar
        }
        apply()
    }

    private func apply() {
        guard !bars.isEmpty, bounds.width > 0 else { return }
        let gap: CGFloat = 2
        let barWidth = (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        guard barWidth > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)      // kein Nachziehen, der Wert gilt sofort
        for (i, bar) in bars.enumerated() {
            let value = CGFloat(bands.indices.contains(i) ? bands[i] : 0)
            let height = max(3, bounds.height * value)
            bar.frame = CGRect(x: CGFloat(i) * (barWidth + gap),
                               y: (bounds.height - height) / 2,
                               width: barWidth, height: height)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = tone.withAlphaComponent(0.35 + 0.5 * value).cgColor
        }
        CATransaction.commit()
    }
}

// MARK: - Panelinhalt

private final class PlayerView: NSView {
    let cover = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let artistLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let playButton = NSButton()
    let nextButton = NSButton()
    let addButton = NSButton()
    let progressBar = ProgressBar()
    let timeLabel = NSTextField(labelWithString: "")
    let totalLabel = NSTextField(labelWithString: "")
    let spectrum = SpectrumView()
    var showsSpectrum = false { didSet { needsLayout = true } }

    // Was bei welcher Breite dazukommt. Die Grenzen sind so gesetzt, dass ein
    // Element erst erscheint, wenn es ohne Gedraenge Platz hat – nicht sobald
    // es rechnerisch gerade so hineinpasst.
    private var showsArtistLine: Bool { bounds.width >= 260 }
    private var showsSkipButtons: Bool { bounds.width >= 320 }
    private var spectrumVisible: Bool { showsSpectrum && bounds.width >= 400 }
    var showsExtras: Bool { bounds.width >= 560 }
    /// Ganz breit ist auch fuer die naechste Liedtextzeile Platz – dann
    /// verdraengt sie die laufende nicht mehr.
    var showsLyricPreview: Bool { bounds.width >= 700 }
    /// Bei grosser Breite sieht das Panel dauerhaft so aus wie sonst beim
    /// Zeigen: Leiste und Zeiten sichtbar, Inhalt entsprechend angehoben.
    private var effectiveHover: CGFloat { showsExtras ? 1 : hoverProgress }
    var showsLyrics = false { didSet { cover.isHidden = showsLyrics; needsLayout = true } }

    private var glassView: NSView!
    private let content = NSView()
    private let shade = NSView()
    private let boost = NSView()
    private let rim = PassthroughView()
    private var glassEffect: NSView?
    private var tracking: NSTrackingArea?
    private var hoverProgress: CGFloat = 0
    private var hoverTimer: Timer?

    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Liquid Glass wie beim Dock, mit Rückfallebene für ältere Systeme.
        // "useGlass" auf NO erzwingt die Rückfallebene, "material" wählt sie.
        let wantsGlass = UserDefaults.standard.object(forKey: "useGlass") as? Bool ?? true
        if #available(macOS 26.0, *), wantsGlass {
            let glass = NSGlassEffectView()
            PlayerView.tune(glass)
            glassEffect = glass
            glass.contentView = content
            glassView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = PlayerView.material(named:
                UserDefaults.standard.string(forKey: "material") ?? "hudWindow")
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            glassView = effect
        }
        addSubview(glassView)

        // Das Glas allein bleibt durchlässiger als das Dock; diese Schicht
        // gleicht den Rest an. Wert per "glassOpacity" einstellbar.
        shade.wantsLayer = true
        content.addSubview(shade, positioned: .below, relativeTo: nil)
        // Additive Schicht: hebt die Flaeche an, ohne die Steigung zu aendern.
        // Nur so lassen sich Helligkeit und Durchlaessigkeit getrennt stellen.
        boost.wantsLayer = true
        content.addSubview(boost, positioned: .below, relativeTo: shade)

        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 5
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        content.addSubview(cover)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        content.addSubview(titleLabel)

        artistLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.cell?.usesSingleLineMode = true
        content.addSubview(artistLabel)

        for (button, symbol, description) in [
            (previousButton, "backward.fill", "Vorheriger Titel"),
            (playButton, "play.fill", "Abspielen"),
            (nextButton, "forward.fill", "Nächster Titel"),
            (addButton, "plus.circle", "Zur Playlist hinzufügen"),
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imageScaling = .scaleNone
            button.image = Self.symbol(symbol, description)
            button.contentTintColor = .labelColor
            content.addSubview(button)
        }

        progressBar.alphaValue = 0        // erscheint erst beim Zeigen
        content.addSubview(progressBar)

        for label in [timeLabel, totalLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
            label.alphaValue = 0
            content.addSubview(label)
        }
        timeLabel.alignment = .right
        totalLabel.alignment = .left

        content.addSubview(spectrum)

        // Das Dock hat eine helle Kante (gemessen 0,52 gegen 0,23 innen).
        // Ohne sie wirkt die Flaeche flach und eben nicht wie Apples Glas.
        rim.wantsLayer = true
        rim.layer?.masksToBounds = true
        addSubview(rim)

        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tatsaechlich bemalte Breite eines Symbols. Die Layout-Groesse taugt dafuer
    /// nicht: sie enthaelt Raender, die je Symbol verschieden ausfallen – gleiche
    /// Rahmen ergeben dann sichtbar ungleiche Abstaende.
    struct Ink { let left: CGFloat; let width: CGFloat; let right: CGFloat }
    private static var inkCache: [String: Ink] = [:]

    static func inkReport() -> String {
        inkCache.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.1f|%.1f|%.1f", $0.value.left, $0.value.width, $0.value.right))" }
            .joined(separator: " ")
    }

    static func ink(of image: NSImage?, key: String) -> Ink {
        guard let image else { return Ink(left: 0, width: 20, right: 0) }
        if let cached = inkCache[key] { return cached }
        // In genau der Groesse messen, in der der Knopf zeichnet – bei
        // abweichender Groesse faellt das Antialiasing anders aus und die
        // Kanten liegen um einen Punkt daneben.
        let scale: CGFloat = 1
        let w = Int(ceil(image.size.width * scale)), h = Int(ceil(image.size.height * scale))
        guard w > 0, h > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)
        else { return Ink(left: 0, width: image.size.width, right: 0) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()

        var first = w, last = -1
        for x in 0..<w {
            var painted = false
            for y in 0..<h where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.04 { painted = true; break }
            if painted { first = min(first, x); last = max(last, x) }
        }
        guard last >= first else { return Ink(left: 0, width: image.size.width, right: 0) }
        let result = Ink(left: CGFloat(first) / scale,
                         width: CGFloat(last - first + 1) / scale,
                         right: CGFloat(w - 1 - last) / scale)
        inkCache[key] = result
        return result
    }

    /// Groesse ausdruecklich setzen: NSButton skaliert Symbole nur herunter.
    static func symbol(_ name: String, _ description: String) -> NSImage? {
        let size = UserDefaults.standard.object(forKey: "symbolSize") as? Double ?? 17
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    /// Die Kanten zieht der Fenster-Server selbst; siehe PlayerPanel.
    override func mouseDown(with event: NSEvent) { onClick?() }

    var onScroll: ((Int) -> Void)?
    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // Eine Mausraste soll spuerbar etwas bewegen; Trackpads liefern viele
        // kleine Schritte und werden deshalb gesammelt.
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            // An die Schrittweite gekoppelt: die Lautstaerke soll je gewischtem
            // Zentimeter gleich weit wandern, egal ob in Zweier- oder
            // Fuenferschritten. Sonst waere der Regler bei groesseren Schritten
            // nach einem Wisch am Anschlag.
            let unit = UserDefaults.standard.object(forKey: "volumeStep") as? Int ?? 5
            let step = CGFloat(unit) * 1.5
            while abs(scrollAccumulator) >= step {
                onScroll?(scrollAccumulator > 0 ? 1 : -1)
                scrollAccumulator -= scrollAccumulator > 0 ? step : -step
            }
        } else if event.scrollingDeltaY != 0 {
            onScroll?(event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }

    /// Im Glas-Container greifen die semantischen Farben nicht zuverlaessig,
    /// deshalb nach tatsaechlicher Darstellung setzen – und bei jedem Wechsel neu.
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    /// Die Flaeche richtet sich nach dem, was hinter dem Panel liegt – gemessen
    /// zwischen 0,21 und 0,88 Helligkeit. Eine an den Systemmodus gekoppelte
    /// Textfarbe versagt dort zwangslaeufig. Heller Text mit Schatten bleibt
    /// auf beidem lesbar, so wie Untertitel es loesen.
    var primaryColor: NSColor { .white }
    var secondaryColor: NSColor { NSColor(calibratedWhite: 1, alpha: 0.8) }

    private func shadow(radius: CGFloat, opacity: Float) -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
        s.shadowBlurRadius = radius
        s.shadowOffset = NSSize(width: 0, height: -0.5)
        return s
    }

    /// Setzt Titel und Unterzeile samt Schatten. Ein Textfeld zeichnet die
    /// shadow-Eigenschaft nicht – der Schatten muss ins Textattribut.
    var onTextChange: (() -> Void)?

    private var lastTimeWidth: CGFloat = -1

    /// Die Zeiten bestimmen die Feldbreite und damit das ganze Layout. Ein
    /// Neulayout je Sekunde kostet mehr als es bringt: die Breite aendert sich
    /// nur beim Sprung auf zweistellige Minuten.
    func setTimes(running: String, total: String) {
        var changed = false
        if timeLabel.stringValue != running { timeLabel.stringValue = running; changed = true }
        if totalLabel.stringValue != total { totalLabel.stringValue = total; changed = true }
        guard changed else { return }
        let measured = max(ceil(timeLabel.attributedStringValue.size().width),
                           ceil(totalLabel.attributedStringValue.size().width))
        if measured != lastTimeWidth {
            lastTimeWidth = measured
            needsLayout = true
        }
    }

    /// Die neue Zeile steigt von unten ein und blendet auf – als Ebenen-
    /// animation, die der Compositor faehrt. Ein Neuzeichnen je Bild wuerde
    /// in der Glasflaeche ein Vielfaches kosten.
    private func animateLine(_ label: NSTextField, rise: CGFloat, delay: CFTimeInterval) {
        label.wantsLayer = true
        guard let layer = label.layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -rise
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.26
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "zeilenwechsel")
    }

    private var lastTitle: String?
    private var lastSubtitle: String?
    /// Im Liedtext-Modus traegt das obere Feld die Zeile allein und darf
    /// umbrechen; sonst stehen dort Titel und Interpret untereinander.
    private(set) var wrapsText = false

    /// Eine Liedtextzeile fuer sich, bei Bedarf ueber zwei Zeilen. Die
    /// abgeschwaechte naechste Zeile entfaellt dafuer – lange Zeilen wurden
    /// sonst abgeschnitten, und das Kommende ist weniger wert als das
    /// Laufende vollstaendig.
    func setLyricLine(_ text: String) {
        guard text != lastTitle || !wrapsText else { return }
        let newLine = wrapsText && lastTitle != nil
        lastTitle = text
        lastSubtitle = nil
        if !wrapsText {
            wrapsText = true
            artistLabel.isHidden = true
            titleLabel.cell?.usesSingleLineMode = false
            titleLabel.maximumNumberOfLines = 2
            // Umbrechen, und wenn zwei Zeilen nicht reichen, die letzte
            // sichtbar kuerzen statt den Rest stillschweigend wegzulassen.
            // Das macht die Zelle, nicht der Umbruchmodus: .byTruncatingTail
            // dort unterbindet den Umbruch ganz.
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.cell?.truncatesLastVisibleLine = true
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        titleLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: primaryColor,
            .shadow: shadow(radius: 3, opacity: 0.9),
            .paragraphStyle: paragraph,
        ])
        needsLayout = true
        onTextChange?()
        if newLine { animateLine(titleLabel, rise: 5, delay: 0) }
    }

    func setTexts(title: String, subtitle: String) {
        // Im Liedtext-Modus laeuft das zehnmal je Sekunde, die Zeile wechselt
        // aber nur alle paar Sekunden. Zwei Attributtexte samt Schatten neu zu
        // bauen und ins Glas zu zeichnen kostet dort mehr als der ganze Rest.
        guard title != lastTitle || subtitle != lastSubtitle else { return }
        // Im Liedtext-Modus wechselt die Zeile mitten im Lauf. Ohne Bewegung
        // ist der Wechsel kaum zu bemerken – der Text steht einfach ploetzlich
        // anders da. Nur bei neuer Zeile, nicht bei der Lautstaerkeanzeige.
        let newLine = showsLyrics && !wrapsText && lastTitle != nil && title != lastTitle
        lastTitle = title
        lastSubtitle = subtitle
        if wrapsText {
            wrapsText = false
            artistLabel.isHidden = false
            titleLabel.cell?.usesSingleLineMode = true
            titleLabel.maximumNumberOfLines = 1
            titleLabel.lineBreakMode = .byTruncatingTail
        }
        defer {
            onTextChange?()
            if newLine {
                animateLine(titleLabel, rise: 5, delay: 0)
                animateLine(artistLabel, rise: 3, delay: 0.04)
            }
        }
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: primaryColor,
            .shadow: shadow(radius: 3, opacity: 0.9),
        ])
        artistLabel.attributedStringValue = NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: secondaryColor,
            .shadow: shadow(radius: 2.5, opacity: 0.85),
        ])
    }

    /// Stellt das Glas ein. Die Werte stehen bei applyFill begruendet.
    @available(macOS 26.0, *)
    static func tune(_ glass: NSGlassEffectView) {
        let d = UserDefaults.standard
        // "clear" ist die durchlaessigste Stufe und die einzige, deren Mischung
        // ueber den ganzen Helligkeitsbereich gerade verlaeuft wie beim Dock.
        let style = d.object(forKey: "glassStyle") as? Int ?? 1
        if let s = NSGlassEffectView.Style(rawValue: style) { glass.style = s }
        for (key, name) in [("glassAdaptive", "_adaptiveAppearance"),
                            ("glassLensing", "_contentLensing")] {
            if let on = d.object(forKey: key) as? Bool {
                glass.setValue(on, forKey: name)
            }
        }
        // Die Mischung des Dock ist gerade: Helligkeit = 0,66 · Grund + 58.
        // Unter den Glasvarianten trifft nur Nummer 5 diese Geraden-Form ueber
        // den ganzen Bereich; die oeffentlichen Stufen knicken ueber halbheller
        // Flaeche weg. Fehlt der Schluessel auf einem kuenftigen System, bleibt
        // es bei der Voreinstellung – dann sitzt die Farbe nicht ganz.
        let variant = d.object(forKey: "glassVariant") as? Int ?? 5
        if glass.responds(to: Selector("set_variant:")) {
            glass.setValue(variant, forKey: "_variant")
        }
    }

    static func material(named name: String) -> NSVisualEffectView.Material {
        switch name {
        case "popover":              return .popover
        case "menu":                 return .menu
        case "sidebar":              return .sidebar
        case "toolTip":              return .toolTip
        case "titlebar":             return .titlebar
        case "headerView":           return .headerView
        case "windowBackground":     return .windowBackground
        case "underWindowBackground":return .underWindowBackground
        case "contentBackground":    return .contentBackground
        case "selection":            return .selection
        case "fullScreenUI":         return .fullScreenUI
        default:                     return .hudWindow
        }
    }

    /// Der Dock hat oben und unten eine helle Kante von je einem Punkt
    /// (gemessen 140 gegen 88 Flaeche, Hellmodus), an den Seiten nur eine
    /// Andeutung (+5). Keine gezeichnete Linie, sondern ein Verlauf – eine
    /// harte Kontur sieht im direkten Vergleich falsch aus.
    private func applyRim() {
        rim.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard bounds.width > 1 else { return }
        let strength = UserDefaults.standard.object(forKey: "rimAlpha") as? Double
            ?? (isDarkAppearance ? 0.27 : 0.334)

        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.cornerRadius = min(bounds.height * 0.38, 22)
        gradient.colors = [
            NSColor(calibratedWhite: 1, alpha: strength).cgColor,
            NSColor(calibratedWhite: 1, alpha: strength * 0.30).cgColor,
            NSColor(calibratedWhite: 1, alpha: strength * 0.10).cgColor,
            NSColor(calibratedWhite: 1, alpha: strength * 0.30).cgColor,
            NSColor(calibratedWhite: 1, alpha: strength).cgColor,
        ]
        gradient.locations = [0, 0.08, 0.5, 0.92, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        // Nur der Rand leuchtet, nicht die Flaeche
        let mask = CAShapeLayer()
        let radius = min(bounds.height * 0.38, 22)
        mask.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: radius, cornerHeight: radius, transform: nil)
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = 1.0
        gradient.mask = mask
        rim.layer?.addSublayer(gradient)
    }

    /// Der Dock mischt streng linear, in beiden Darstellungen und ueber den
    /// ganzen Bereich (Pruefflaechen Schwarz bis Weiss, Abweichung 0):
    ///   hell   Helligkeit = 0,660 · Grund + 58
    ///   dunkel Helligkeit = 0,720 · Grund + 17
    /// Liquid Glass tut das nicht: die oeffentlichen Stufen hellen sich ueber
    /// halbheller Flaeche selbsttaetig auf und kippen ueber sehr heller sogar
    /// ins Dunkle. Nur die Glasvariante 5 verlaeuft ebenso gerade
    /// (hell 0,634 · G + 85, dunkel 0,677 · G + 37).
    /// Der Rest ist ein fester Abzug per "plusD": 24 Stufen im Hellmodus,
    /// 14,5 im Dunkelmodus. Ein Abzug aendert nur den Sockel, nicht die
    /// Steigung – eine normale Deckschicht wuerde beides zugleich verschieben.
    /// Bleibt die Steigungsdifferenz von 0,026 bzw. 0,043; der Abzug ist so
    /// gewaehlt, dass sie sich auf beide Enden verteilt. Groesste Abweichung
    /// gemessen: 4 von 255 im Hellmodus, 6 im Dunkelmodus.
    private func applyFill() {
        let dark = isDarkAppearance
        if #available(macOS 26.0, *), let glass = glassEffect as? NSGlassEffectView {
            glass.tintColor = nil
        }
        let d = UserDefaults.standard
        let opacity = d.object(forKey: dark ? "fillDark" : "fillLight") as? Double ?? 0
        let shadeWhite = d.object(forKey: dark ? "shadeDark" : "shadeLight") as? Double ?? 1.0
        // Abzug per "plusD": 255 minus Wert wird von der Flaeche abgezogen.
        // Hell 24 Stufen (Glas 0,634·G+85 gegen Dock 0,660·G+58),
        // dunkel 14,5 Stufen (Glas 0,677·G+37 gegen Dock 0,720·G+17).
        let liftGray = d.object(forKey: dark ? "liftDark" : "liftLight") as? Double
            ?? (dark ? 0.9431 : 0.9059)
        shade.layer?.backgroundColor = NSColor(calibratedWhite: shadeWhite, alpha: opacity).cgColor
        boost.layer?.compositingFilter = d.string(forKey: "boostFilter") ?? "plusD"
        boost.layer?.backgroundColor = NSColor(calibratedWhite: liftGray, alpha: 1).cgColor
    }

    func applyColors() {
        applyFill()
        applyRim()
        for button in [previousButton, playButton, nextButton, addButton] {
            button.contentTintColor = primaryColor
            button.wantsLayer = true
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = 0.55
            button.layer?.shadowRadius = 2.5
            button.layer?.shadowOffset = .zero
        }
        cover.layer?.backgroundColor = primaryColor.withAlphaComponent(0.12).cgColor
        progressBar.tone = primaryColor
        spectrum.tone = primaryColor
        timeLabel.textColor = secondaryColor
        totalLabel.textColor = secondaryColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Zeigen

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area

        // Wird die Zone neu aufgebaut – etwa weil sich die Panelbreite geaendert
        // hat – meldet macOS kein erneutes Eintreten. Ohne diese Pruefung faellt
        // der Zeige-Zustand still aus, obwohl der Zeiger noch darauf steht.
        if let window, window.isVisible {
            let inWindow = window.mouseLocationOutsideOfEventStream
            setHovering(bounds.contains(convert(inWindow, from: nil)))
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    /// Blendet die Leiste unabhaengig vom Zeigen ein – fuer die Lautstaerke.
    func forceProgressVisible(_ visible: Bool) {
        progressBar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            let target: CGFloat = visible ? 1 : (isHovering ? 1 : 0)
            progressBar.animator().alphaValue = target
            timeLabel.animator().alphaValue = target
            totalLabel.animator().alphaValue = target
        }
    }

    private func setHovering(_ value: Bool) {
        guard value != isHovering else { return }
        isHovering = value
        startHoverAnimation()
        onHoverChange?(value)
    }

    /// Faehrt `hoverProgress` weich zwischen 0 und 1; das Layout haengt daran.
    private func startHoverAnimation() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let target: CGFloat = self.isHovering ? 1 : 0
            self.hoverProgress += (target - self.hoverProgress) * 0.25
            if abs(target - self.hoverProgress) < 0.005 {
                self.hoverProgress = target
                timer.invalidate()
                self.hoverTimer = nil
            }
            // Ab der grossen Breite stehen Leiste und Zeiten dauerhaft da –
            // dann ist Platz dafuer, und sie sind der Hauptgewinn der Breite.
            let shown = self.effectiveHover
            self.progressBar.alphaValue = shown
            self.timeLabel.alphaValue = shown
            self.totalLabel.alphaValue = shown
            // Unsichtbar darf sie keine Klicks abfangen.
            self.progressBar.isHidden = shown < 0.03
            self.needsLayout = true
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    // MARK: Anordnung

    /// Breite, die der Inhalt tatsaechlich braucht. Ohne das entsteht zwischen
    /// Titel und Tonanzeige eine Luecke, die je nach Titellaenge anders ausfaellt –
    /// die Abstaende waeren dann nicht gesetzt, sondern zufaellig.
    func preferredWidth(height: CGFloat) -> CGFloat {
        let pad: CGFloat = 8
        let gap: CGFloat = 10
        let coverSize = showsLyrics ? 0 : height - pad * 2 - 2
        let titleWidth = titleLabel.attributedStringValue.size().width
        let artistWidth = artistLabel.attributedStringValue.size().width
        let textWidth = min(max(ceil(max(titleWidth, artistWidth)) + 3, 90), showsLyrics ? 330 : 190)
        let buttons = 4 * min(26, height - pad * 2) + 3 * 4
        var total = pad + coverSize + (showsLyrics ? 0 : gap) + textWidth + gap + buttons + pad
        if spectrumVisible { total += 30 + gap }
        return ceil(total)
    }

    override func layout() {
        super.layout()

        // Ein Raster fuer alles: Aussenabstand und Elementabstand.
        let pad: CGFloat = 8
        let gap: CGFloat = 10
        let radius = min(bounds.height * 0.38, 22)
        // Einmal auf ganze Punkte gerundet: sonst gleitet das Cover, waehrend
        // die Knoepfe (deren Rahmen gerundet werden) einen Tick spaeter springen.
        let lift = round(4 * effectiveHover)

        glassView.frame = bounds
        content.frame = bounds
        rim.frame = bounds
        rim.layer?.cornerRadius = radius
        applyRim()
        shade.frame = bounds
        shade.layer?.cornerRadius = radius
        shade.layer?.masksToBounds = true
        // Die Deckkraft haengt sonst nur am Hover-Takt, der bei grosser Breite
        // nie laeuft – dann blieben Leiste und Zeiten unsichtbar.
        let shown = effectiveHover
        if progressBar.alphaValue != shown {
            progressBar.alphaValue = shown
            timeLabel.alphaValue = shown
            totalLabel.alphaValue = shown
            progressBar.isHidden = shown < 0.03
        }

        boost.frame = bounds
        boost.layer?.cornerRadius = radius
        boost.layer?.masksToBounds = true
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glassView.layer?.cornerRadius = radius
        }

        // Cover links
        let coverSize = bounds.height - pad * 2 - 2
        cover.frame = CGRect(x: pad, y: round(pad + 1) + lift, width: coverSize, height: coverSize)

        // Knoepfe von rechts. Die Symbole sind unterschiedlich breit (gemessen
        // 25, 12, 24 und 18 px); in gleich breiten Rahmen wirken die Abstaende
        // dadurch ungleich. Deshalb folgt jeder Rahmen seinem Symbol.
        let buttonHeight = min(26, bounds.height - pad * 2)
        let symbolGap: CGFloat = 12
        var x = bounds.width - pad
        // x wandert von rechts nach links und markiert immer die Kante der
        // gezeichneten Flaeche – die Raender des Symbols werden herausgerechnet.
        let keys = ["plus", "next", "play", "previous"]
        previousButton.isHidden = !showsSkipButtons
        nextButton.isHidden = !showsSkipButtons
        for (index, button) in [addButton, nextButton, playButton, previousButton].enumerated() {
            if button.isHidden { continue }
            let key = keys[index] + (button === playButton ? (button.image?.accessibilityDescription ?? "") : "")
            let ink = Self.ink(of: button.image, key: key)
            // Rest-Versatz aus der Nachmessung am gezeichneten Bild. Play und
            // Pause sind unterschiedlich geformt und brauchen eigene Werte.
            let isPause = (button.image?.accessibilityDescription ?? "").hasPrefix("Paus")
            let nudge: CGFloat
            if button === playButton { nudge = isPause ? 0 : 1 }
            else if button === previousButton { nudge = -1 }
            else { nudge = 0 }
            let frameWidth = ink.left + ink.width + ink.right
            // rechte Tintenkante soll bei x liegen
            // Auf ganze Punkte runden: Bruchteile fuehren beim Zeichnen zu
            // unterschiedlicher Rundung und damit zu ungleichen Abstaenden.
            let frameRight = round(x + ink.right + nudge)
            let frameX = round(frameRight - frameWidth)
            button.frame = CGRect(x: frameX, y: round((bounds.height - buttonHeight) / 2) + lift,
                                  width: round(frameWidth), height: buttonHeight)
            x = frameX + ink.left - symbolGap
        }
        // 2 Punkte Zugabe: nachgemessen liegt die Tonanzeige sonst zu dicht am Knopf.
        var rightEdge = x + symbolGap - gap - 2

        // Tonanzeige davor
        spectrum.isHidden = !spectrumVisible
        if spectrumVisible {
            let spectrumWidth: CGFloat = 30
            let spectrumHeight: CGFloat = 20
            spectrum.frame = CGRect(x: rightEdge - spectrumWidth,
                                    y: round((bounds.height - spectrumHeight) / 2) + lift,
                                    width: spectrumWidth, height: spectrumHeight)
            rightEdge -= spectrumWidth + gap
        }

        // Titel und Unterzeile
        let textLeft = showsLyrics ? pad : cover.frame.maxX + gap
        let textWidth = max(20, rightEdge - textLeft)
        let lineHeight: CGFloat = 14
        let top = (bounds.height - lineHeight * 2) / 2
        artistLabel.isHidden = wrapsText || !showsArtistLine
        if !wrapsText && !showsArtistLine {
            // Nur der Titel: dann steht er mittig, nicht auf der oberen der
            // beiden Zeilen.
            titleLabel.frame = CGRect(x: textLeft, y: round((bounds.height - lineHeight) / 2) + lift,
                                      width: textWidth, height: lineHeight)
        } else if wrapsText {
            // Eine Zeile sitzt mittig, zwei belegen dasselbe Band wie sonst
            // Titel und Interpret – so stoesst der Text nicht an die Zeitleiste.
            let needed = titleLabel.attributedStringValue.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            let twoLines = needed > lineHeight + 1
            let height = twoLines ? lineHeight * 2 : lineHeight
            // Eine Zeile steht schlicht mittig. Zwei brauchen einen Punkt
            // Versatz nach unten: die Zelle setzt den Text oben an, unten
            // bleibt der Platz fuer Unterlaengen ungenutzt. Gemessen liegt der
            // Block damit auf derselben Mitte wie Titel und Interpret im
            // Normalmodus (beide y=35,0), die Grundlinie einer einzelnen Zeile
            // auf der Mitte von deren beiden Grundlinien (y=38).
            let correction: CGFloat = twoLines ? -1 : 0
            titleLabel.frame = CGRect(x: textLeft,
                                      y: round((bounds.height - height) / 2 + correction) + lift,
                                      width: textWidth, height: height)
        } else {
            titleLabel.frame = CGRect(x: textLeft, y: round(top + lineHeight - 1) + lift, width: textWidth, height: lineHeight)
            artistLabel.frame = CGRect(x: textLeft, y: round(top) + lift, width: textWidth, height: lineHeight)
        }

        // Zeitleiste: links die laufende, rechts die gesamte Zeit – beide mit
        // fester Breite, damit die Leiste beim Ticken nicht wandert.
        let barHeight = pad + 8
        // Die Schrift sitzt in ihrem Feld etwas ueber der Unterkante; dieser
        // Versatz bringt ihre Grundlinie auf die Hoehe des Strichs.
        let labelHeight: CGFloat = 11
        let labelY = (barHeight - labelHeight) / 2 - 1

        // Beide Zeiten bekommen dieselbe Breite – die des breiteren Textes.
        // Eine feste Mindestbreite wuerde dort Luft lassen, wo der Text schmaler
        // ist, und die Leiste damit sichtbar aus der Mitte ruecken.
        // Ein Punkt Zugabe: die gemessene Breite schneidet sonst das letzte
        // Zeichen an.
        let measured = max(ceil(timeLabel.attributedStringValue.size().width),
                           ceil(totalLabel.attributedStringValue.size().width)) + 2
        let leftWidth = measured
        let rightWidth = measured
        // Abstand Zeit zur Leiste und Abstand der rechten Zeit zum Panelrand.
        // Beide Werte sind gemessen, nicht geschaetzt – siehe README.
        let timeGap: CGFloat = 7
        let edgeGap: CGFloat = 13
        timeLabel.frame = CGRect(x: textLeft, y: labelY, width: leftWidth, height: labelHeight)
        totalLabel.frame = CGRect(x: bounds.width - edgeGap - rightWidth, y: labelY,
                                  width: rightWidth, height: labelHeight)

        // Ziffern tragen unterschiedlich viel Tinte an ihren Raendern: gleiche
        // gesetzte Abstaende wirken deshalb um einen Punkt ungleich. Nachgemessen
        // und hier ausgeglichen.
        let barLeft = timeLabel.frame.maxX + timeGap
        let barRight = totalLabel.frame.minX - (timeGap - 1)
        progressBar.frame = CGRect(x: barLeft, y: 0, width: max(10, barRight - barLeft), height: barHeight)
    }
}

/// Reine Zierde – darf keine Mausereignisse abfangen.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PlayerPanel: NSPanel {
    /// Muss true sein, damit der Fenster-Server die Kanten uebernimmt. Mit
    /// .nonactivatingPanel wird davon die Anwendung nicht aktiv.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// macOS haelt Fenster mit Titelrahmen selbsttaetig aus dem Dock-Bereich
    /// heraus – gemessen 50 Punkte nach oben geschoben. Genau dort soll das
    /// Panel aber sitzen. Der Rahmen ist nur da, damit der Fenster-Server die
    /// Kanten uebernimmt; seine Platzierung bestimmt weiter der Dock.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - App

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private static var retained: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var panel: PlayerPanel!
    private var view: PlayerView!
    private var followTimer: Timer?
    private var progressTimer: Timer?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    /// Breite waehrend des Ziehens; erst beim Loslassen gesichert.
    private var pendingWidth: CGFloat?
    private var liveResizing = false
    private var motionTimer: Timer?
    private var spectrumTimer: Timer?
    private let analyzer = AudioSpectrum()
    private var track = Track()
    private var artworkCache: [String: NSImage] = [:]
    private var permissionNoticeShown = false

    /// Wohin das Panel unterwegs ist – die Bewegung dorthin läuft weich.
    private var lastDockFrame: CGRect = .null
    private var idleTicks = 0
    private var scrubbing = false
    private var positionAnchor: (value: TimeInterval, at: Date)?

    /// Liedzeilen brauchen deutlich mehr Platz als ein Songtitel.
    private var panelWidth: CGFloat {
        guard let view else { return 372 }
        // Fest, nicht nach Inhalt: eine mitwandernde Breite waere bei jedem
        // Titel eine andere, und das Panel spraenge staendig hin und her.
        // Eingestellt wird sie an der Kante, gezogen wie bei einem Fenster.
        if let pendingWidth { return pendingWidth }
        let stored = UserDefaults.standard.object(forKey: widthKey) as? Double
            ?? (lyricsMode ? 520 : 420)
        return clampWidth(CGFloat(stored))
    }

    /// Getrennte Breiten: der Liedtext-Modus braucht mehr Platz als Cover,
    /// Titel und Knoepfe, und beides einzeln zu merken erspart das Nachziehen
    /// bei jedem Umschalten.
    private var widthKey: String { lyricsMode ? "lyricsWidth" : "panelWidth" }

    /// Unter 200 Punkten bleibt vom Panel nichts Sinnvolles uebrig: Cover,
    /// eine lesbare Titelzeile und ein Knopf brauchen zusammen so viel.
    static let minWidth: CGFloat = 200

    private func clampWidth(_ width: CGFloat) -> CGFloat {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(lastDockFrame) })
            ?? NSScreen.main
        let room = max(Self.minWidth, (screen?.frame.width ?? 1440) - lastDockFrame.width - 4 * gap)
        return min(max(width, Self.minWidth), room)
    }
    private var spectrumEnabled: Bool { UserDefaults.standard.bool(forKey: "showSpectrum") }
    private let gap: CGFloat = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showSpectrum": true])
        buildPanel()
        // Bildsynchron: nur so sitzt das Panel auch waehrend der Dock-Vergroesserung
        // exakt am Rand, statt sichtbar hinterherzulaufen. Eine Abfrage kostet 0,06 ms.
        // Abtastrate einstellbar: defaults write de.jancko.docktunes followRate -int 30
        let rate = max(4.0, min(120.0, UserDefaults.standard.object(forKey: "followRate") as? Double ?? 60))
        followTimer = schedule(every: 1.0 / rate) { [weak self] in self?.followDock() }
        progressTimer = schedule(every: 0.1) { [weak self] in self?.updateProgress() }
        // Spotify meldet Wechsel von sich aus; dieser Takt ist nur die Rückfallebene
        // und die Nachführung der Wiedergabeposition. Ein Abruf kostet 55 ms.
        syncPollRate()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshTrack() }

        checkPermission()
        refreshTrack()
        followDock()
        writeDiagnostics()
    }

    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Aufbau

    private func buildPanel() {
        panel = PlayerPanel(contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: 50),
                            // Ein echter Fensterrahmen, nur unsichtbar gemacht:
                            // damit uebernimmt der Fenster-Server die Kanten,
                            // zeigt dort den Groessenzeiger und zieht selbst.
                            // Rahmenlos ginge das nicht – ohne Rahmen gibt es
                            // keine Kante, an der er greifen koennte, und den
                            // Zeiger setzen kann nur die aktive Anwendung.
                            styleMask: [.titled, .fullSizeContentView,
                                        .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Der Dock wirft keinen Schatten: der Grund neben ihm misst 45,0 –
        // genau den Wert des Hintergrunds. Mit Schatten sass das Panel sichtbar
        // "auf" dem Bild statt darin (gemessen 31 ueber, 28 unter der Kante).
        panel.hasShadow = false
        panel.delegate = self
        // Vom Rahmen bleibt nichts zu sehen: kein Titel, keine Knoepfe, keine
        // Leiste – nur seine Kanten, an denen sich ziehen laesst.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.remove(.closable)
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.appearance = nil           // folgt der Systemdarstellung, hell wie dunkel

        view = PlayerView(frame: panel.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        view.previousButton.target = self
        view.previousButton.action = #selector(previousTrack)
        view.playButton.target = self
        view.playButton.action = #selector(playPause)
        view.nextButton.target = self
        view.nextButton.action = #selector(nextTrack)
        view.addButton.target = self
        view.addButton.action = #selector(addToPlaylist)
        view.onClick = { [weak self] in self?.openSpotify() }
        view.onTextChange = { [weak self] in
            guard let self else { return }
            // Breite haengt am Text – Position neu bestimmen lassen
            self.lastDockFrame = .null
        }
        view.onScroll = { [weak self] direction in
            guard let self else { return }
            // Schrittweite je Raste; per "volumeStep" anpassbar.
            let step = UserDefaults.standard.object(forKey: "volumeStep") as? Int ?? 5
            if UserDefaults.standard.bool(forKey: "systemVolume") {
                Spotify.changeSystemVolume(by: direction * step)
                self.showVolume(nil)
                return
            }
            // Wert lokal fortschreiben und sofort anzeigen. Auf Spotifys Antwort
            // zu warten laesst die Leiste zappeln, weil die Rueckmeldungen
            // verzoegert und in beliebiger Reihenfolge eintreffen.
            // Auf das Raster einrasten: so stehen dort immer glatte Werte,
            // auch wenn Spotify bei 73 stand.
            let base = self.knownVolume ?? 50
            let raw = direction > 0
                ? Int((Double(base + 1) / Double(step)).rounded(.up)) * step
                : Int((Double(base - 1) / Double(step)).rounded(.down)) * step
            let next = max(0, min(100, raw))
            self.knownVolume = next
            self.showVolume(next)
            Spotify.setVolume(next)
        }
        view.menu = buildContextMenu()

        view.progressBar.onScrub = { [weak self] fraction in
            guard let self else { return }
            self.scrubbing = true
            // Die Zeit links an der Leiste zeigt beim Ziehen das Ziel. Sie steht
            // ohnehin da; sie zweitens in die Interpretenzeile zu schreiben,
            // sagt dasselbe zweimal und wirft den Text beim Ziehen um.
            guard self.track.duration > 0 else { return }
            self.view.setTimes(running: Self.clock(fraction * self.track.duration),
                               total: self.view.totalLabel.stringValue)
        }
        view.progressBar.onSeek = { [weak self] fraction in
            guard let self, self.track.duration > 0 else { return }
            let target = fraction * self.track.duration
            Spotify.seek(to: target)
            self.positionAnchor = (target, Date())
            self.scrubbing = false
            self.updateText()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refreshTrack() }
        }
        view.onHoverChange = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.refreshTrack()
                Spotify.readVolume { level in
                    guard let level else { return }
                    // Spotify rastet die Lautstaerke intern auf 1/64 – wer 70
                    // setzt, liest 69 zurueck. Diesen Rueckfall zu uebernehmen
                    // wuerde das Fuenferraster nach jedem Hovern zerstoeren.
                    // Nur uebernehmen, wenn jemand anders sie verstellt hat.
                    if let known = self.knownVolume, abs(level - known) <= 2 { return }
                    self.knownVolume = level
                }
            }
        }
        view.showsSpectrum = spectrumEnabled
        view.showsLyrics = lyricsMode
        view.spectrum.bands = Array(repeating: 0, count: AudioSpectrum.bandCount)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Spotify öffnen", action: #selector(openSpotify), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        if SpotifyWeb.isLinked {
            let choose = NSMenuItem(title: "Zu Playlist hinzufügen …", action: #selector(choosePlaylist), keyEquivalent: "")
            choose.target = self
            choose.isEnabled = !track.uri.isEmpty
            menu.addItem(choose)
            if let current = SpotifyWeb.defaultPlaylist {
                menu.addItem(disabledItem("Standard: " + current.name))
            }
            let unlink = NSMenuItem(title: "Spotify-Verbindung trennen", action: #selector(unlinkSpotify), keyEquivalent: "")
            unlink.target = self
            menu.addItem(unlink)
        } else {
            let link = NSMenuItem(title: "Mit Spotify verbinden …", action: #selector(setUpSpotifyLink), keyEquivalent: "")
            link.target = self
            menu.addItem(link)
        }
        menu.addItem(.separator())
        // Ein einzelner Schalter "regelt Systemlautstärke" ist zweideutig: man
        // schaltet ihn ein und bekommt das Gegenteil des Erwarteten. Zwei
        // benannte Optionen sind eindeutig.
        let usesSystem = UserDefaults.standard.bool(forKey: "systemVolume")
        let volumeMenu = NSMenu()
        for (title, wantsSystem) in [("Spotify", false), ("System", true)] {
            let item = NSMenuItem(title: title, action: #selector(setVolumeSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = wantsSystem
            item.state = (usesSystem == wantsSystem) ? .on : .off
            volumeMenu.addItem(item)
        }
        let volumeItem = NSMenuItem(title: "Scrollen regelt Lautstärke von", action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)
        let lyricsItem = NSMenuItem(title: "Liedtext mitlaufen lassen", action: #selector(toggleLyrics), keyEquivalent: "")
        lyricsItem.target = self
        lyricsItem.state = lyricsMode ? .on : .off
        menu.addItem(lyricsItem)
        if lyricsMode {
            // Nur im Liedtext-Modus sichtbar: sonst richtet sich die Breite
            // nach dem Inhalt und waere gar nicht einstellbar.
            let current = UserDefaults.standard.object(forKey: "lyricsWidth") as? Double ?? 520
            let widthMenu = NSMenu()
            for (title, value) in [("Schmal", 420.0), ("Normal", 520.0),
                                   ("Breit", 640.0), ("Sehr breit", 760.0)] {
                let item = NSMenuItem(title: title, action: #selector(setLyricsWidth(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value
                item.state = abs(current - value) < 1 ? .on : .off
                widthMenu.addItem(item)
            }
            let widthItem = NSMenuItem(title: "Breite des Liedtexts", action: nil, keyEquivalent: "")
            widthItem.submenu = widthMenu
            menu.addItem(widthItem)
        }
        let spectrumItem = NSMenuItem(title: "Tonanalyse anzeigen", action: #selector(toggleSpectrum), keyEquivalent: "")
        spectrumItem.target = self
        spectrumItem.state = spectrumEnabled ? .on : .off
        menu.addItem(spectrumItem)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Bei der Anmeldung starten", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "DockTunes beenden", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Anmeldeobjekt konnte nicht geändert werden"
            alert.informativeText = error.localizedDescription
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        view.menu = buildContextMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        analyzer.stop()
    }

    // MARK: Steuerung

    @objc private func playPause() {
        let wantsPlay = !track.isPlaying
        Spotify.send("playpause")
        if wantsPlay {
            // Hat Spotify keinen Titel geladen, verpufft "playpause" wirkungslos.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                Spotify.load { fresh in
                    guard let self, self.track.isPlaying, !fresh.isPlaying else { return }
                    Spotify.send("play")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshTrack() }
                }
            }
        }
        track.isPlaying.toggle()
        if track.isPlaying { positionAnchor = (displayPosition, Date()) }
        else { positionAnchor = (displayPosition, Date()) }
        applyTrack(track, reloadArtwork: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refreshTrack() }
    }

    @objc private func nextTrack() {
        Spotify.send("next track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refreshTrack() }
    }

    @objc private func previousTrack() {
        Spotify.send("previous track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refreshTrack() }
    }

    @objc private func openSpotify() { Spotify.activate() }

    // MARK: Playlists

    @objc private func addToPlaylist() {
        if let picker, picker.isVisible {
            picker.close()
            self.picker = nil
            return
        }
        guard !track.uri.isEmpty else { return }
        guard SpotifyWeb.isLinked else { setUpSpotifyLink(); return }
        guard let playlist = SpotifyWeb.defaultPlaylist else { choosePlaylist(); return }
        addTrack(to: playlist, remember: false)
    }

    /// Kurze Rückmeldung am Knopf, damit der Klick sichtbar wirkt.
    private func flashAddButton(symbol: String) {
        view.addButton.image = PlayerView.symbol(symbol, "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.view.addButton.image = PlayerView.symbol("plus.circle", "Zur Playlist hinzufügen")
        }
    }

    @objc private func choosePlaylist() {
        if let picker, picker.isVisible {
            picker.close()
            self.picker = nil
            return
        }
        // Der Klick auf den Knopf nimmt dem Fenster zuvor den Fokus, wodurch es
        // sich selbst schliesst. Ohne diese Sperre ginge es sofort wieder auf.
        if Date().timeIntervalSince(pickerClosedAt) < 0.4 { return }
        guard SpotifyWeb.isLinked else { setUpSpotifyLink(); return }
        SpotifyWeb.loadPlaylists { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showError("Playlists konnten nicht geladen werden", error.localizedDescription)
            case .success(let playlists):
                guard !playlists.isEmpty else {
                    self.showError("Keine Playlists gefunden", "Dein Konto hat keine bearbeitbaren Playlists.")
                    return
                }
                let picker = PlaylistPicker(playlists: playlists) { [weak self] chosen in
                    self?.addTrack(to: chosen, remember: true)
                }
                picker.onClose = { [weak self] in
                    self?.pickerClosedAt = Date()
                    self?.picker = nil
                }
                self.picker = picker
                // Ueber dem Plus-Knopf aufklappen
                let button = self.view.addButton.frame
                let anchor = self.panel.frame.origin
                picker.show(near: NSPoint(x: anchor.x + button.midX, y: anchor.y + self.panel.frame.height + 8))
            }
        }
    }

    private func addTrack(to playlist: SpotifyWeb.Playlist, remember: Bool) {
        if remember { SpotifyWeb.defaultPlaylist = playlist }
        guard !track.uri.isEmpty else { return }
        SpotifyWeb.add(trackURI: track.uri, to: playlist) { [weak self] result in
            switch result {
            case .success: self?.flashAddButton(symbol: "checkmark.circle.fill")
            case .failure(let error):
                self?.flashAddButton(symbol: "exclamationmark.circle.fill")
                self?.showError("Titel konnte nicht hinzugefügt werden", error.localizedDescription)
            }
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func setUpSpotifyLink() {
        if SpotifyWeb.clientID == nil {
            let alert = NSAlert()
            alert.messageText = "Einmalige Einrichtung"
            alert.informativeText = "Zum Einsortieren in Playlists braucht DockTunes eine eigene Client-ID.\n\n"
                + "1. developer.spotify.com/dashboard öffnen und eine App anlegen\n"
                + "2. Als Redirect URI eintragen: " + SpotifyWeb.redirectURI + "\n"
                + "3. Client-ID kopieren und hier einsetzen"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Client-ID"
            alert.accessoryView = field
            alert.addButton(withTitle: "Weiter")
            alert.addButton(withTitle: "Dashboard öffnen")
            alert.addButton(withTitle: "Abbrechen")
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            if answer == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                return
            }
            guard answer == .alertFirstButtonReturn else { return }
            let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entered.isEmpty else { return }
            SpotifyWeb.clientID = entered
        }
        SpotifyWeb.authorize { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.view.menu = self.buildContextMenu()
                self.choosePlaylist()
            case .failure(let error):
                self.showError("Verbindung fehlgeschlagen", error.localizedDescription)
            }
        }
    }

    @objc private func unlinkSpotify() {
        SpotifyWeb.unlink()
        view.menu = buildContextMenu()
    }

    private func showError(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Titelanzeige

    private var displayPosition: TimeInterval {
        guard let anchor = positionAnchor else { return track.position }
        guard track.isPlaying else { return anchor.value }
        return min(track.duration, anchor.value + Date().timeIntervalSince(anchor.at))
    }

    private var deniedNoticeShown = false
    private var picker: PlaylistPicker?
    private var pickerClosedAt = Date.distantPast
    private var lyricLines: [Lyrics.Line] = []
    private var lyricsTrackURI = ""
    private var lyricsMode: Bool { UserDefaults.standard.bool(forKey: "lyricsMode") }

    /// Ein Abruf ueber AppleScript kostet 55 ms. Waehrend der Wiedergabe ist er
    /// alle fuenf Sekunden noetig, um die Position nachzuziehen. Bei Pause
    /// bewegt sich nichts, und einen echten Wechsel meldet Spotify von selbst –
    /// da genuegt ein Blick alle 20 Sekunden als Rueckfallebene.
    private func syncPollRate() {
        let interval: TimeInterval = track.isPlaying ? 5 : 20
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = schedule(every: interval) { [weak self] in self?.refreshTrack() }
    }

    private func refreshTrack() {
        Spotify.load { [weak self] new in
            guard let self else { return }
            if Spotify.permissionDenied && !self.deniedNoticeShown {
                self.deniedNoticeShown = true
                self.showAutomationHint()
            }
            let artworkChanged = new.artworkURL != self.track.artworkURL
            let wasSame = new.title == self.track.title && new.isPlaying == self.track.isPlaying
                && new.spotifyRunning == self.track.spotifyRunning
            let playChanged = new.isPlaying != self.track.isPlaying
            self.track = new
            self.positionAnchor = (new.position, Date())
            if !wasSame || artworkChanged { self.applyTrack(new, reloadArtwork: artworkChanged) }
            if playChanged { self.syncPollRate() }
            self.updateProgress()
        }
    }

    private func applyTrack(_ track: Track, reloadArtwork: Bool) {
        if track.uri != lyricsTrackURI {
            lyricsTrackURI = track.uri
            lyricLines = []
            if lyricsMode { loadLyrics(for: track) }
        }
        updateText()
        view.playButton.image = PlayerView.symbol(track.isPlaying ? "pause.fill" : "play.fill",
                                                  track.isPlaying ? "Pausieren" : "Abspielen")
        if reloadArtwork && !lyricsMode { loadArtwork(track.artworkURL) }
        updateAnalyzer()
        followDock()
    }

    /// Mitschnitt nur, solange wirklich etwas läuft – sonst kostet er unnötig Rechenzeit.
    private func updateAnalyzer() {
        guard spectrumEnabled, track.isPlaying, track.spotifyRunning,
              let spotify = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" })
        else {
            if analyzer.isRunning { analyzer.stop() }
            stopSpectrumUpdates()
            // Bleibt sichtbar, faellt aber auf null zurueck – ruhiger als ein Verschwinden.
            view.spectrum.bands = Array(repeating: 0, count: AudioSpectrum.bandCount)
            return
        }
        if !analyzer.isRunning {
            guard analyzer.start(pid: spotify.processIdentifier) else { return }
        }
        startSpectrumUpdates()
    }

    private func startSpectrumUpdates() {
        guard spectrumTimer == nil else { return }
        let rate = max(5.0, min(60.0, UserDefaults.standard.object(forKey: "spectrumRate") as? Double ?? 30))
        let timer = Timer(timeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible, self.view.showsSpectrum else { return }
            self.view.spectrum.bands = self.analyzer.currentBands()
        }
        RunLoop.main.add(timer, forMode: .common)
        spectrumTimer = timer
    }

    private func stopSpectrumUpdates() {
        spectrumTimer?.invalidate()
        spectrumTimer = nil
    }

    @objc private func toggleSpectrum() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "showSpectrum"), forKey: "showSpectrum")
        view.showsSpectrum = spectrumEnabled
        view.menu = buildContextMenu()
        updateAnalyzer()
        followDock()
    }

    private func loadLyrics(for track: Track) {
        Lyrics.lines(for: track) { [weak self] lines in
            guard let self, track.uri == self.lyricsTrackURI else { return }
            self.lyricLines = lines
            self.updateText()
        }
    }

    /// Zeigt entweder Titel und Interpret oder die mitlaufende Textzeile.
    private func updateText() {
        guard lyricsMode else {
            // Das Album kommt erst bei grosser Breite dazu; darunter waere die
            // Zeile nur abgeschnitten.
            let showsAlbum = view.showsExtras && !track.album.isEmpty
                && track.album != track.title
            view.setTexts(title: track.title,
                          subtitle: showsAlbum ? "\(track.artist) · \(track.album)" : track.artist)
            return
        }
        guard !lyricLines.isEmpty else {
            view.setTexts(title: track.title,
                          subtitle: lyricsTrackURI.isEmpty ? "" : "kein Liedtext gefunden")
            return
        }
        let (current, next) = Lyrics.at(displayPosition, in: lyricLines)
        // Vor der ersten Zeile und in Instrumentalpausen steht nichts an –
        // dann lieber Titel und Interpret als eine leere Flaeche.
        if current.isEmpty {
            view.setTexts(title: track.title, subtitle: track.artist)
        } else if view.showsLyricPreview && !next.isEmpty {
            // Genug Platz: die naechste Zeile darunter, wie frueher – hier
            // nimmt sie der laufenden nichts weg.
            view.setTexts(title: current, subtitle: next)
        } else {
            view.setLyricLine(current)
        }
    }

    /// Aus: Spotifys eigener Regler (Vorgabe). An: die des Systems.
    @objc private func setVolumeSource(_ sender: NSMenuItem) {
        guard let wantsSystem = sender.representedObject as? Bool else { return }
        UserDefaults.standard.set(wantsSystem, forKey: "systemVolume")
        view.menu = buildContextMenu()
    }

    @objc private func setLyricsWidth(_ sender: NSMenuItem) {
        guard let width = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(width, forKey: "lyricsWidth")
        lastDockFrame = .null          // Breite geaendert, Position neu setzen
        followDock()
        view.menu = buildContextMenu()
    }

    @objc private func toggleLyrics() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "lyricsMode"), forKey: "lyricsMode")
        view.showsLyrics = lyricsMode
        view.menu = buildContextMenu()
        lastDockFrame = .null          // Breite hat sich geändert, Position neu setzen
        if lyricsMode {
            if lyricLines.isEmpty { loadLyrics(for: track) }
        } else {
            loadArtwork(track.artworkURL)
        }
        updateText()
    }

    private var volumeResetTimer: Timer?
    private var knownVolume: Int?

    /// Waehrend des Scrollens wird die Zeitleiste kurz zur Lautstaerkeanzeige.
    private func showVolume(_ level: Int?) {
        if let level {
            view.progressBar.progress = Double(level) / 100
            view.setTexts(title: view.titleLabel.stringValue, subtitle: "Lautstärke \(level) %")
            // Spielzeiten passen hier nicht dazu
            view.timeLabel.stringValue = ""
            view.totalLabel.stringValue = ""
        }
        view.progressBar.showsVolume = true
        view.forceProgressVisible(true)
        volumeResetTimer?.invalidate()
        let timer = Timer(timeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.view.progressBar.showsVolume = false
            self.view.forceProgressVisible(false)
            self.updateText()
            self.updateProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeResetTimer = timer
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func updateProgress() {
        if lyricsMode, !lyricLines.isEmpty, track.isPlaying { updateText() }
        // Waehrend die Lautstaerke angezeigt wird, darf die Position die Leiste
        // nicht ueberschreiben – sonst springt sie im Takt hin und her.
        guard !scrubbing, !view.progressBar.showsVolume, track.duration > 0 else { return }
        // Leiste und Zeiten sind nur beim Hovern zu sehen – ausser bei grosser
        // Breite, da stehen sie dauerhaft da. Sonst zeichnet dieser Takt gegen
        // eine durchsichtige Anzeige; beim Hovern setzt onHoverChange den
        // Stand ohnehin sofort neu.
        guard view.isHovering || view.showsExtras else { return }
        view.progressBar.progress = displayPosition / track.duration
        view.setTimes(running: Self.clock(displayPosition), total: Self.clock(track.duration))
    }

    private func loadArtwork(_ urlString: String) {
        guard !urlString.isEmpty else { view.cover.image = nil; return }
        if let cached = artworkCache[urlString] { view.cover.image = cached; return }
        guard let url = URL(string: urlString) else { view.cover.image = nil; return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.artworkCache.count > 40 { self.artworkCache.removeAll() }
                self.artworkCache[urlString] = image
                if self.track.artworkURL == urlString { self.view.cover.image = image }
            }
        }.resume()
    }

    // MARK: Dem Dock folgen

    // MARK: Breite ziehen

    /// Die Hoehe gehoert dem Dock, frei ist nur die Breite.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: clampWidth(frameSize.width), height: sender.frame.height)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveResizing = true
    }

    func windowDidResize(_ notification: Notification) {
        // Waehrend des Ziehens ist der Fensterrahmen die Wahrheit; die
        // Nachfuehrung darf ihn nicht ueberschreiben.
        pendingWidth = panel.frame.width
        updateText()            // Album und Vorschau haengen an der Breite
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        liveResizing = false
        if let width = pendingWidth {
            UserDefaults.standard.set(Double(width), forKey: widthKey)
        }
        pendingWidth = nil
        lastDockFrame = .null    // wieder an den Dock heranziehen
        followDock()
        view.menu = buildContextMenu()
        writeDiagnostics()
    }

    private func followDock() {
        guard !liveResizing else { return }
        // Der Dock aendert seine Groesse nur aus zwei Gruenden: der Zeiger ist
        // bei ihm (Vergroesserung) oder er faehrt ein und aus. Beides passiert
        // nur in seiner Naehe. Sonst genuegen fuenf Blicke je Sekunde. Die
        // Zeigerabfrage ist kostenlos, die Abfrage der Bedienungshilfen nicht:
        // sie macht bei 60 Hz zwei Prozent Rechenzeit aus, gemessen.
        if !lastDockFrame.isNull {
            let pointer = NSEvent.mouseLocation
            let every: Int
            if panel.frame.contains(pointer) {
                // Auf dem Panel vergroessert sich der Dock nicht. Nur haeufig
                // genug hinsehen, um den Uebergang zum Dock nicht zu verpassen.
                every = 3
            } else if lastDockFrame.insetBy(dx: -180, dy: -180).contains(pointer) {
                every = 1
            } else {
                every = 12
            }
            if every > 1 {
                idleTicks += 1
                guard idleTicks >= every else { return }
            }
        }
        idleTicks = 0

        guard track.hasTrack, let dockFrame = Dock.frame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockFrame) }),
              screen.frame.contains(dockFrame)
        else {
            if panel.isVisible { panel.orderOut(nil); writeDiagnostics() }
            return
        }

        // Unveraendert und sichtbar? Dann ist nichts zu tun – das spart bei
        // 60 Abfragen je Sekunde den Grossteil der Rechenzeit.
        if dockFrame == lastDockFrame, panel.isVisible, panel.frame.width == panelWidth {
            return
        }
        lastDockFrame = dockFrame

        var frame = CGRect(x: dockFrame.maxX + gap, y: dockFrame.minY,
                           width: panelWidth, height: dockFrame.height)
        if frame.maxX > screen.frame.maxX - 4 {
            frame.origin.x = dockFrame.minX - gap - panelWidth
        }
        if frame.minX < screen.frame.minX + 4 {
            frame.origin.x = screen.frame.minX + 4
        }

        if frame != panel.frame {
            panel.setFrame(frame, display: false)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
            writeDiagnostics()
        }
        // Album und Liedtextvorschau haengen an der Breite; nach jeder
        // Aenderung der Geometrie neu entscheiden.
        updateText()
    }

    // MARK: Berechtigungen

    /// Schreibt den Zustand nach /tmp/docktunes-status.txt - erspart bei
    /// "Panel unsichtbar" das Raetselraten.
    private func showAutomationHint() {
        let alert = NSAlert()
        alert.messageText = "DockTunes darf Spotify nicht steuern"
        alert.informativeText = "Ohne diese Erlaubnis kennt DockTunes weder Titel noch Wiedergabe und bleibt "
            + "unsichtbar.\n\nSystemeinstellungen > Datenschutz & Sicherheit > Automatisierung, "
            + "dort bei DockTunes den Schalter fuer Spotify einschalten."
        alert.addButton(withTitle: "Systemeinstellungen oeffnen")
        alert.addButton(withTitle: "Spaeter")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func writeDiagnostics() {
        let dockFrame = Dock.frame()

        let lines = [
            "Bedienungshilfen erteilt : \(AXIsProcessTrusted())",
            "Spotify laeuft           : \(Spotify.isRunning)",
            "Spotify steuerbar        : \(Spotify.permissionDenied ? "NEIN - nicht erlaubt" : (track.title.isEmpty ? "noch unklar" : "ja"))",
            "Titel gelesen            : \(track.title.isEmpty ? "-- leer --" : track.title)",
            "Dock gefunden            : \(dockFrame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "NEIN")",
            "Panel                    : x=\(Int(panel.frame.minX)) y=\(Int(panel.frame.minY)) \(Int(panel.frame.width))x\(Int(panel.frame.height)) Schluessel=\(panel.isKeyWindow)",
            "Panel sichtbar           : \(panel?.isVisible == true)",
            "Playlist-Verbindung      : \(SpotifyWeb.isLinked ? "steht" : (SpotifyWeb.clientID == nil ? "keine Client-ID" : "nicht angemeldet"))",
            "Zugangs-Ablage           : \(SpotifyWeb.storageCheck())",
            "Symbolbreiten            : \(PlayerView.inkReport())",
            "Darstellung System       : \(NSApp.effectiveAppearance.name.rawValue)",
            "Darstellung Panel        : \(panel?.effectiveAppearance.name.rawValue ?? "-")",
            "Darstellung Inhalt       : \(view?.effectiveAppearance.name.rawValue ?? "-")",
        ]
        try? lines.joined(separator: "\n").write(toFile: "/tmp/docktunes-status.txt", atomically: true, encoding: .utf8)
    }

    private func checkPermission() {
        guard !AXIsProcessTrusted() else { return }

        // Der System-Dialog trägt DockTunes selbst in die Liste der
        // Bedienungshilfen ein. Ein eigener Hinweis täte das nicht – dann müsste
        // man die App dort über "+" von Hand heraussuchen.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Sobald die Freigabe steht, ohne Neustart weitermachen.
        let watcher = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.refreshTrack()
            self?.followDock()
        }
        RunLoop.main.add(watcher, forMode: .common)
    }
}
