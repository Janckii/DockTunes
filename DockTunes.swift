import AppKit
import Accelerate
import CoreServices
import ApplicationServices
import AudioToolbox
import CoreAudio
import CryptoKit
import Network
import ServiceManagement


/// Zweisprachig ohne Bundle-Lokalisierung: die App ist eine einzige Datei, und
/// ein .lproj-Verzeichnis waere fuer drei Dutzend Zeichenketten zu viel
/// Apparat. Deutsch, wenn das System auf Deutsch steht, sonst Englisch.
func t(_ de: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("de") == true ? de : en
}

// MARK: - Spotify-Anbindung

/// Ein Interpret mit seiner Spotify-Kennung, damit sein Name anklickbar ist.
struct ArtistLink: Equatable {
    let name: String
    let uri: String
}

private struct Track: Equatable {
    var spotifyRunning = false
    var isPlaying = false
    var title = ""
    /// Nur der Hauptinterpret. Bleibt so, weil die Liedtextsuche ihn braucht:
    /// lrclib fuehrt die Titel unter diesem einen Namen, eine Aufzaehlung
    /// findet dort nichts.
    var artist = ""
    /// Alle Interpreten, durch Komma getrennt – sobald sie bekannt sind.
    /// Der Skriptzugang von Spotify kennt nur den ersten, siehe
    /// SpotifyWeb.loadArtists.
    var artists = ""
    /// Dieselben Namen einzeln, mit Kennung: nur damit laesst sich einer
    /// anklicken. Ohne Web-Verbindung bleibt die Liste leer.
    var artistLinks: [ArtistLink] = []
    var album = ""
    var repeating = false
    var artworkURL = ""
    var uri = ""
    var duration: TimeInterval = 0     // Sekunden
    var position: TimeInterval = 0     // Sekunden

    var hasTrack: Bool { spotifyRunning && !title.isEmpty }
    /// Fuer die Anzeige. Der Rueckfall auf den ersten Namen greift, solange die
    /// Besetzung noch unterwegs ist oder gar keine Web-API verbunden ist.
    var credits: String { artists.isEmpty ? artist : artists }
}

private enum Spotify {
    /// AppleScript ist nicht thread-sicher – alle Aufrufe laufen hier hintereinander.
    private static let queue = DispatchQueue(label: "de.jancko.docktunes.spotify")
    private static let bundleID = "com.spotify.client"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Nur Position und Zustand. Kostet gemessen 15 ms statt 60 fuer den
    /// vollen Abruf – und mehr wird zum Nachziehen der Position nicht
    /// gebraucht. Titelwechsel und Start/Stopp meldet Spotify von selbst.
    static func loadPosition(_ completion: @escaping ((TimeInterval, Bool)?) -> Void) {
        queue.async {
            guard isRunning else { DispatchQueue.main.async { completion(nil) }; return }
            let raw = runCached("""
            tell application "Spotify"
              return (player position as text) & "|" & (player state as text)
            end tell
            """)
            let parts = raw?.components(separatedBy: "|") ?? []
            guard parts.count == 2, let pos = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let playing = parts[1] == "playing"
            DispatchQueue.main.async { completion((pos, playing)) }
        }
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
              set trackRepeat to (repeating as string)
              set coverURL to artwork url of current track
              set trackLength to duration of current track
              set playPos to player position
              set trackURI to spotify url of current track
              return playerStatus & "\\n" & trackName & "\\n" & trackArtist & "\\n" & coverURL ¬
                & "\\n" & trackLength & "\\n" & playPos & "\\n" & trackURI & "\\n" & trackAlbum ¬
                & "\\n" & trackRepeat
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
                    if parts.count >= 9 { track.repeating = parts[8] == "true" }
                    // Länge kommt in Millisekunden, Position in Sekunden.
                    track.duration = (number(parts[4]) ?? 0) / 1000
                    track.position = number(parts[5]) ?? 0
                    track.uri = parts[6]
                    track.artistLinks = SpotifyWeb.cachedArtists(for: track.uri) ?? []
                    track.artists = track.artistLinks.map(\.name).joined(separator: ", ")
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
    static func setRepeating(_ on: Bool) {
        send("set repeating to \(on)")
    }

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
        // Ohne .completeFileProtection: diese Schutzklasse macht die Datei auf
        // macOS unlesbar – nachgemessen wurde sie danach selbst fuer die App
        // selbst und fuer den Eigentuemer mit "Operation not permitted"
        // abgewiesen, obwohl die Rechte 0600 lauteten. Der Schutz sind hier die
        // Dateirechte, nicht eine Klasse aus der iOS-Welt.
        try? data.write(to: storeURL, options: [.atomic])
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
            completion(.failure(SimpleError(t("Es ist noch keine Client-ID hinterlegt.", "No client ID has been stored yet."))))
            return
        }
        verifier = randomString(64)
        let state = randomString(16)

        listener = CallbackListener(port: 8888) { code, returnedState in
            listener?.stop()
            listener = nil
            guard returnedState == state else {
                DispatchQueue.main.async { completion(.failure(SimpleError(t("Antwort passt nicht zur Anfrage.", "The reply does not match the request.")))) }
                return
            }
            guard let code else {
                DispatchQueue.main.async { completion(.failure(SimpleError(t("Die Anmeldung wurde abgebrochen.", "Sign-in was cancelled.")))) }
                return
            }
            exchange(code: code, clientID: clientID, completion: completion)
        }
        guard listener?.start() == true else {
            completion(.failure(SimpleError(t("Port 8888 ist belegt – die Rückleitung kann nicht empfangen werden.", "Port 8888 is busy – the redirect cannot be received."))))
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
                    completion(.failure(SimpleError(t("Spotify hat keinen Zugang ausgestellt.", "Spotify did not issue an access token."))))
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
                completion(.failure(SimpleError(t("Nicht mit Spotify verbunden.", "Not connected to Spotify."))))
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
                        let text: String
                        switch status {
                        case 403:
                            text = t(
                                "Spotify verweigert den Zugriff (403).\n\n"
                                + "Wenn das bei jeder Playlist passiert, liegt es meist "
                                + "am eigenen Konto in der Spotify-App: "
                                + "developer.spotify.com/dashboard öffnen, die App "
                                + "auswählen, Settings → User Management, sich selbst "
                                + "mit Name und E-Mail eintragen.\n\n"
                                + "Bei einer einzelnen Playlist heißt es meist: sie "
                                + "gehört jemand anderem – dort darf nur der Besitzer "
                                + "etwas ändern.",
                                "Spotify refuses access (403).\n\n"
                                + "If this happens for every playlist, your account is "
                                + "usually missing from the Spotify app: open "
                                + "developer.spotify.com/dashboard, pick the app, "
                                + "Settings → User Management, add yourself with name "
                                + "and e-mail.\n\n"
                                + "For a single playlist it usually means it belongs to "
                                + "someone else – only the owner may change it.")
                        case 401: text = t("Die Anmeldung ist abgelaufen. Im Menü einmal trennen und neu verbinden.",
                                           "The sign-in has expired. Disconnect and reconnect from the menu.")
                        case 404: text = t("Die Playlist gibt es nicht mehr.", "That playlist no longer exists.")
                        case 429: text = t("Zu viele Anfragen an Spotify. Gleich nochmal versuchen.",
                                           "Too many requests to Spotify. Try again shortly.")
                        default:  text = t("Spotify antwortete mit Fehler \(status).",
                                           "Spotify replied with error \(status).")
                        }
                        completion(.failure(SimpleError(text)))
                        return
                    }
                    completion(.success(data ?? Data()))
                }
            }.resume()
        }
    }

    /// Eigene Kontokennung – noetig, um fremde Playlists auszusortieren.
    /// Sie aendert sich nie, wird also einmal geholt und behalten.
    private static var accountID: String? {
        get { UserDefaults.standard.string(forKey: "spotifyAccountID") }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyAccountID") }
    }

    private static func withAccountID(_ completion: @escaping (String?) -> Void) {
        if let accountID { completion(accountID); return }
        call("me") { result in
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else { completion(nil); return }
            accountID = id
            completion(id)
        }
    }

    /// Liefert nur Playlists, in die sich auch schreiben laesst: eigene und
    /// gemeinsame. "me/playlists" gibt auch alle gefolgten zurueck – dort
    /// antwortet Spotify beim Hinzufuegen mit 403. Gemessen an einem echten
    /// Konto: 12 von 23 Eintraegen waren fremd.
    // MARK: Besetzung

    /// Der Skriptzugang von Spotify kennt "artist" nur in der Einzahl und gibt
    /// dort den ersten Namen zurueck: bei "Rich Baby Daddy (feat. Sexyy Red &
    /// SZA)" steht da schlicht "Drake", waehrend Spotify selbst "Drake, Sexyy
    /// Red, SZA" fuehrt. Die ganze Besetzung steht nur in der Web-API. Ohne
    /// Verbindung bleibt es beim ersten Namen – das ist der alte Zustand, es
    /// geht also nichts verloren.
    private static var artistCache: [String: [ArtistLink]] = [:]
    private static var artistPending: Set<String> = []
    private static var artistTries: [String: Int] = [:]
    private static let artistLock = NSLock()

    private static func trackID(from uri: String) -> String? {
        // Nur richtige Titel: eigene Dateien und Podcastfolgen tragen eine
        // andere Kennung, die dieser Aufruf nicht kennt.
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Aus dem Speicher, ohne Nachfrage – laeuft im Takt des Auslesens mit.
    static func cachedArtists(for uri: String) -> [ArtistLink]? {
        guard let id = trackID(from: uri) else { return nil }
        artistLock.lock()
        defer { artistLock.unlock() }
        return artistCache[id]
    }

    /// Fragt die Besetzung einmal je Titel nach. Auch ein einzelner Name wird
    /// gespeichert, sonst stellte die App dieselbe Frage bei jedem Durchlauf
    /// neu. Meldet sich nur, wenn wirklich etwas ankommt.
    static func loadArtists(for uri: String, completion: @escaping ([ArtistLink]) -> Void) {
        guard isLinked, let id = trackID(from: uri) else { return }
        artistLock.lock()
        // Nach drei Fehlschlaegen ist Ruhe. Sonst fragte die App, solange der
        // Titel laeuft, bei jedem Durchlauf neu – ohne Netz alle paar Sekunden.
        guard artistCache[id] == nil, !artistPending.contains(id),
              artistTries[id, default: 0] < 3 else {
            artistLock.unlock()
            return
        }
        artistTries[id, default: 0] += 1
        artistPending.insert(id)
        artistLock.unlock()
        call("tracks/" + id) { result in
            artistLock.lock()
            artistPending.remove(id)
            artistLock.unlock()
            guard case .success(let data) = result,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["artists"] as? [[String: Any]] else { return }
            let links: [ArtistLink] = entries.compactMap { entry in
                guard let name = entry["name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                // Ohne Kennung bleibt der Name stehen, nur eben ohne Verweis.
                return ArtistLink(name: name, uri: entry["uri"] as? String ?? "")
            }
            guard !links.isEmpty else { return }
            artistLock.lock()
            // Sonst waechst der Speicher mit jedem gehoerten Titel weiter.
            if artistCache.count > 200 { artistCache.removeAll(); artistTries.removeAll() }
            artistCache[id] = links
            artistTries[id] = nil
            artistLock.unlock()
            completion(links)
        }
    }

    static func loadPlaylists(completion: @escaping (Result<[Playlist], Error>) -> Void) {
        withAccountID { account in
        call("me/playlists?limit=50") { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    completion(.failure(SimpleError(t("Playlists konnten nicht gelesen werden.", "Playlists could not be read."))))
                    return
                }
                let playlists = items.compactMap { item -> Playlist? in
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                    let owner = (item["owner"] as? [String: Any])?["id"] as? String
                    let shared = (item["collaborative"] as? Bool) ?? false
                    // Ohne bekannte Kontokennung lieber alle zeigen als keine.
                    guard account == nil || owner == account || shared else { return nil }
                    return Playlist(id: id, name: name)
                }
                completion(.success(playlists))
            }
        }
        }
    }

    static func add(trackURI: String, to playlist: Playlist,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        let body = try? JSONSerialization.data(withJSONObject: ["uris": [trackURI]])
        // "/items", nicht "/tracks": den alten Pfad weist Spotify inzwischen mit
        // 403 ab, ohne Begruendung. Nachgemessen am selben Konto, selber
        // Playlist, selbem Schluessel: /tracks 403, /items 201. Alles andere
        // (Profil, Playlist-Liste, Playlist-Details, Suche) antwortet auf
        // beiden Wegen normal – der Fehler sah deshalb nach einer fehlenden
        // Berechtigung aus und war keine.
        call("playlists/\(playlist.id)/items", method: "POST", body: body) { result in
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
                    ? t("<h2>Fertig.</h2><p>DockTunes ist jetzt mit Spotify verbunden. Dieses Fenster kann geschlossen werden.</p>",
                        "<h2>Done.</h2><p>DockTunes is now connected to Spotify. You can close this window.</p>")
                    : t("<h2>Abgebrochen.</h2><p>Es wurde kein Zugang erteilt.</p>",
                        "<h2>Cancelled.</h2><p>No access was granted.</p>")
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

        searchField.placeholderString = t("Playlist suchen", "Search playlists")
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
            place(header(t("Favoriten", "Favourites")), height: 20)
            favored.forEach { place(row(for: $0, isFavorite: true), height: 27) }
        }
        if !shown.isEmpty {
            if !favored.isEmpty { place(header(t("Weitere", "More")), height: 22) }
            shown.forEach { place(row(for: $0, isFavorite: false), height: 27) }
        }
        if hidden > 0 {
            place(moreRow(count: hidden), height: 26)
        }
        if matching.isEmpty { place(header(t("Nichts gefunden", "Nothing found")), height: 22) }

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
        row.playlist = SpotifyWeb.Playlist(id: "__more__", name: t("\(count) weitere anzeigen …", "show \(count) more …"))
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
    /// Der Dock-Prozess wechselt praktisch nie. Ihn alle zwei Sekunden in der
    /// Prozessliste zu suchen war im Leerlauf der groesste Posten (gemessen:
    /// der Loewenanteil der Ruhelast steckte in dieser Suche). Deshalb wird er
    /// behalten und erst verworfen, wenn die Abfrage fehlschlaegt – dann ist
    /// der Dock neu gestartet. Nur in diesem Fall wird wieder gesucht, und
    /// hoechstens alle zwei Sekunden.
    private static func element() -> AXUIElement? {
        if let cachedElement { return cachedElement }
        let now = Date()
        guard now.timeIntervalSince(lastLookup) >= 2 else { return nil }
        lastLookup = now
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })
        else { return nil }
        cachedPID = app.processIdentifier
        cachedElement = AXUIElementCreateApplication(app.processIdentifier)
        return cachedElement
    }

    private static func forget() {
        cachedElement = nil
        cachedList = nil
    }

    /// Rechteck des sichtbaren Dock-Glases in Fensterkoordinaten.
    /// Rechteck des sichtbaren Dock-Glases in Fensterkoordinaten.
    ///
    /// Die Symbolliste wird gemerkt. Sie jedes Mal unter den Kindern zu suchen
    /// heisst: ein Feld anlegen und fuer jedes Kind die Rolle erfragen – jede
    /// Abfrage geht als eigener Aufruf an den Dock-Prozess. Gemessen kostete
    /// ein Durchlauf damit rund 2 ms und war im Leerlauf der groesste Posten.
    /// Mit gemerkter Liste bleiben zwei Abfragen.
    private static var cachedList: AXUIElement?

    private static func listElement() -> AXUIElement? {
        if let cachedList { return cachedList }
        guard let dock = element() else { return nil }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            forget()          // Dock neu gestartet: beim naechsten Mal neu suchen
            return nil
        }
        for child in children {
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
            guard (roleValue as? String) == kAXListRole as String else { continue }
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success
            else { continue }
            var size = CGSize.zero
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            guard size.width > 1, size.height > 1 else { continue }
            cachedList = child
            return child
        }
        return nil
    }

    static func frame() -> CGRect? {
        guard let list = listElement() else { return nil }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            // Die gemerkte Liste taugt nicht mehr – beim naechsten Mal neu suchen.
            cachedList = nil
            forget()
            return nil
        }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { cachedList = nil; return nil }
        let rect = CGRect(origin: origin, size: size)
        let referenceMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        // AX zählt y von oben, Fenster von unten – und das Glas liegt tiefer.
        return CGRect(x: rect.minX,
                      y: referenceMaxY - rect.maxY - glassOffsetY,
                      width: rect.width,
                      height: rect.height)
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
            // Nur zeichnen lassen, wenn sich sichtbar etwas aendert: gerundet
            // auf ganze Punkte Hoehe und auf 32 Stufen Deckkraft. Jeder
            // Durchlauf loest einen Compositor-Umlauf ueber die Glasflaeche
            // aus – ohne diese Pruefung dreissigmal je Sekunde, auch wenn die
            // Balken auf derselben Hoehe stehen bleiben.
            let now = quantised(bands)
            guard now != lastCommitted else { return }
            lastCommitted = now
            applyLevels()
        }
    }

    private var lastCommitted: [Int32] = []

    private func quantised(_ values: [Float]) -> [Int32] {
        let h = Float(bounds.height)
        return values.map { v in
            let height = max(3, (h * v).rounded())
            let alpha = (0.35 + 0.5 * v) * 32
            return Int32(height) &* 64 &+ Int32(alpha.rounded())
        }
    }
    var tone: NSColor = .labelColor { didSet { applyShape() } }

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
        if bands.count != bars.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = bands.map { _ in
                let bar = CALayer()
                bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer?.addSublayer(bar)
                return bar
            }
        }
        lastCommitted = []
        applyShape()
        applyLevels()
    }

    /// Alles, was nur von der Groesse und der Farbe abhaengt. Getrennt vom
    /// Pegel, weil es dreissigmal je Sekunde unveraendert neu gesetzt wuerde –
    /// und weil jede Farbe sonst ein neues CGColor kostet, siebenmal je Bild.
    private func applyShape() {
        guard !bars.isEmpty, bounds.width > 0 else { return }
        let barWidth = self.barWidth
        guard barWidth > 0.5 else { return }
        let color = tone.withAlphaComponent(1).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color
        }
        CATransaction.commit()
    }

    private var barWidth: CGFloat {
        let gap: CGFloat = 2
        return (bounds.width - gap * CGFloat(max(1, bars.count) - 1)) / CGFloat(max(1, bars.count))
    }

    /// Je Bild nur zwei Werte: Hoehe und Deckkraft. Beides bewegt der
    /// Compositor, ohne dass etwas neu gezeichnet wird.
    private func applyLevels() {
        guard !bars.isEmpty, bounds.width > 0 else { return }
        let gap: CGFloat = 2
        let barWidth = self.barWidth
        guard barWidth > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)      // kein Nachziehen, der Wert gilt sofort
        for (i, bar) in bars.enumerated() {
            let value = CGFloat(bands.indices.contains(i) ? bands[i] : 0)
            let height = max(3, bounds.height * value)
            bar.frame = CGRect(x: CGFloat(i) * (barWidth + gap),
                               y: (bounds.height - height) / 2,
                               width: barWidth, height: height)
            bar.opacity = Float(0.35 + 0.5 * value)
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
    let repeatButton = NSButton()
    /// Drei Zustaende: aus (gedimmt), alle (hell), einzeln (hell mit der 1
    /// im Symbol – so zeigt es auch Apple Music und Spotify selbst).
    /// Aus wird gedimmt gezeigt statt ausgeblendet, damit sichtbar bleibt,
    /// dass es die Wahl gibt.
    var repeatMode = 0 {
        didSet {
            guard repeatMode != oldValue else { return }
            repeatButton.image = Self.symbol(repeatMode == 2 ? "repeat.1" : "repeat",
                                             repeatMode == 2 ? t("Titel einzeln wiederholen", "Repeat one")
                                                             : t("Alle wiederholen", "Repeat all"))
            repeatButton.alphaValue = repeatMode == 0 ? 0.45 : 1
            needsLayout = true          // "repeat.1" ist breiter als "repeat"
        }
    }
    let progressBar = ProgressBar()
    let timeLabel = NSTextField(labelWithString: "")
    let totalLabel = NSTextField(labelWithString: "")
    private let titleClip = NSView()
    private let marquee = CALayer()
    private var marqueeKey = ""

    let spectrum = SpectrumView()
    var showsSpectrum = false { didSet { needsLayout = true } }

    // Was bei welcher Breite dazukommt. Die Reihenfolge folgt dem Nutzen:
    // weiter ist wichtiger als zurueck, und beides wichtiger als das Plus.
    // Der Interpret braucht keine Breite, er steht unter dem Titel. Selbst im
    // schmalsten Panel bleibt fuer beide Zeilen Platz.
    private var showsArtistLine: Bool { true }
    var showsExtras: Bool { bounds.width >= 520 }
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

        // Der Titel sitzt in einem Ausschnitt. Passt er nicht hinein, laeuft
        // er darin endlos durch; die zweite Kopie schliesst die Luecke, damit
        // der Text nicht am Rand abreisst und von vorn anfaengt.
        titleClip.wantsLayer = true
        titleClip.layer?.masksToBounds = true
        titleClip.layer?.addSublayer(marquee)
        marquee.isHidden = true
        titleClip.addSubview(titleLabel)
        content.addSubview(titleClip)
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true

        artistLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.cell?.usesSingleLineMode = true
        content.addSubview(artistLabel)

        for (button, symbol, description) in [
            (previousButton, "backward.fill", t("Vorheriger Titel", "Previous track")),
            (playButton, "play.fill", t("Abspielen", "Play")),
            (nextButton, "forward.fill", t("Nächster Titel", "Next track")),
            (repeatButton, "repeat", t("Alle wiederholen", "Repeat all")),
            (addButton, "plus.circle", t("Zur Playlist hinzufügen", "Add to playlist")),
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imageScaling = .scaleNone
            button.image = Self.symbol(symbol, description)
            button.contentTintColor = .labelColor
            content.addSubview(button)
        }

        // Anfangszustand ausdruecklich setzen: der Beobachter von repeatMode
        // laeuft nicht, solange sich der Wert nicht aendert – aus haette sonst
        // beim Start ausgesehen wie an.
        repeatButton.alphaValue = 0.45

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
    override func mouseDown(with event: NSEvent) {
        // Trifft der Klick einen Interpreten, oeffnet der sich; sonst bleibt es
        // beim alten Verhalten und Spotify kommt nach vorn.
        let point = convert(event.locationInWindow, from: nil)
        if let index = artistZone(at: point) {
            onArtistClick?(artistZones[index].uri)
            return
        }
        // Das Cover fuehrt zum Titel selbst, alles uebrige holt nur Spotify
        // nach vorn. Im Liedtext-Modus ist es null Punkte breit, dann trifft
        // die Pruefung ohnehin nie.
        if cover.bounds.contains(cover.convert(point, from: self)) {
            onCoverClick?()
            return
        }
        onClick?()
    }

    /// Das Menue wird bei jedem Rechtsklick neu gebaut. Beim Start steht die
    /// Dock-Geometrie noch nicht fest, und davon haengt ab, welche Breiten
    /// ueberhaupt neben den Dock passen.
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }

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

    /// Gemeinsamer Faktor fuer alle Schatten; 0 schaltet sie ab.
    ///
    /// Warum ueberhaupt Schatten: ueber einem hellen Fenster hinter dem Dock
    /// steht weisser Text auf einer Flaeche von 221 – gemessene 34 Stufen
    /// Eigenkontrast, das traegt nicht. Der Schatten bringt dort 60 Stufen
    /// dazu. Ueber einem dunklen Schreibtischbild ist er dagegen kaum zu
    /// sehen (Flaeche 82, Halo 23), kostet also fast nichts an Ruhe.
    /// Frueher 1,0 – das war ueber dunklem Grund unnoetig praegnant.
    static var shadowStrength: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "shadowStrength") as? Double ?? 0.6)
    }

    private func shadow(radius: CGFloat, opacity: Float) -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(CGFloat(opacity) * Self.shadowStrength)
        s.shadowBlurRadius = radius
        s.shadowOffset = NSSize(width: 0, height: -0.5)
        return s
    }

    /// Setzt Titel und Unterzeile samt Schatten. Ein Textfeld zeichnet die
    /// shadow-Eigenschaft nicht – der Schatten muss ins Textattribut.
    var onTextChange: (() -> Void)?

    private var lastTimeWidth: CGFloat = -1
    private var lastRunning = ""
    private var lastTotal = ""
    var currentTotal: String { lastTotal }

    /// Die Zeiten bestimmen die Feldbreite und damit das ganze Layout. Ein
    /// Neulayout je Sekunde kostet mehr als es bringt: die Breite aendert sich
    /// nur beim Sprung auf zweistellige Minuten.
    /// Leert die Zeiten und den Merker dazu. Ohne das Zuruecksetzen haelt
    /// setTimes den naechsten gleichen Wert faelschlich fuer unveraendert und
    /// die Felder blieben leer.
    func clearTimes() {
        lastRunning = ""
        lastTotal = ""
        timeLabel.stringValue = ""
        totalLabel.stringValue = ""
    }

    func setTimes(running: String, total: String) {
        // Die gesetzten Werte selbst merken: stringValue am Feld abzufragen geht
        // durch AppKit und passierte sonst bei jedem Durchlauf zweimal.
        guard running != lastRunning || total != lastTotal else { return }
        var changed = false
        if running != lastRunning { lastRunning = running; timeLabel.stringValue = running; changed = true }
        if total != lastTotal { lastTotal = total; totalLabel.stringValue = total; changed = true }
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
        // Der Lauftext haengt am Text: ohne neues Layout liefe die Bewegung
        // des vorigen Titels mit der alten Laenge weiter.
        needsLayout = true
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
        renderArtistLine()
    }

    // MARK: Anklickbare Interpreten

    /// Die Namen der Unterzeile mit ihrer Kennung. Leer, wenn dort etwas
    /// anderes steht – eine Liedzeile etwa – oder ohne Web-Verbindung.
    var artistLinks: [ArtistLink] = [] {
        didSet {
            guard artistLinks != oldValue else { return }
            hoveredArtist = nil
            renderArtistLine()
        }
    }
    var onArtistClick: ((String) -> Void)?
    var onCoverClick: (() -> Void)?
    private var hoveredArtist: Int?
    /// Waagerechte Ausdehnung jedes Namens, einmal je Zeile ausgerechnet.
    /// Beim Bewegen des Zeigers ist dann nur noch zu vergleichen.
    private var artistZones: [(range: NSRange, from: CGFloat, to: CGFloat, uri: String)] = []

    private func renderArtistLine() {
        // Der Attributtext bringt seinen eigenen Absatzstil mit und ueberging
        // damit das byTruncatingTail des Feldes: zu lange Zeilen brachen hart
        // ab, mitten im Wort und ohne Auslassungszeichen. Faellt erst bei
        // mehreren Interpreten auf, betraf aber auch lange Einzelnamen.
        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: lastSubtitle ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: secondaryColor,
            .shadow: shadow(radius: 2.5, opacity: 0.85),
            .paragraphStyle: clip,
        ])
        artistLabel.attributedStringValue = text
        rebuildArtistZones()
        // Der Zeiger kann den Namen nicht anzeigen – den Mauszeiger setzt nur
        // das Programm im Vordergrund, und das Panel kommt nie dorthin. Die
        // Unterstreichung ist der Ersatz dafuer.
        guard let hoveredArtist, hoveredArtist < artistZones.count else { return }
        text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 1)],
                           range: artistZones[hoveredArtist].range)
        artistLabel.attributedStringValue = text
    }

    private func rebuildArtistZones() {
        artistZones = []
        guard !artistLinks.isEmpty else { return }
        let attributed = artistLabel.attributedStringValue
        guard attributed.length > 0 else { return }
        let whole = attributed.string as NSString
        let line = CTLineCreateWithAttributedString(attributed)
        var from = 0
        for link in artistLinks where !link.uri.isEmpty {
            // Der Reihe nach suchen: bei "Sexyy Red" und "Red" in derselben
            // Zeile faende eine freie Suche sonst zweimal dieselbe Stelle.
            let found = whole.range(of: link.name,
                                    range: NSRange(location: from, length: whole.length - from))
            guard found.location != NSNotFound else { continue }
            from = found.location + found.length
            let a = CTLineGetOffsetForStringIndex(line, found.location, nil)
            let b = CTLineGetOffsetForStringIndex(line, from, nil)
            artistZones.append((found, min(a, b), max(a, b), link.uri))
        }
    }

    /// Welcher Name liegt unter diesem Punkt der Ansicht?
    private func artistZone(at point: CGPoint) -> Int? {
        guard !artistZones.isEmpty, !artistLabel.isHidden else { return nil }
        let local = convert(point, to: artistLabel)
        guard artistLabel.bounds.contains(local) else { return nil }
        // Das Textfeld zeichnet mit einem kleinen eigenen Rand.
        let inset = artistLabel.cell?.titleRect(forBounds: artistLabel.bounds).minX ?? 0
        let x = local.x - inset
        return artistZones.firstIndex { x >= $0.from && x <= $0.to }
    }

    private func setHoveredArtist(_ index: Int?) {
        guard index != hoveredArtist else { return }
        hoveredArtist = index
        renderArtistLine()
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
    /// Der Rest ist ein fester Abzug per "plusD": 30,5 Stufen im Hellmodus,
    /// 14,5 im Dunkelmodus.
    ///
    /// Der Abzug haengt am Bildschirm: auf dem eingebauten Retina-Schirm mischt
    /// das Glas anders als auf einem aeusseren. Gemessen mit 24 Stufen Abzug
    /// lag die Flaeche innen 12 Stufen zu hell, aussen 4. Eingestellt ist der
    /// Wert fuer den eingebauten Schirm (30,5), weil das der Normalfall ist;
    /// aussen bleiben damit rund 10 Stufen. Feinjustage: liftLight. Ein Abzug aendert nur den Sockel, nicht die
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
            ?? (dark ? 0.9431 : 0.8804)
        shade.layer?.backgroundColor = NSColor(calibratedWhite: shadeWhite, alpha: opacity).cgColor
        boost.layer?.compositingFilter = d.string(forKey: "boostFilter") ?? "plusD"
        boost.layer?.backgroundColor = NSColor(calibratedWhite: liftGray, alpha: 1).cgColor
    }

    func applyColors() {
        applyFill()
        applyRim()
        for button in [previousButton, playButton, nextButton, addButton, repeatButton] {
            button.contentTintColor = primaryColor
            button.wantsLayer = true
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = Float(0.55 * Self.shadowStrength)
            button.layer?.shadowRadius = 2.5
            button.layer?.shadowOffset = .zero
        }
        cover.layer?.backgroundColor = primaryColor.withAlphaComponent(0.12).cgColor
        progressBar.tone = primaryColor
        spectrum.tone = primaryColor
        timeLabel.textColor = secondaryColor
        totalLabel.textColor = secondaryColor
        // Schatten ueber die Ebene, nicht als Textattribut: ein Attributtext
        // misst sich anders, und die Feldbreite haengt an dieser Messung –
        // die Zeiten wurden dadurch um ein Zeichen beschnitten.
        for label in [timeLabel, totalLabel] {
            label.wantsLayer = true
            label.layer?.shadowColor = NSColor.black.cgColor
            label.layer?.shadowOpacity = Float(0.8 * Self.shadowStrength)
            label.layer?.shadowRadius = 2
            label.layer?.shadowOffset = .zero
        }
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
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
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
    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        setHoveredArtist(nil)
    }
    /// Kommt nur, solange der Zeiger auf dem Panel steht, und faellt sofort
    /// wieder aus. Gezeichnet wird nur, wenn ein anderer Name darunter liegt.
    override func mouseMoved(with event: NSEvent) {
        setHoveredArtist(artistZone(at: convert(event.locationInWindow, from: nil)))
    }

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
        if showsSpectrum { total += 30 + gap }
        return ceil(total)
    }

    /// Setzt den Titelausschnitt und entscheidet, ob der Text darin laeuft.
    /// Im Liedtext-Modus nicht: dort bricht die Zeile um, statt zu wandern.
    ///
    /// Der Lauftext ist ein einzelnes Bild mit zwei Abzuegen des Titels, das
    /// der Compositor schiebt. Zwei Textfelder waeren naheliegender, aber
    /// AppKit zeichnet eine Ansicht nicht, solange sie ausserhalb des
    /// Ausschnitts liegt – die zweite Kopie blieb dadurch leer und es entstand
    /// eine Luecke von mehreren Sekunden (nachgemessen).
    private func placeTitle(_ rect: NSRect, scrolls: Bool) {
        titleClip.frame = rect
        let text = titleLabel.attributedStringValue
        let natural = ceil(text.size().width)
        let key = "\(titleLabel.stringValue)|\(Int(rect.width))|\(Int(rect.height))|\(scrolls)"
        guard scrolls, natural > rect.width else {
            titleLabel.isHidden = false
            titleLabel.frame = titleClip.bounds
            if marqueeKey != key {
                marqueeKey = key
                marquee.removeAnimation(forKey: "lauftext")
                marquee.isHidden = true
            }
            return
        }
        titleLabel.isHidden = true
        marquee.isHidden = false
        guard marqueeKey != key else { return }
        marqueeKey = key

        // Zwei Abzuege im Abstand von 40 Punkten. Das Band wandert um genau
        // eine Abzugslaenge; danach steht der zweite dort, wo der erste war.
        let space: CGFloat = 40
        let step = natural + space
        let size = NSSize(width: step + natural, height: rect.height)
        let baseline = (rect.height - ceil(text.size().height)) / 2
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: NSPoint(x: 0, y: baseline))
            text.draw(at: NSPoint(x: step, y: baseline))
            return true
        }
        marquee.contents = image
        marquee.contentsScale = window?.backingScaleFactor ?? 2
        marquee.frame = CGRect(origin: .zero, size: size)
        marquee.removeAnimation(forKey: "lauftext")
        // Erst stehen bleiben, dann wandern. Die Pause laesst den Anfang des
        // Titels lesen, bevor er losgeht – und sie kostet nichts: solange sich
        // nichts bewegt, muss die Glasflaeche auch nicht neu gemischt werden.
        // Am Ende steht der zweite Abzug genau dort, wo der erste stand, der
        // Sprung zurueck auf null ist deshalb unsichtbar.
        let pause: TimeInterval = 2.5
        let travel = Double(step) / 20         // Punkte je Sekunde
        let start = marquee.position.x
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [start, start, start - step]
        move.keyTimes = [0, NSNumber(value: pause / (pause + travel)), 1]
        move.timingFunctions = [CAMediaTimingFunction(name: .linear),
                                CAMediaTimingFunction(name: .linear)]
        move.duration = pause + travel
        move.repeatCount = .infinity
        marquee.add(move, forKey: "lauftext")
    }

    /// Mindestplatz fuer den Titel. Darunter waere er nur noch ein hastig
    /// durchlaufender Schnipsel.
    static let minTitleRoom: CGFloat = 70

    /// Breite, die die Knopfreihe braucht – gerechnet, nicht gesetzt.
    private func buttonsAdvance(add: Bool, repeatOn: Bool, previous: Bool) -> CGFloat {
        let symbolGap: CGFloat = 12
        var total: CGFloat = 0
        let set: [(NSButton, String, Bool)] = [
            (addButton, "plus", add), (repeatButton, "repeat", repeatOn),
            (nextButton, "next", true), (playButton, "play", true),
            (previousButton, "previous", previous),
        ]
        for (button, key, shown) in set where shown {
            let full = key + (button === playButton || button === repeatButton
                              ? (button.image?.accessibilityDescription ?? "") : "")
            let ink = Self.ink(of: button.image, key: full)
            total += ink.left + ink.width + ink.right + symbolGap
        }
        return total
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
        let keys = ["plus", "repeat", "next", "play", "previous"]
        // Was hineinpasst, wird ausgerechnet statt an feste Breiten gebunden.
        // Auf einem 1512 Punkte breiten Bildschirm bleiben neben einem 850
        // Punkte breiten Dock nur 327 – feste Schwellen von 360 und 380 haetten
        // dort Plus und Wiederholen fuer immer verschluckt, obwohl beide passen.
        // Weggelassen wird in der Reihenfolge des Nutzens: Wiederholen zuerst,
        // dann das Plus, dann Zurueck. Weiter und Abspielen bleiben immer.
        // Zur Playlist legen kann man einen Titel nur hier; wiederholen auch
        // in Spotify selbst.
        let textLeftForFit = showsLyrics ? pad : pad + (bounds.height - pad * 2 - 2) + gap
        var showAdd = true, showRepeat = true, showPrevious = true
        for _ in 0..<3 {
            let used = buttonsAdvance(add: showAdd, repeatOn: showRepeat, previous: showPrevious)
                + (showsSpectrum ? 30 + gap : 0)
            let room = bounds.width - pad - used - textLeftForFit - gap
            if room >= Self.minTitleRoom { break }
            if showRepeat { showRepeat = false }
            else if showAdd { showAdd = false }
            else if showPrevious { showPrevious = false }
            else { break }
        }
        previousButton.isHidden = !showPrevious
        addButton.isHidden = !showAdd
        repeatButton.isHidden = !showRepeat
        for (index, button) in [addButton, repeatButton, nextButton, playButton, previousButton].enumerated() {
            if button.isHidden { continue }
            let key = keys[index] + (button === playButton || button === repeatButton
                                     ? (button.image?.accessibilityDescription ?? "") : "")
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

        // Tonanzeige davor. Ob sie ueberhaupt erscheint, entscheidet der
        // Schalter im Menue; sie weicht nur, wenn dem Titel sonst zu wenig
        // bliebe. Die Schwelle haengt an der Panelbreite und daran, welche
        // Knoepfe stehen – nicht am Text. Sonst ginge sie bei jedem Titel an
        // und aus. Passt der Titel nicht, laeuft er durch.
        let spectrumWidth: CGFloat = 30
        let textLeft = showsLyrics ? pad : cover.frame.maxX + gap
        let roomForTitle = rightEdge - textLeft - (spectrumWidth + gap)
        let spectrumVisible = showsSpectrum && roomForTitle >= Self.minTitleRoom
        spectrum.isHidden = !spectrumVisible
        if spectrumVisible {
            let spectrumHeight: CGFloat = 20
            spectrum.frame = CGRect(x: rightEdge - spectrumWidth,
                                    y: round((bounds.height - spectrumHeight) / 2) + lift,
                                    width: spectrumWidth, height: spectrumHeight)
            rightEdge -= spectrumWidth + gap
        }

        // Titel und Unterzeile
        let textWidth = max(20, rightEdge - textLeft)
        let lineHeight: CGFloat = 14
        let top = (bounds.height - lineHeight * 2) / 2
        artistLabel.isHidden = wrapsText || !showsArtistLine
        if !wrapsText && !showsArtistLine {
            // Nur der Titel: dann steht er mittig, nicht auf der oberen der
            // beiden Zeilen.
            placeTitle(CGRect(x: textLeft, y: round((bounds.height - lineHeight) / 2) + lift,
                              width: textWidth, height: lineHeight), scrolls: true)
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
            placeTitle(CGRect(x: textLeft,
                              y: round((bounds.height - height) / 2 + correction) + lift,
                              width: textWidth, height: height), scrolls: false)
        } else {
            placeTitle(CGRect(x: textLeft, y: round(top + lineHeight - 1) + lift,
                              width: textWidth, height: lineHeight), scrolls: true)
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

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
    private var fullPollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var repeatMode = 0
    private var noticeUntil = Date.distantPast
    private var pickerCount = 0
    private var followLog: [String] = []
    private var lastFollowWrite = Date.distantPast
    private var loopTimer: Timer?
    private var motionTimer: Timer?
    private var spectrumTimer: Timer?
    private let analyzer = AudioSpectrum()
    private var track = Track()
    private var artworkCache: [String: NSImage] = [:]
    private var permissionNoticeShown = false

    /// Wohin das Panel unterwegs ist – die Bewegung dorthin läuft weich.
    private var lastDockFrame: CGRect = .null
    private var tick = 0
    private var offScreenSince: Date?
    private var fastFollow = true
    private var fastFollowRate: Double = 60
    private var pointerNearDock = false
    private var pointerOnPanel = false
    private var scrubbing = false
    private var positionAnchor: (value: TimeInterval, at: Date)?

    /// Liedzeilen brauchen deutlich mehr Platz als ein Songtitel.
    private var panelWidth: CGFloat {
        guard let view else { return 372 }
        // Fest, nicht nach Inhalt: eine mitwandernde Breite waere bei jedem
        // Titel eine andere, und das Panel spraenge staendig hin und her.
        // Eingestellt wird sie im Rechtsklick-Menue.
        if let cachedWidth { return cachedWidth }
        let stored = UserDefaults.standard.object(forKey: widthKey) as? Double
            ?? (lyricsMode ? 520 : 380)
        let width = clampWidth(CGFloat(stored))
        cachedWidth = width
        return width
    }

    /// Die Breite haengt an einer Einstellung, am Modus und am Platz neben dem
    /// Dock – nichts davon aendert sich zwischen zwei Takten. Sie bei jeder
    /// Abfrage neu zu holen hiess: einmal in die Einstellungen und einmal durch
    /// alle Bildschirme, sechzigmal je Sekunde.
    private var cachedWidth: CGFloat?

    /// Getrennte Breiten: der Liedtext-Modus braucht mehr Platz als Cover,
    /// Titel und Knoepfe, und beides einzeln zu merken erspart das Nachziehen
    /// bei jedem Umschalten.
    private var widthKey: String { lyricsMode ? "lyricsWidth" : "panelWidth" }

    /// Unter 200 Punkten bleibt vom Panel nichts Sinnvolles uebrig: Cover,
    /// eine lesbare Titelzeile und ein Knopf brauchen zusammen so viel.
    static let minWidth: CGFloat = 200

    /// Das Panel steht neben dem Dock, nicht um ihn herum – es zaehlt also der
    /// Platz auf **einer** Seite, nicht die Restbreite des Bildschirms. Auf
    /// einem 1512 Punkte breiten Bildschirm mit 850 Punkte breitem Dock sind
    /// das 319 je Seite, nicht 630.
    private func clampWidth(_ width: CGFloat) -> CGFloat {
        guard !lastDockFrame.isNull,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(lastDockFrame) })
        else { return max(width, Self.minWidth) }
        let roomRight = (screen.frame.maxX - 4) - (lastDockFrame.maxX + gap)
        let roomLeft = (lastDockFrame.minX - gap) - (screen.frame.minX + 4)
        let room = max(Self.minWidth, max(roomRight, roomLeft))
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
        fastFollowRate = max(4.0, min(120.0, UserDefaults.standard.object(forKey: "followRate") as? Double ?? 60))
        fastFollow = true
        followTimer = schedule(every: 1.0 / fastFollowRate) { [weak self] in self?.followDock() }
        // Fuenfmal je Sekunde genuegt: der Strich wandert bei drei Minuten
        // Spielzeit alle anderthalb Sekunden um einen Punkt, die Sekunden-
        // anzeige springt einmal je Sekunde, und Liedtextzeilen wechseln alle
        // paar Sekunden.
        progressTimer = schedule(every: 0.2) { [weak self] in self?.updateProgress() }
        // Spotify meldet Wechsel von sich aus; dieser Takt ist nur die Rückfallebene
        // und die Nachführung der Wiedergabeposition. Ein Abruf kostet 55 ms.
        syncPollRate()
        // Rueckfallebene, falls eine Meldung von Spotify ausbleibt.
        fullPollTimer = schedule(every: 60) { [weak self] in self?.refreshTrack() }

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
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Der Dock wirft keinen Schatten: der Grund neben ihm misst 45,0 –
        // genau den Wert des Hintergrunds. Mit Schatten sass das Panel sichtbar
        // "auf" dem Bild statt darin (gemessen 31 ueber, 28 unter der Kante).
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        // Ohne das kommen ueber die Beobachtungszone zwar Eintreten und
        // Verlassen an, aber keine Bewegung - und damit wuesste das Panel nie,
        // ueber welchem Interpreten der Zeiger gerade steht.
        panel.acceptsMouseMovedEvents = true
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
        view.repeatButton.target = self
        view.repeatButton.action = #selector(toggleRepeat)
        view.addButton.target = self
        view.addButton.action = #selector(addToPlaylist)
        view.onClick = { [weak self] in self?.openSpotify() }
        view.onArtistClick = { [weak self] uri in self?.openArtist(uri) }
        view.onCoverClick = { [weak self] in self?.openTrack() }
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

        view.menuProvider = { [weak self] in self?.buildContextMenu() }

        view.progressBar.onScrub = { [weak self] fraction in
            guard let self else { return }
            self.scrubbing = true
            // Die Zeit links an der Leiste zeigt beim Ziehen das Ziel. Sie steht
            // ohnehin da; sie zweitens in die Interpretenzeile zu schreiben,
            // sagt dasselbe zweimal und wirft den Text beim Ziehen um.
            guard self.track.duration > 0 else { return }
            self.view.setTimes(running: Self.clock(fraction * self.track.duration),
                               total: self.view.currentTotal)
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
            defer { self.syncPollRate() }
            if hovering {
                self.refreshTrack()
                self.syncPollRate()
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
        let open = NSMenuItem(title: t("Spotify öffnen", "Open Spotify"), action: #selector(openSpotify), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        if SpotifyWeb.isLinked {
            let choose = NSMenuItem(title: t("Zu Playlist hinzufügen …", "Add to playlist …"), action: #selector(choosePlaylist), keyEquivalent: "")
            choose.target = self
            choose.isEnabled = !track.uri.isEmpty
            menu.addItem(choose)
            let unlink = NSMenuItem(title: t("Spotify-Verbindung trennen", "Disconnect from Spotify"), action: #selector(unlinkSpotify), keyEquivalent: "")
            unlink.target = self
            menu.addItem(unlink)
        } else {
            let link = NSMenuItem(title: t("Mit Spotify verbinden …", "Connect to Spotify …"), action: #selector(setUpSpotifyLink), keyEquivalent: "")
            link.target = self
            menu.addItem(link)
        }
        menu.addItem(.separator())
        // Ein einzelner Schalter "regelt Systemlautstärke" ist zweideutig: man
        // schaltet ihn ein und bekommt das Gegenteil des Erwarteten. Zwei
        // benannte Optionen sind eindeutig.
        let usesSystem = UserDefaults.standard.bool(forKey: "systemVolume")
        let volumeMenu = NSMenu()
        for (title, wantsSystem) in [("Spotify", false), (t("System", "System"), true)] {
            let item = NSMenuItem(title: title, action: #selector(setVolumeSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = wantsSystem
            item.state = (usesSystem == wantsSystem) ? .on : .off
            volumeMenu.addItem(item)
        }
        let volumeItem = NSMenuItem(title: t("Scrollen regelt Lautstärke von", "Scrolling controls volume of"), action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)
        let lyricsItem = NSMenuItem(title: t("Liedtext mitlaufen lassen", "Show live lyrics"), action: #selector(toggleLyrics), keyEquivalent: "")
        lyricsItem.target = self
        lyricsItem.state = lyricsMode ? .on : .off
        menu.addItem(lyricsItem)
        // Die Stufen sind an den Inhalt gekoppelt, nicht rund gewaehlt: jede
        // bringt etwas Sichtbares mehr (siehe README, Abschnitt Breite).
        let steps: [(String, Double)] = lyricsMode
            ? [(t("Schmal", "Narrow"), 420), (t("Normal", "Normal"), 520), (t("Breit", "Wide"), 640), (t("Sehr breit", "Very wide"), 760)]
            : [(t("Schmal", "Narrow"), 250), (t("Normal", "Normal"), 380), (t("Breit", "Wide"), 520), (t("Sehr breit", "Very wide"), 640)]
        // Gegen die tatsaechliche Breite pruefen, nicht gegen die gespeicherte:
        // die letzte Stufe traegt den verfuegbaren Platz, nicht den Wunschwert.
        let current = Double(panelWidth)
        // Nur anbieten, was neben den Dock passt. Auf einem schmalen Schirm
        // waere "Sehr breit" eine Wahl ohne Wirkung; die letzte Stufe bekommt
        // stattdessen den tatsaechlich verfuegbaren Platz.
        let room = Double(clampWidth(.greatestFiniteMagnitude))
        // Gezeigt wird, was passt; gespeichert der urspruengliche Wunschwert.
        // Sonst merkte sich die App die Zahl dieses Bildschirms und bliebe an
        // einem groesseren Schirm unnoetig schmal.
        var fitting: [(String, Double, Double)] = []
        for (title, value) in steps {
            if value <= room { fitting.append((title, value, value)) }
            else { fitting.append((title, room, value)); break }
        }
        let widthMenu = NSMenu()
        for (title, shown, stored) in fitting {
            let item = NSMenuItem(title: title, action: #selector(setLyricsWidth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stored
            item.state = abs(current - shown) < 1 ? .on : .off
            widthMenu.addItem(item)
        }
        let widthItem = NSMenuItem(title: t("Breite", "Width"), action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)
        let spectrumItem = NSMenuItem(title: t("Tonanalyse anzeigen", "Show audio meter"), action: #selector(toggleSpectrum), keyEquivalent: "")
        spectrumItem.target = self
        spectrumItem.state = spectrumEnabled ? .on : .off
        menu.addItem(spectrumItem)
        menu.addItem(.separator())
        let login = NSMenuItem(title: t("Bei der Anmeldung starten", "Start at login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: t("DockTunes beenden", "Quit DockTunes"), action: #selector(quit), keyEquivalent: "")
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
            alert.messageText = t("Anmeldeobjekt konnte nicht geändert werden", "Could not change the login item")
            alert.informativeText = error.localizedDescription
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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

    /// Oeffnet den Interpreten in Spotify. Der Aufruf holt die App selbst nach
    /// vorn, ein zusaetzliches Aktivieren waere doppelt.
    /// Blaettert in Spotify zur Seite des laufenden Titels. Nachgemessen: der
    /// Aufruf startet nichts – die Wiedergabe laeuft unveraendert weiter, es
    /// wechselt nur die Ansicht.
    ///
    /// Eigene Dateien tragen eine andere Kennung, zu der es keine Seite gibt;
    /// dort bleibt es beim blossen Nach-vorn-Holen.
    private func openTrack() {
        guard track.uri.hasPrefix("spotify:track:"), let url = URL(string: track.uri) else {
            openSpotify()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openArtist(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Playlists

    @objc private func addToPlaylist() {
        if let picker, picker.isVisible {
            picker.close()
            self.picker = nil
            return
        }
        guard !track.uri.isEmpty else { return }
        guard SpotifyWeb.isLinked else { setUpSpotifyLink(); return }
        // Immer fragen: ohne Auswahl weiss niemand, wohin der Titel wandert,
        // und die zuletzt benutzte Liste ist selten die gewollte.
        choosePlaylist()
    }

    /// Kurze Rückmeldung am Knopf, damit der Klick sichtbar wirkt.
    private func flashAddButton(symbol: String) {
        view.addButton.image = PlayerView.symbol(symbol, "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.view.addButton.image = PlayerView.symbol("plus.circle", t("Zur Playlist hinzufügen", "Add to playlist"))
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
                self.showError(t("Playlists konnten nicht geladen werden", "Could not load playlists"), error.localizedDescription)
            case .success(let playlists):
                guard !playlists.isEmpty else {
                    self.showError(t("Keine Playlists gefunden", "No playlists found"), t("Dein Konto hat keine bearbeitbaren Playlists.", "Your account has no editable playlists."))
                    return
                }
                let picker = PlaylistPicker(playlists: playlists) { [weak self] chosen in
                    self?.addTrack(to: chosen)
                }
                picker.onClose = { [weak self] in
                    self?.pickerClosedAt = Date()
                    self?.picker = nil
                    self?.writeDiagnostics()
                }
                self.picker = picker
                self.pickerCount = playlists.count
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.writeDiagnostics() }
                // Ueber dem Plus-Knopf aufklappen
                let button = self.view.addButton.frame
                let anchor = self.panel.frame.origin
                picker.show(near: NSPoint(x: anchor.x + button.midX, y: anchor.y + self.panel.frame.height + 8))
            }
        }
    }

    private func addTrack(to playlist: SpotifyWeb.Playlist) {
        guard !track.uri.isEmpty else { return }
        SpotifyWeb.add(trackURI: track.uri, to: playlist) { [weak self] result in
            switch result {
            case .success:
                self?.flashAddButton(symbol: "checkmark.circle.fill")
                // Ein Haken sagt nur "hat geklappt", nicht wohin. Der Name der
                // Liste steht deshalb kurz in der Unterzeile.
                let name = playlist.name.trimmingCharacters(in: .whitespaces)
                self?.flashNotice(t("Zu \(name) hinzugefügt", "Added to \(name)"))
            case .failure(let error):
                self?.flashAddButton(symbol: "exclamationmark.circle.fill")
                let text = error.localizedDescription
                self?.showError(t("Titel konnte nicht hinzugefügt werden", "Could not add track"), text,
                                offerRelink: text.contains("403"))
            }
        }
    }

    /// Kurze Rueckmeldung in der Unterzeile. Nutzt denselben Weg wie die
    /// Lautstaerkeanzeige: der Liedtext darf waehrenddessen nicht nachruecken.
    private func flashNotice(_ text: String) {
        noticeUntil = Date().addingTimeInterval(1.8)
        view.setTexts(title: view.titleLabel.stringValue, subtitle: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, Date() >= self.noticeUntil else { return }
            self.updateText()
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
            alert.messageText = t("Einmalige Einrichtung", "One-time setup")
            alert.informativeText = t(
                "Zum Einsortieren in Playlists braucht DockTunes eine eigene Client-ID.\n\n"
                + "1. developer.spotify.com/dashboard öffnen und eine App anlegen\n"
                + "2. Als Redirect URI eintragen: " + SpotifyWeb.redirectURI + "\n"
                + "3. Unter Settings → User Management sich selbst eintragen\n"
                + "4. Client-ID kopieren und hier einsetzen",
                "To file tracks into playlists DockTunes needs its own client ID.\n\n"
                + "1. Open developer.spotify.com/dashboard and create an app\n"
                + "2. Set the redirect URI to: " + SpotifyWeb.redirectURI + "\n"
                + "3. Under Settings → User Management, add yourself\n"
                + "4. Copy the client ID and paste it here")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = t("Client-ID", "Client ID")
            alert.accessoryView = field
            alert.addButton(withTitle: t("Weiter", "Continue"))
            alert.addButton(withTitle: t("Dashboard öffnen", "Open dashboard"))
            alert.addButton(withTitle: t("Abbrechen", "Cancel"))
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
                self.choosePlaylist()
            case .failure(let error):
                self.showError("Verbindung fehlgeschlagen", error.localizedDescription)
            }
        }
    }

    @objc private func unlinkSpotify() {
        SpotifyWeb.unlink()
    }

    private func showError(_ title: String, _ text: String, offerRelink: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.window.level = .floating
        alert.addButton(withTitle: "OK")
        // Spotify prueft die Freigabe beim Anmelden, nicht bei jedem Aufruf.
        // Wer sich erst danach im Dashboard eintraegt, braucht eine neue
        // Anmeldung – ein Erneuern des Schluessels genuegt nicht (nachgeprueft).
        if offerRelink { alert.addButton(withTitle: t("Neu verbinden …", "Reconnect …")) }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, offerRelink {
            SpotifyWeb.unlink()
            setUpSpotifyLink()
        }
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
        // Die Wiedergabeposition steht nur in der Zeitleiste, und die ist beim
        // Zeigen, bei grosser Breite und im Liedtext-Modus zu sehen. Sonst
        // interessiert sie niemanden, und ein Abruf kostet 55 ms.
        let needsPosition = view?.isHovering == true || view?.showsExtras == true || lyricsMode
        let interval: TimeInterval = track.isPlaying ? (needsPosition ? 5 : 15) : 20
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = schedule(every: interval) { [weak self] in self?.refreshPosition() }
    }

    /// Zieht nur die Position nach. Aendert sich dabei der Wiedergabezustand,
    /// ist doch etwas passiert – dann der volle Abruf.
    private func refreshPosition() {
        Spotify.loadPosition { [weak self] result in
            guard let self else { return }
            guard let position = result else { self.refreshTrack(); return }
            if position.1 != self.track.isPlaying {
                self.refreshTrack()
                return
            }
            self.track.position = position.0
            self.positionAnchor = (position.0, Date())
            self.updateProgress()
        }
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
            // Die uebrigen Interpreten kommen einen Wimpernschlag spaeter nach
            // und ersetzen dann den einzelnen Namen. Beim naechsten Durchlauf
            // stehen sie schon im Speicher, es blitzt also nichts zurueck.
            if new.artists.isEmpty, new.hasTrack {
                SpotifyWeb.loadArtists(for: new.uri) { [weak self] links in
                    guard let self, self.track.uri == new.uri else { return }
                    self.track.artistLinks = links
                    self.track.artists = links.map(\.name).joined(separator: ", ")
                    self.updateText()
                }
            }
            if !wasSame || artworkChanged { self.applyTrack(new, reloadArtwork: artworkChanged) }
            if playChanged { self.syncPollRate() }
            // Spotifys eigenes Wiederholen hat Vorrang; "einzeln" ist unser
            // Zustand und steht in den Einstellungen.
            self.repeatMode = new.repeating ? 1
                : (UserDefaults.standard.bool(forKey: "repeatOne") ? 2 : 0)
            self.view.repeatMode = self.repeatMode
            self.armLoop()
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
                                                  track.isPlaying ? t("Pausieren", "Pause") : t("Abspielen", "Play"))
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
        // 24 statt 30 Bilder je Sekunde: die Balken bewegen sich fuer das Auge
        // gleich, gemessen kostet der Unterschied 0,3 Prozentpunkte.
        let rate = max(5.0, min(60.0, UserDefaults.standard.object(forKey: "spectrumRate") as? Double ?? 24))
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
        guard !view.progressBar.showsVolume, Date() >= noticeUntil else { return }
        guard lyricsMode else {
            // Das Album kommt erst bei grosser Breite dazu; darunter waere die
            // Zeile nur abgeschnitten.
            let showsAlbum = view.showsExtras && !track.album.isEmpty
                && track.album != track.title
            // Vor setTexts: die Zeile wird dort gezeichnet, und dabei werden
            // die anklickbaren Stellen gleich mit ausgerechnet.
            view.artistLinks = track.artistLinks
            view.setTexts(title: track.title,
                          subtitle: showsAlbum ? "\(track.credits) · \(track.album)" : track.credits)
            return
        }
        guard !lyricLines.isEmpty else {
            view.artistLinks = []
            view.setTexts(title: track.title,
                          subtitle: lyricsTrackURI.isEmpty ? "" : t("kein Liedtext gefunden", "no lyrics found"))
            return
        }
        let (current, next) = Lyrics.at(displayPosition, in: lyricLines)
        // Vor der ersten Zeile und in Instrumentalpausen steht nichts an –
        // dann lieber Titel und Interpret als eine leere Flaeche.
        if current.isEmpty {
            view.artistLinks = track.artistLinks
            view.setTexts(title: track.title, subtitle: track.credits)
        } else if view.showsLyricPreview && !next.isEmpty {
            // In der Unterzeile steht jetzt Liedtext, kein Interpret.
            view.artistLinks = []
            // Genug Platz: die naechste Zeile darunter, wie frueher – hier
            // nimmt sie der laufenden nichts weg.
            view.setTexts(title: current, subtitle: next)
        } else {
            view.artistLinks = []
            view.setLyricLine(current)
        }
    }

    /// Aus: Spotifys eigener Regler (Vorgabe). An: die des Systems.
    @objc private func setVolumeSource(_ sender: NSMenuItem) {
        guard let wantsSystem = sender.representedObject as? Bool else { return }
        UserDefaults.standard.set(wantsSystem, forKey: "systemVolume")
    }

    @objc private func setLyricsWidth(_ sender: NSMenuItem) {
        guard let width = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(width, forKey: widthKey)
        cachedWidth = nil
        lastDockFrame = .null          // Breite geaendert, Position neu setzen
        followDock()
        updateText()                   // Album und Vorschau haengen an der Breite
    }

    /// aus → alle → einzeln → aus.
    ///
    /// "alle" ist Spotifys eigenes Wiederholen. "einzeln" kennt Spotify ueber
    /// AppleScript nicht (die Eigenschaft ist ein blosses Ja/Nein, nachgesehen
    /// im Woerterbuch), deshalb macht das Panel es selbst: kurz vor Schluss
    /// zurueck auf Anfang. Das braucht weder Web-Anmeldung noch Premium.
    @objc private func toggleRepeat() {
        switch repeatMode {
        case 0: repeatMode = 1; Spotify.setRepeating(true)
        case 1: repeatMode = 2; Spotify.setRepeating(false)
        default: repeatMode = 0; Spotify.setRepeating(false)
        }
        UserDefaults.standard.set(repeatMode == 2, forKey: "repeatOne")
        view.repeatMode = repeatMode
        armLoop()
        // Spotify braucht einen Moment; danach den echten Stand holen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshTrack() }
    }

    /// Springt kurz vor Ende zurueck auf Anfang. Der Abstand ist mit Absicht
    /// grosszuegig: die Position wird zwischen den Abrufen hochgerechnet, und
    /// zu spaet waere der naechste Titel schon dran.
    private func armLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        guard repeatMode == 2, track.isPlaying, track.duration > 2 else { return }
        let remaining = track.duration - displayPosition - 0.6
        guard remaining > 0 else { restartTrack(); return }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            self?.restartTrack()
        }
        RunLoop.main.add(timer, forMode: .common)
        loopTimer = timer
    }

    private func restartTrack() {
        guard repeatMode == 2 else { return }
        Spotify.seek(to: 0)
        positionAnchor = (0, Date())
        updateProgress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshTrack() }
    }

    @objc private func toggleLyrics() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "lyricsMode"), forKey: "lyricsMode")
        view.showsLyrics = lyricsMode
        cachedWidth = nil
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
            view.setTexts(title: view.titleLabel.stringValue, subtitle: t("Lautstärke \(level) %", "Volume \(level) %"))
            view.clearTimes()          // Spielzeiten passen hier nicht dazu
        }
        view.progressBar.showsVolume = true
        view.forceProgressVisible(true)
        volumeResetTimer?.invalidate()
        let timer = Timer(timeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.view.progressBar.showsVolume = false
            self.view.forceProgressVisible(false)
            self.updateText()          // erst jetzt wieder erlaubt
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
        // Waehrend die Lautstaerke angezeigt wird, darf der Liedtext nicht
        // nachruecken – er ueberschriebe die Anzeige zehnmal je Sekunde.
        if lyricsMode, !lyricLines.isEmpty, track.isPlaying,
           !view.progressBar.showsVolume { updateText() }
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

    /// Kurzes Gedaechtnis fuer die letzten Auffaelligkeiten beim Nachfuehren.
    /// Steht in der Selbstpruefung; ohne das laesst sich ein Aufblitzen beim
    /// Bildschirmwechsel nicht nachvollziehen, es ist zu kurz zum Hinsehen.
    private func noteFollow(_ text: String) {
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        followLog.append("\(stamp) \(text)")
        if followLog.count > 12 { followLog.removeFirst() }
        // Hoechstens einmal je Sekunde schreiben – waehrend eines Wechsels
        // faellt das sonst sechzigmal an.
        if Date().timeIntervalSince(lastFollowWrite) > 1 {
            lastFollowWrite = Date()
            writeDiagnostics()
        }
    }

    /// Der Taktgeber selbst kostet: bei 60 Hz gemessen 0,6 Prozentpunkte mehr
    /// als bei 15, selbst wenn der Durchlauf nichts tut. Voll laeuft er
    /// deshalb nur, solange der Zeiger beim Dock steht – nur dann kann sich
    /// dessen Groesse ueberhaupt aendern. Sonst zwoelfmal je Sekunde, was
    /// genuegt, um die Annaeherung rechtzeitig zu bemerken.
    private func setFollowRate(fast: Bool) {
        guard fast != fastFollow else { return }
        fastFollow = fast
        followTimer?.invalidate()
        let hz = fast ? fastFollowRate : 12
        followTimer = schedule(every: 1.0 / hz) { [weak self] in self?.followDock() }
        writeDiagnostics()
    }

    private func followDock() {
        // Der Dock aendert seine Groesse nur aus zwei Gruenden: der Zeiger ist
        // bei ihm (Vergroesserung) oder er faehrt ein und aus. Beides passiert
        // nur in seiner Naehe. Sonst genuegen fuenf Blicke je Sekunde. Die
        // Zeigerabfrage ist kostenlos, die Abfrage der Bedienungshilfen nicht:
        // sie macht bei 60 Hz zwei Prozent Rechenzeit aus, gemessen.
        tick &+= 1
        if !lastDockFrame.isNull {
            let pointer = NSEvent.mouseLocation
            // Auf dem Panel vergroessert sich der Dock nicht – und das Panel
            // liegt im Beobachtungsband des Docks. Ohne diese Unterscheidung
            // liefe beim Zeigen aufs Panel die volle Rate.
            pointerOnPanel = panel.frame.contains(pointer)
            pointerNearDock = !pointerOnPanel
                && lastDockFrame.insetBy(dx: -180, dy: -180).contains(pointer)
            setFollowRate(fast: pointerNearDock)
            // Im langsamen Takt genuegt jeder dritte Blick auf den Dock.
            if !fastFollow { guard tick % 3 == 0 else { return } }
        }

        guard track.hasTrack, let dockFrame = Dock.frame() else {
            // Kein Dock zu finden: Vollbild, automatisches Ausblenden oder kein
            // Titel. Dann gehoert das Panel sofort weg.
            if panel.isVisible {
                panel.orderOut(nil)
                noteFollow("verborgen: kein Dock")
                writeDiagnostics()
            }
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockFrame) }),
              screen.frame.contains(dockFrame) else {
            // Faehrt der Dock aus (automatisches Ausblenden), liegt sein
            // Rechteck dauerhaft ausserhalb – dann gehoert das Panel weg. Beim
            // Bildschirmwechsel ist derselbe Zustand nur ein Wimpernschlag
            // lang da. Ein Viertel Sekunde Geduld trennt beides.
            if offScreenSince == nil { offScreenSince = Date() }
            if let since = offScreenSince, Date().timeIntervalSince(since) > 0.25,
               panel.isVisible {
                panel.orderOut(nil)
                noteFollow("verborgen: Dock ausgefahren")
                writeDiagnostics()
                return
            }
            // Der Dock wandert gerade zwischen den Bildschirmen; sein Rechteck
            // passt dabei auf keinen einzelnen. Frueher wurde das Panel hier
            // ausgeblendet und gleich darauf wieder eingeblendet – genau das
            // war das kurze Aufblitzen beim Bildschirmwechsel. Jetzt bleibt es
            // einfach stehen, bis der Dock wieder auf einem Schirm sitzt.
            noteFollow("Wechsel: \(Int(dockFrame.minX)),\(Int(dockFrame.minY)) \(Int(dockFrame.width))x\(Int(dockFrame.height))")
            return
        }

        // Unveraendert und sichtbar? Dann ist nichts zu tun – das spart bei
        // 60 Abfragen je Sekunde den Grossteil der Rechenzeit.
        if dockFrame == lastDockFrame, panel.isVisible, panel.frame.width == panelWidth {
            return
        }
        offScreenSince = nil
        lastDockFrame = dockFrame
        cachedWidth = nil          // haengt am Platz neben dem Dock

        // Platz links und rechts vom Dock getrennt rechnen. Auf einem schmalen
        // Bildschirm mit breitem Dock passt die eingestellte Breite auf keine
        // Seite – frueher rutschte das Panel dann an den Bildschirmrand und lag
        // ueber dem Dock. Jetzt nimmt es die groessere Seite und wird nur so
        // breit, wie dort Platz ist.
        let roomRight = (screen.frame.maxX - 4) - (dockFrame.maxX + gap)
        let roomLeft = (dockFrame.minX - gap) - (screen.frame.minX + 4)
        let wanted = panelWidth
        let width: CGFloat
        let originX: CGFloat
        if roomRight >= wanted {
            width = wanted; originX = dockFrame.maxX + gap
        } else if roomLeft >= wanted {
            width = wanted; originX = dockFrame.minX - gap - wanted
        } else if roomRight >= roomLeft {
            width = max(Self.minWidth, roomRight); originX = dockFrame.maxX + gap
        } else {
            width = max(Self.minWidth, roomLeft); originX = dockFrame.minX - gap - max(Self.minWidth, roomLeft)
        }
        let frame = CGRect(x: originX, y: dockFrame.minY,
                           width: width, height: dockFrame.height)

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
        alert.messageText = t("DockTunes darf Spotify nicht steuern",
                              "DockTunes is not allowed to control Spotify")
        alert.informativeText = t(
            "Ohne diese Erlaubnis kennt DockTunes weder Titel noch Wiedergabe und bleibt "
            + "unsichtbar.\n\nSystemeinstellungen > Datenschutz & Sicherheit > Automatisierung, "
            + "dort bei DockTunes den Schalter fuer Spotify einschalten.",
            "Without it DockTunes knows neither the track nor the playback state and stays "
            + "invisible.\n\nSystem Settings > Privacy & Security > Automation, "
            + "then turn on the Spotify switch under DockTunes.")
        alert.addButton(withTitle: t("Systemeinstellungen oeffnen", "Open System Settings"))
        alert.addButton(withTitle: t("Spaeter", "Later"))
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
            "Auswahlfenster           : \(picker?.isVisible == true ? "offen mit \(pickerCount) Playlists" : "zu")",
            "Nachfuehren, zuletzt     : \(followLog.isEmpty ? "nichts" : followLog.joined(separator: " | "))",
            "Takt                     : leer=\(lastDockFrame.isNull) beimDock=\(pointerNearDock) aufPanel=\(pointerOnPanel) schnell=\(fastFollow)",
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
