import Foundation

/// YouTube Music for the iPhone page: its home page's shelves, your playlists, search, album
/// and playlist track lists, and playing any of it. Everything goes through the YouTube Music
/// tab, so it's the user's own: their account, their language. Reads go through `send`; the
/// rest runs on the scripting queue.
///
/// Reading goes to YouTube Music's own API (the endpoints its pages load from), signed in
/// the way its pages are (a SAPISIDHASH of the account cookie). The requests run in the tab
/// without blocking it; PlayPrio starts them and collects the answer once it's there.
///
/// Chrome runs AppleScript's JavaScript in an isolated world: it sees the page, not the
/// page's own code. Playing a particular song is handed to the page through a script element
/// (the page only accepts those through a Trusted Types policy), which raises the same
/// `yt-navigate` event YouTube Music's own play buttons do. Not `ytmusic-app.navigate()`: for
/// songs that leaves its loading bar running and the app half stuck.
enum CompanionLibrary {
    struct Shelf: Codable {
        let title: String
        /// The small line above the title (YouTube Music puts the account name there).
        let strapline: String
        let items: [Item]
        /// "playlists" for the user's own playlists (the page names that shelf), else empty.
        let kind: String
    }

    struct Item: Codable {
        /// YouTube Music's own link: "watch?v=…" for songs, "browse/…" for albums and playlists.
        let id: String
        let title: String
        let subtitle: String
        let image: String
        /// What it is when it isn't a song ("Album", "Playlist", "EP" …, in YouTube Music's
        /// words); empty for songs.
        let badge: String
    }

    /// An album's or playlist's page, for picking a song from it.
    struct Album: Codable {
        let title: String
        let artist: String
        /// "Album • 2019" and the like.
        let subtitle: String
        let image: String
        /// What plays the whole thing, and gives a song its place in it.
        let playlistId: String
        /// YouTube Music's own "shuffle play" for it (passed with the playlist), if it has one.
        let shuffleParams: String
        /// The artist's page ("UC…"), when the album names one.
        let artistId: String
        let tracks: [Track]
    }

    /// An artist's page: top songs, then albums, singles and the like as YouTube Music lists them.
    struct Artist: Codable {
        let name: String
        let image: String
        /// YouTube Music's own buttons: the artist's songs shuffled, and a mix (radio).
        let shuffle: Start?
        let radio: Start?
        let songs: [Item]
        /// The playlist of all their songs ("browse/VL…"), when YouTube Music has one.
        let allSongsId: String
        let shelves: [Shelf]
    }

    /// The home page's shelves, and the language YouTube Music shows them in ("en", "de" …).
    struct Home: Codable {
        let language: String
        let shelves: [Shelf]
    }

    /// What one of YouTube Music's play buttons starts.
    struct Start: Codable {
        let videoId: String
        let playlistId: String
        let params: String
    }

    /// What YouTube Music's player bar shows beyond the song: repeat mode and links.
    struct PlayerInfo: Codable, Equatable {
        /// "NONE", "ALL" or "ONE".
        let repeatMode: String
        let artistId: String
    }

    /// What a search found that can be played: songs and music videos, albums and playlists.
    struct SearchResults: Codable {
        let songs: [Item]
        let albums: [Item]
    }

    struct Track: Codable {
        let videoId: String
        let title: String
        let artist: String
        let duration: String
        let index: String
        let playable: Bool
    }

    /// The tab the shelves came from, so a pick plays there (and only there).
    private static var tabID: String?

    /// A read from YouTube Music's API, run in its tab (see `send`).
    struct Request<Value: Decodable> {
        fileprivate let job: String
    }

    /// The home page's shelves (all of them, the way YouTube Music pages through them), with
    /// the user's playlists after the first.
    static let home = Request<Home>(job: homeJS)

    /// An album's or playlist's page ("browse/…").
    static func album(id: String) -> Request<Album>? {
        guard id.hasPrefix("browse/"), isValid(id), let browseID = quoted(String(id.dropFirst("browse/".count))) else { return nil }
        return Request(job: albumJS.replacingOccurrences(of: "BROWSE_ID", with: browseID))
    }

    /// An artist's page ("UC…").
    static func artist(id: String) -> Request<Artist>? {
        guard id.range(of: #"^UC[\w-]{10,40}$"#, options: .regularExpression) != nil, let browseID = quoted(id) else { return nil }
        return Request(job: artistJS.replacingOccurrences(of: "BROWSE_ID", with: browseID))
    }

    /// Searches YouTube Music, as its own search box would.
    static func search(_ query: String) -> Request<SearchResults>? {
        quoted(query).map { Request(job: searchJS.replacingOccurrences(of: "QUERY", with: $0)) }
    }

    /// Starts `request` in the tab (it runs there without blocking the page) and collects the
    /// answer once it's in, on the main thread. Waiting happens between short visits to the
    /// scripting queue, so media keys pressed meanwhile aren't held up.
    static func send<Value>(_ request: Request<Value>?, with store: Store, done: @escaping (Value?) -> Void) {
        guard let request else { return done(nil) }
        let id = "r" + UUID().uuidString.prefix(8)
        let start = """
        (() => {
          window.playprioJobs = window.playprioJobs || {};
          window.playprioJobs['\(id)'] = null;
          (async () => { \(apiJS) \(request.job) })().then(
            (value) => { window.playprioJobs['\(id)'] = { value: String(value || '') }; },
            () => { window.playprioJobs['\(id)'] = { value: '' }; });
          return 'started';
        })()
        """
        let collect = "(() => { const r = (window.playprioJobs || {})['\(id)']; if (!r) return 'pending'; delete window.playprioJobs['\(id)']; return 'done:' + r.value; })()"
        store.runScript({ run(start) == "started" }) { started in
            guard started else { return done(nil) }
            // nil while the job runs; once it's done (or the tab is gone), its answer, if any.
            store.pollScript(every: 0.12, for: 12, { () -> String?? in
                guard let result = run(collect) else { return .some(nil) }
                guard result.hasPrefix("done:") else { return nil }
                return .some(String(result.dropFirst("done:".count)))
            }) { answer in
                done((answer ?? nil).flatMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) })
            }
        }
    }

    /// The player bar's repeat mode and the playing song's artist.
    static func playerInfo() -> PlayerInfo? {
        guard let json = run(playerInfoJS) else { return nil }
        return try? JSONDecoder().decode(PlayerInfo.self, from: Data(json.utf8))
    }

    /// Presses the player bar's repeat button (off → all → one → off) or shuffle button (which
    /// shuffles the queue once).
    @discardableResult
    static func press(_ button: String) -> Bool {
        guard ["repeat", "shuffle"].contains(button) else { return false }
        return run("(() => { const b = document.querySelector('ytmusic-player-bar .\(button)'); if (!b) return ''; b.click(); return 'ok'; })()") == "ok"
    }

    /// Plays a shelf item: a song (in the queue YouTube Music gives it there) right away, an
    /// album or playlist from its first song (`playlistID`, from its page). Without one, the
    /// tile's own play button on the home page is pressed.
    @discardableResult
    static func play(id: String, playlistID: String?) -> Bool {
        guard isValid(id) else { return false }
        if id.hasPrefix("watch?"), let query = URLComponents(string: "https://music.youtube.com/" + id)?.queryItems,
           let videoID = query.first(where: { $0.name == "v" })?.value {
            return play(videoID: videoID, playlistID: query.first { $0.name == "list" }?.value)
        }
        if let playlistID, !playlistID.isEmpty {
            return play(videoID: nil, playlistID: playlistID)
        }
        return run(pressJS.replacingOccurrences(of: "ITEM_ID", with: quoted(id) ?? "''")) != nil
    }

    /// Plays a song, in its album or playlist when given one; or a whole album or playlist.
    /// `params` are YouTube Music's own (shuffled, a mix …) from the button being copied.
    @discardableResult
    static func play(videoID: String?, playlistID: String?, params: String? = nil) -> Bool {
        let valid = { (value: String?, pattern: String) in value.map { $0.range(of: pattern, options: .regularExpression) != nil } ?? true }
        guard videoID != nil || playlistID != nil, valid(videoID, #"^[\w-]{11}$"#), valid(playlistID, #"^[\w-]{2,80}$"#),
              valid(params, #"^[\w%=-]{1,60}$"#) else { return false }
        // "wAEB" is what YouTube Music's own play buttons send: play here, in the player bar.
        var endpoint: [String: [String: String]]
        if let videoID {
            endpoint = ["watchEndpoint": ["videoId": videoID, "params": params ?? "wAEB"]]
            if let playlistID { endpoint["watchEndpoint"]?["playlistId"] = playlistID }
        } else {
            endpoint = ["watchPlaylistEndpoint": ["playlistId": playlistID!, "params": params ?? "wAEB"]]
        }
        guard let json = (try? JSONEncoder().encode(endpoint)).flatMap({ String(data: $0, encoding: .utf8) }),
              let code = quoted("""
              (document.querySelector('ytmusic-player-bar') || document.querySelector('ytmusic-app')).dispatchEvent(\
              new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: \(json) } }));
              """) else { return false }
        return run(inPage(code)) == "ok"
    }

    /// Jumps to a point in the song YouTube Music plays. Through its player, not the video:
    /// while an album plays, the video holds several songs.
    @discardableResult
    static func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0,
              let code = quoted("document.getElementById('movie_player').seekTo(\(seconds), true);") else { return false }
        return run(inPage(code)) == "ok"
    }

    /// Only links as YouTube Music writes them; they end up inside JavaScript.
    static func isValid(_ id: String) -> Bool {
        id.range(of: #"^(watch\?v=|browse/)[A-Za-z0-9_\-=&%.]+$"#, options: .regularExpression) != nil
    }

    // MARK: Helpers

    /// Runs `js` in the YouTube Music tab (the one the shelves came from, if it's still there).
    /// Call on the scripting queue.
    private static func run(_ js: String) -> String? {
        let prefixes = Targets.youTubeMusic.urlPrefixes
        var result = tabID.flatMap { try? Chromium.chrome.runJS(js, inTabsMatching: prefixes, tabIDs: [$0]).first }
        if result == nil { result = try? Chromium.chrome.runJS(js, inTabsMatching: prefixes).first }
        if let result { tabID = result.tabID }
        return result?.value
    }

    /// A JavaScript string literal.
    private static func quoted(_ text: String) -> String? {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Wraps code (a JavaScript string literal) so it runs in the page's own world.
    private static func inPage(_ code: String) -> String {
        """
        (() => {
          try {
            window.playprioPolicy = window.playprioPolicy || trustedTypes.createPolicy('playprio', { createScript: (s) => s });
            const script = document.createElement('script');
            script.nonce = [...document.scripts].map((s) => s.nonce).find(Boolean) || '';
            script.textContent = window.playprioPolicy.createScript(\(code));
            document.documentElement.appendChild(script);
            script.remove();
            return 'ok';
          } catch (error) {
            return 'failed: ' + error;
          }
        })()
        """
    }

    /// What every request starts with: `api(endpoint, body)` for YouTube Music's API (with the
    /// page's client version and language, signed in like the page), and helpers for its
    /// answers.
    private static let apiJS = #"""
    const config = [...document.scripts].map((s) => s.textContent).find((t) => t.includes('INNERTUBE_CLIENT_VERSION')) || '';
    const setting = (name) => (config.match(new RegExp(`"${name}":"([^"]+)"`)) || [])[1];
    const cookie = (name) => (document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]+)`)) || [])[1];
    const sha1Hex = async (text) => [...new Uint8Array(await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text)))]
      .map((byte) => byte.toString(16).padStart(2, '0')).join('');
    const api = async (endpoint, body) => {
      const headers = { 'Content-Type': 'application/json' };
      const sapisid = cookie('SAPISID') || cookie('__Secure-3PAPISID');
      if (sapisid) {
        const time = Math.floor(Date.now() / 1000);
        headers.Authorization = `SAPISIDHASH ${time}_${await sha1Hex(`${time} ${sapisid} ${location.origin}`)}`;
        headers['X-Goog-AuthUser'] = setting('SESSION_INDEX') || '0';
        headers['X-Origin'] = location.origin;
      }
      const response = await fetch(`/youtubei/v1/${endpoint}?prettyPrint=false`, { method: 'POST', headers, credentials: 'include',
        body: JSON.stringify({ ...body, context: { client: {
          clientName: 'WEB_REMIX', clientVersion: setting('INNERTUBE_CLIENT_VERSION'), hl: setting('HL'), gl: setting('GL') } } }) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    };
    const find = (node, key) => {
      if (!node || typeof node !== 'object') return undefined;
      if (key in node) return node[key];
      for (const value of Object.values(node)) { const found = find(value, key); if (found !== undefined) return found; }
      return undefined;
    };
    const all = (node, key, out = []) => {
      if (!node || typeof node !== 'object') return out;
      for (const [k, value] of Object.entries(node)) { if (k === key) out.push(value); else all(value, key, out); }
      return out;
    };
    const text = (value) => ((value && value.runs) || []).map((run) => run.text).join('');
    // A list row's text columns: title, then artist/album/plays and the like.
    const column = (row, n) => row.flexColumns?.[n]?.musicResponsiveListItemFlexColumnRenderer?.text;
    // Square covers: Google's images at the size asked for; videos' 16:9 thumbnails, as the
    // 4:3 ones have black bars baked in.
    const picture = (thumbnails, size) => {
      const src = ((thumbnails || [])[(thumbnails || []).length - 1] || {}).url || '';
      const video = /^https:\/\/i\.ytimg\.com\/vi(?:_webp)?\/([\w-]{11})\//.exec(src);
      if (video) return `https://i.ytimg.com/vi/${video[1]}/${size > 200 ? 'hq720' : 'mqdefault'}.jpg`;
      return src.replace(/=w\d+-h\d+[^/]*$/, `=w${size}-h${size}-l90-rj`);
    };
    const watchID = (watch) => `watch?v=${watch.videoId}` + (watch.playlistId ? `&list=${watch.playlistId}` : '');
    // A tile (albums, playlists, mixes, songs); artists and podcasts are left out.
    const fromTile = (tile) => {
      const nav = tile.navigationEndpoint || {};
      const parts = text(tile.subtitle).split(' • ');
      const image = picture(find(tile.thumbnailRenderer, 'thumbnails'), 300);
      if (nav.watchEndpoint) return { id: watchID(nav.watchEndpoint), title: text(tile.title), subtitle: parts.slice(-1)[0] || '', image, badge: '' };
      const type = find(nav, 'pageType') || '';
      if (nav.browseEndpoint && /ALBUM|PLAYLIST/.test(type)) {
        // An album's subtitle starts with its kind ("Album", "Single", "EP"); a playlist's with
        // whoever made it, so that one just says "Playlist".
        const album = /ALBUM/.test(type);
        return { id: `browse/${nav.browseEndpoint.browseId}`, title: text(tile.title),
                 badge: album ? (parts.length > 1 ? parts[0] : '') : 'Playlist',
                 subtitle: album && parts.length > 1 ? parts.slice(1).join(' • ') : parts.join(' • '), image };
      }
      return null;
    };
    // A song row (Quick picks).
    const fromRow = (row) => {
      const watch = find(row.overlay, 'watchEndpoint') || find(column(row, 0), 'watchEndpoint');
      if (!watch || !watch.videoId) return null;
      return { id: watchID(watch), title: text(column(row, 0)), subtitle: text(column(row, 1)).split(' • ')[0], badge: '',
               image: picture(find(row.thumbnail, 'thumbnails'), 300) };
    };
    """#

    /// The home page, paged through as YouTube Music does while scrolling, and the user's own
    /// playlists ("Liked music" among them).
    private static let homeJS = #"""
    const shelves = [];
    let page = await api('browse', { browseId: 'FEmusic_home' });
    for (let round = 0; round < 5 && page; round++) {
      for (const shelf of all(page, 'musicCarouselShelfRenderer')) {
        const header = shelf.header?.musicCarouselShelfBasicHeaderRenderer || {};
        const items = (shelf.contents || []).map((entry) => entry.musicTwoRowItemRenderer ? fromTile(entry.musicTwoRowItemRenderer)
          : entry.musicResponsiveListItemRenderer ? fromRow(entry.musicResponsiveListItemRenderer) : null).filter(Boolean).slice(0, 20);
        if (items.length >= 3) shelves.push({ title: text(header.title), strapline: text(header.strapline), items, kind: '' });
      }
      const next = all(page, 'nextContinuationData')[0]?.continuation;
      page = next ? await api('browse', { continuation: next }) : null;
    }
    try {
      const library = await api('browse', { browseId: 'FEmusic_liked_playlists' });
      // "New episodes" is a podcast feed, not music.
      const items = all(library, 'musicTwoRowItemRenderer').map(fromTile).filter((item) => item && item.id !== 'browse/VLRDPN')
        .map((item) => ({ ...item, badge: '' })); // all playlists here
      if (items.length) shelves.push({ title: '', strapline: '', items, kind: 'playlists' });
    } catch {}
    // The user's order: Quick picks, Listen again, their playlists, Albums for you, Forgotten
    // favourites, then the rest as YouTube Music has it.
    const order = [/^(Schnellauswahl|Quick picks)$/i, /^(Noch mal anhören|Listen again)$/i, 'playlists',
                   /^(Alben für dich|Albums for you)$/i, /^(Vergessene Favoriten|Forgotten favou?rites)$/i];
    const rank = (shelf) => {
      const i = order.findIndex((entry) => entry === 'playlists' ? shelf.kind === 'playlists' : entry.test(shelf.title));
      return i < 0 ? order.length : i;
    };
    shelves.sort((a, b) => rank(a) - rank(b));
    return shelves.length ? JSON.stringify({ language: setting('HL') || '', shelves }) : '';
    """#

    /// An album's or playlist's page: header, songs, and the menu's "Shuffle play".
    private static let albumJS = #"""
    const browseId = BROWSE_ID;
    const data = await api('browse', { browseId });
    const header = find(data, 'musicResponsiveHeaderRenderer') || find(data, 'musicDetailHeaderRenderer') || {};
    const shelf = find(data, 'musicShelfRenderer') || find(data, 'musicPlaylistShelfRenderer') || {};
    const items = (shelf.contents || []).map((entry) => entry.musicResponsiveListItemRenderer).filter(Boolean);
    const tracks = items.map((item, i) => {
      return {
        videoId: item.playlistItemData?.videoId || find(item, 'watchEndpoint')?.videoId || '',
        title: text(column(item, 0)), artist: text(column(item, 1)),
        duration: text(item.fixedColumns?.[0]?.musicResponsiveListItemFixedColumnRenderer?.text),
        index: text(item.index) || String(i + 1),
        playable: item.musicItemRendererDisplayPolicy !== 'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT',
      };
    }).filter((track) => track.videoId && track.title);
    const playlistId = (items[0] && find(items[0], 'watchEndpoint')?.playlistId) || find(header, 'watchPlaylistEndpoint')?.playlistId
      || (browseId.startsWith('VL') ? browseId.slice(2) : '');
    const shuffle = (find(header, 'menuRenderer')?.items || []).map((entry) => entry.menuNavigationItemRenderer)
      .find((entry) => entry?.icon?.iconType === 'MUSIC_SHUFFLE')?.navigationEndpoint?.watchPlaylistEndpoint;
    return JSON.stringify({
      title: text(header.title), artist: text(header.straplineTextOne), subtitle: text(header.subtitle),
      image: picture(find(header.thumbnail, 'thumbnails') || find(header, 'thumbnails'), 544), playlistId,
      // Without a menu entry of its own (Liked music, say) the usual shuffle parameters do.
      shuffleParams: (shuffle && shuffle.playlistId === playlistId && shuffle.params) || (playlistId ? 'wAEB8gECKAE%3D' : ''),
      artistId: (header.straplineTextOne?.runs || []).map((run) => run.navigationEndpoint?.browseEndpoint?.browseId).find((id) => /^UC/.test(id || '')) || '',
      tracks });
    """#

    /// An artist's page: header, top songs ("Titel"), and the shelves of albums, singles,
    /// videos and playlists (other artists left out).
    private static let artistJS = #"""
    const data = await api('browse', { browseId: BROWSE_ID });
    const header = find(data, 'musicImmersiveHeaderRenderer') || find(data, 'musicVisualHeaderRenderer') || find(data, 'musicResponsiveHeaderRenderer') || {};
    const thumbnails = find(header.thumbnail, 'thumbnails') || [];
    const start = (button) => {
      const watch = find(button, 'watchEndpoint');
      return watch && watch.videoId ? { videoId: watch.videoId, playlistId: watch.playlistId || '', params: watch.params || 'wAEB' } : null;
    };
    // Some artists have no buttons in the header, only the same two entries in its menu.
    const menu = (find(header.menu, 'items') || []).map((entry) => entry.menuNavigationItemRenderer).filter(Boolean);
    const fromMenu = (icon) => {
      const nav = menu.find((entry) => entry.icon?.iconType === icon)?.navigationEndpoint || {};
      const watch = nav.watchEndpoint || nav.watchPlaylistEndpoint;
      return watch && watch.playlistId ? { videoId: watch.videoId || '', playlistId: watch.playlistId, params: watch.params || 'wAEB' } : null;
    };
    // The page shows five top songs; behind "Show all" is a playlist with all of them.
    const songShelf = find(data, 'musicShelfRenderer') || {};
    const allSongs = find(songShelf.bottomEndpoint, 'browseId') || find(songShelf.title, 'browseId') || '';
    const songRows = (shelf) => (shelf?.contents || []).map((entry) => entry.musicResponsiveListItemRenderer).filter(Boolean).map((row) => {
      const item = fromRow(row);
      return item && { ...item, subtitle: text(column(row, 2)) || item.subtitle };
    }).filter(Boolean);
    let songs = songRows(songShelf);
    if (allSongs.startsWith('VL')) {
      try {
        const more = songRows(find(await api('browse', { browseId: allSongs }), 'musicPlaylistShelfRenderer'));
        if (more.length > songs.length) songs = more;
      } catch {}
    }
    songs = songs.slice(0, 20);
    const shelves = all(data, 'musicCarouselShelfRenderer').map((shelf) => ({
      title: text(shelf.header?.musicCarouselShelfBasicHeaderRenderer?.title), strapline: '', kind: '',
      items: (shelf.contents || []).map((entry) => entry.musicTwoRowItemRenderer && fromTile(entry.musicTwoRowItemRenderer)).filter(Boolean) }))
      .filter((shelf) => shelf.items.length);
    return JSON.stringify({ name: text(header.title), image: ((thumbnails[thumbnails.length - 1] || {}).url || ''),
      shuffle: start(header.playButton) || fromMenu('MUSIC_SHUFFLE'), radio: start(header.startRadioButton) || fromMenu('MIX'), songs,
      allSongsId: allSongs.startsWith('VL') ? `browse/${allSongs}` : '', shelves });
    """#

    /// The player bar: its repeat mode (an attribute, so no language involved) and the byline's
    /// link to the playing song's artist.
    private static let playerInfoJS = #"""
    (() => {
      const bar = document.querySelector('ytmusic-player-bar');
      if (!bar) return '';
      const links = [...bar.querySelectorAll('.byline a')].map((a) => a.getAttribute('href') || '');
      const id = (prefix) => (links.find((href) => href.startsWith(prefix)) || '').slice(prefix.length);
      return JSON.stringify({ repeatMode: bar.getAttribute('repeat-mode') || 'NONE', artistId: id('channel/') });
    })()
    """#

    /// YouTube Music's search answers with one flat list of everything (artists, profiles and
    /// podcast episodes too); the songs and music videos are kept, and its playlists. Albums
    /// hardly show up there, so they come from its own "Albums" filter, asked at the same time.
    private static let searchJS = #"""
    const [data, albumData] = await Promise.all([api('search', { query: QUERY }),
      api('search', { query: QUERY, params: 'EgWKAQIYAWoMEA4QChADEAQQCRAF' }).catch(() => ({}))]);
    // The top result is a card ("Kaneko Ayano" with three songs) whose songs don't name the artist.
    const cardTitles = new Map();
    for (const card of all(data, 'musicCardShelfRenderer')) {
      for (const entry of card.contents || []) if (entry.musicResponsiveListItemRenderer) cardTitles.set(entry.musicResponsiveListItemRenderer, text(card.title));
    }
    const songs = [], albums = [];
    for (const item of [...all(albumData, 'musicResponsiveListItemRenderer'), ...all(data, 'musicResponsiveListItemRenderer')]) {
      const title = text(column(item, 0));
      const parts = text(column(item, 1)).split(' • ');
      const artists = (column(item, 1)?.runs || []).filter((run) => /ARTIST/.test(find(run.navigationEndpoint, 'pageType') || '')).map((run) => run.text);
      const byline = artists.length ? artists.join(', ')
        : parts.slice(1).filter((p) => !/^\d+:\d\d$|\d.*(Aufrufe|views|Wiedergaben|plays)/i.test(p)).join(' • ') || cardTitles.get(item) || '';
      const watch = find(item.overlay, 'watchEndpoint') || find(column(item, 0), 'watchEndpoint');
      const browse = item.navigationEndpoint?.browseEndpoint;
      // Albums first: their rows carry a play button with the first song too.
      if (browse && /ALBUM|PLAYLIST/.test(find(browse, 'pageType') || '')) {
        albums.push({ id: `browse/${browse.browseId}`, title, subtitle: byline, badge: parts.length > 1 ? parts[0] : '',
                      image: picture(find(item.thumbnail, 'thumbnails'), 300) });
      } else if (watch?.videoId && !/PODCAST/.test(find(watch, 'musicVideoType') || '')) {
        songs.push({ id: watchID(watch), title, subtitle: byline, image: picture(find(item.thumbnail, 'thumbnails'), 120), badge: '' });
      }
    }
    const unique = (list) => list.filter((item, i) => list.findIndex((other) => other.id === item.id) === i).slice(0, 12);
    return JSON.stringify({ songs: unique(songs), albums: unique(albums) });
    """#

    /// The fallback for an album whose page couldn't be read: its own play button on the home
    /// page, which YouTube Music only draws once the tile has been on screen.
    private static let pressJS = #"""
    ((id) => {
      const item = [...document.querySelectorAll('ytmusic-carousel-shelf-renderer #items > *')]
        .find((element) => [...element.querySelectorAll('a[href]')].some((a) => a.getAttribute('href') === id));
      if (!item) return '';
      const button = item.querySelector('ytmusic-play-button-renderer');
      if (button) { button.click(); return 'pressed'; }
      item.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      let tries = 0;
      const wait = setInterval(() => {
        const drawn = item.querySelector('ytmusic-play-button-renderer');
        if (drawn) drawn.click();
        if (drawn || ++tries > 30) clearInterval(wait);
      }, 100);
      return 'scrolled';
    })(ITEM_ID)
    """#
}
