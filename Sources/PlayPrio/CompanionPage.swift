import Foundation

/// The iPhone remote's web page and the silence it plays (see `Companion`).
enum CompanionPage {
    /// Where the page loads its silence from. A new name whenever the file changes, as
    /// Safari keeps it for a day.
    static let silencePath = "/silence-12h.wav"
    static let noCoverPath = "/artwork/none.png"

    /// Twelve hours of silence as 8 kHz, 16-bit mono WAV. iOS only shows a page in Now
    /// Playing while it plays media longer than about a second, and it shouldn't loop: at
    /// every restart iOS briefly shows the silence's own position and length instead of the
    /// song's. Too big to keep, so each requested piece is made up on the spot.
    static func silence(for request: CompanionServer.Request) -> CompanionServer.Response {
        let size = silenceHeader.count + silenceDataSize
        var headers = ["Content-Type": "audio/wav", "Accept-Ranges": "bytes", "Cache-Control": "max-age=86400"]
        // Safari asks for ranges; anything else gets the start, as a range too.
        guard let requested = request.headers["range"].map({ CompanionServer.Response.byteRange($0, size: size) })
                ?? 0...(size - 1) else {
            headers["Content-Range"] = "bytes */\(size)"
            return CompanionServer.Response(status: 416, headers: headers)
        }
        let range = requested.lowerBound...min(requested.upperBound, requested.lowerBound + silenceChunk - 1)
        var body = Data(count: range.count) // zeros: silence
        if range.lowerBound < silenceHeader.count {
            let header = silenceHeader[range.lowerBound...min(range.upperBound, silenceHeader.count - 1)]
            body.replaceSubrange(0..<header.count, with: header)
        }
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        return CompanionServer.Response(status: 206, headers: headers, body: body)
    }

    private static let silenceDataSize = 8000 * 2 * 12 * 3600
    /// At most about a minute of audio per request; Safari asks again for more.
    private static let silenceChunk = 1 << 20

    private static let silenceHeader: Data = {
        let sampleRate: UInt32 = 8000, dataSize = UInt32(silenceDataSize)
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + dataSize); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataSize)
        return wav
    }()

    /// Upright it's laid out like Apple Music: the player, then search and YouTube Music's
    /// shelves to scroll down to, and albums as pages of their own. Sideways the player looks
    /// like the StandBy one.
    ///
    /// Plain http on the local network isn't a secure context, so there's no WebCrypto:
    /// the page brings its own SHA-256 for signing requests.
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="dark">
    <meta name="theme-color" content="#000000">
    <meta name="apple-mobile-web-app-title" content="PlayPrio">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <link rel="icon" type="image/png" href="/apple-touch-icon.png">
    <title>PlayPrio</title>
    <style>
    :root {
      --accent: #ff6600;
      --text-2: rgba(255,255,255,.62);
      --text-3: rgba(255,255,255,.38);
      --fill: rgba(255,255,255,.16);
      --fill-2: rgba(255,255,255,.10);
      --hairline: rgba(255,255,255,.12);
      --placeholder: linear-gradient(150deg, rgba(255,255,255,.16), rgba(255,255,255,.05));
      --bar: rgba(18,18,20,.62);
      --pad: max(20px, env(safe-area-inset-left));
      --ease: cubic-bezier(.2,.8,.2,1);
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html { background: #000; }
    html, body { overflow-x: clip; }
    body { margin: 0; color: #fff; font: 17px/1.3 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased; overscroll-behavior-y: none; }
    button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; text-align: inherit;
      transition: transform .14s ease, opacity .14s ease; }
    button:disabled { opacity: .3; cursor: default; }
    button:active:not(:disabled) { transform: scale(.96); }
    svg { display: block; fill: currentColor; }
    img { display: block; }
    h2 { margin: 0 0 12px; font-size: 22px; font-weight: 700; }
    .line { display: block; max-width: 100%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .caption { font-size: 13px; color: var(--text-2); }
    .note { padding: 28px 0; text-align: center; font-size: 14px; color: var(--text-2); }
    .fade { opacity: 0; transition: opacity .3s ease; }
    .fade.loaded { opacity: 1; }
    .appear { animation: appear .45s var(--ease) both; }
    @keyframes appear { from { opacity: 0; transform: translateY(10px); } }

    /* Background: the cover, blurred; two layers so a new one fades in over the old. */
    #backdrop { position: fixed; inset: -20%; z-index: -1; background: radial-gradient(80% 55% at 50% 32%, #2c2c31, #0c0c0e 75%); }
    #backdrop .layer { position: absolute; inset: 0; background: center / cover no-repeat; opacity: 0; transition: opacity .9s ease;
      filter: blur(80px) saturate(1.7) brightness(.5); transform: translateZ(0); }
    #backdrop .layer.on { opacity: 1; }

    /* Player */
    #player { position: relative; min-height: calc(100svh - 56px); display: flex; flex-direction: column; justify-content: center; gap: 26px;
      padding: max(12px, env(safe-area-inset-top)) var(--pad) 10px; }
    #route { display: flex; align-items: center; justify-content: center; gap: 6px; margin-top: 18px; font-size: 12px; color: var(--text-3); }
    #route svg { flex: none; width: 15px; height: 15px; }
    #route.offline, #route.unpaired { color: var(--accent); }
    #art { position: relative; overflow: hidden; flex: none; width: min(100%, 46svh); aspect-ratio: 1; align-self: center; border-radius: 12px;
      display: grid; place-items: center; background: var(--placeholder); box-shadow: 0 24px 60px rgba(0,0,0,.45);
      transition: transform .55s cubic-bezier(.3,1.25,.5,1), box-shadow .55s ease; }
    body.paused #art { transform: scale(.85); box-shadow: 0 10px 30px rgba(0,0,0,.3); }
    #art svg { width: 24%; fill: rgba(255,255,255,.26); }
    #art.cover svg { display: none; }
    #art .layer { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; transition: opacity .45s ease; }
    #art .layer.on { opacity: 1; }
    #info { display: flex; flex-direction: column; min-width: 0; }
    #title { font-size: 22px; font-weight: 600; }
    #artist { min-height: 1.3em; font-size: 20px; color: var(--text-2); }
    #title, #artist { transition: opacity .18s ease, transform .18s ease; }
    .swap { opacity: 0; transform: translateY(4px); }
    #progress { margin-top: 22px; }
    #progress.seekable { cursor: pointer; touch-action: none; }
    #bar { height: 6px; border-radius: 3px; background: var(--fill); overflow: hidden; transition: height .15s ease; }
    #progress.scrubbing #bar { height: 10px; }
    #fill { height: 100%; width: 0; background: rgba(255,255,255,.85); transition: width .5s linear; }
    #progress.scrubbing #fill, #fill.instant { transition: none; }
    #times { display: flex; justify-content: space-between; margin-top: 7px; font-size: 12px; font-weight: 600;
      color: var(--text-3); font-variant-numeric: tabular-nums; }
    #controls { display: flex; align-items: center; justify-content: space-evenly; margin-top: 18px; }
    #controls button { padding: 8px; }
    #controls button:active:not(:disabled) { transform: scale(.88); opacity: .7; }
    #prev svg, #next svg { width: 40px; height: 40px; }
    #toggle svg { width: 48px; height: 48px; }
    #toggle.pop svg { animation: pop .28s ease; }
    @keyframes pop { from { transform: scale(.7); opacity: .4; } }
    #artist.link { cursor: pointer; }
    #artist.link:active { opacity: .55; }
    .stroke { fill: none; stroke: currentColor; stroke-width: 2.1; stroke-linecap: round; stroke-linejoin: round; }

    /* The Mac's volume as Apple Music draws it: a slim bar, no knob, a little thicker while
       touched. Shuffle and repeat sit small at the ends of the controls, as at Spotify. */
    #volume { display: flex; align-items: center; gap: 12px; margin-top: 22px; color: var(--text-3); touch-action: none; cursor: pointer; }
    #volume svg { flex: none; width: 14px; height: 14px; }
    #volume svg.loud { width: 20px; height: 20px; }
    #volumeBar { flex: 1; height: 5px; border-radius: 3px; background: var(--fill); overflow: hidden; transition: height .15s ease; }
    #volume.dragging #volumeBar { height: 9px; }
    #volumeFill { height: 100%; width: 50%; background: rgba(255,255,255,.75); }
    #controls .side { position: relative; color: var(--text-3); }
    #controls .side svg { width: 21px; height: 21px; }
    #controls .side.on { color: var(--accent); }
    #repeat.one::after { content: '1'; position: absolute; top: 4px; right: 3px; font: 700 9px/1 -apple-system, system-ui, sans-serif; }
    .hidden { display: none !important; }

    /* The mini player opens the big one as a sheet over wherever you are, like Apple Music;
       a swipe down puts it away again. */
    body.in-album:not(.player-open) #player { display: none; }
    body.player-open #player { position: fixed; inset: 0; z-index: 8; height: 100svh; min-height: 0; overflow-y: auto; overscroll-behavior: contain;
      padding-top: max(36px, calc(env(safe-area-inset-top) + 26px)); animation: sheet .42s var(--ease); }
    body.player-open { overflow: hidden; }
    body.player-open #backdrop { z-index: 7; }
    body.player-open #mini { transform: translateY(calc(100% + 40px)); }
    @keyframes sheet { from { transform: translateY(100%); } }
    #grab { display: none; }
    body.player-open #grab { display: block; position: absolute; top: max(4px, env(safe-area-inset-top)); left: 50%; width: 90px; height: 26px;
      margin-left: -45px; padding: 0; }
    #grab::before { content: ''; display: block; width: 38px; height: 5px; margin: 10px auto 0; border-radius: 3px; background: rgba(255,255,255,.4); }
    #playerSpacer { display: none; }

    #start { display: flex; flex-direction: column; align-items: center; gap: 10px; margin-top: 18px; text-align: center; }
    #startButton { padding: 12px 44px; border-radius: 99px; background: var(--accent); color: #000; font-weight: 600; }
    #hint { margin: 0; max-width: 420px; }
    body.started #start { display: none; }

    /* Search: the field sticks to the top while there are results, beside a Cancel button. */
    #search { position: relative; }
    .searchbar { position: sticky; top: 0; z-index: 2; display: flex; align-items: center; gap: 12px;
      padding: 10px var(--pad); transition: background .2s ease; }
    body.searching .searchbar { padding-top: max(10px, env(safe-area-inset-top)); background: var(--bar);
      -webkit-backdrop-filter: blur(24px) saturate(1.6); backdrop-filter: blur(24px) saturate(1.6); }
    .field { flex: 1; display: flex; align-items: center; gap: 8px; height: 38px; padding: 0 11px; border-radius: 11px;
      background: var(--fill); color: var(--text-2); }
    .field svg { flex: none; width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 2.4; stroke-linecap: round; }
    .field input { flex: 1; min-width: 0; height: 100%; border: 0; outline: 0; background: none; color: #fff;
      font: 17px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; -webkit-appearance: none; appearance: none; }
    .field input::placeholder { color: var(--text-2); }
    #cancel { display: none; color: var(--accent); }
    body.search-focus #cancel, body.searching #cancel { display: block; }
    #results { padding: 0 var(--pad); }
    body.searching #results { min-height: calc(100svh - 58px); padding-bottom: 30px; }
    body.searching #library, body.searching #others { display: none; }

    /* Shelves */
    #library, #others { padding: 0 var(--pad); }
    #others { padding-bottom: max(30px, env(safe-area-inset-bottom)); }
    .shelf { margin-top: 26px; }
    .strapline { display: block; margin-bottom: 1px; font-size: 12px; font-weight: 500; letter-spacing: .05em; text-transform: uppercase; color: var(--text-2); }
    .pager, .strip { display: grid; grid-auto-flow: column; gap: 8px; overflow-x: auto; scrollbar-width: none;
      margin: 0 calc(-1 * var(--pad)); padding: 0 var(--pad); scroll-padding: 0 var(--pad); }
    .pager::-webkit-scrollbar, .strip::-webkit-scrollbar { display: none; }
    .pager { grid-template-rows: repeat(3, auto); grid-auto-columns: calc((100% - 16px) / 3); scroll-snap-type: x mandatory; }
    .pager > :nth-child(9n+1) { scroll-snap-align: start; }
    .strip { grid-auto-columns: calc((100% - 16px) / 2.5); scroll-snap-type: x proximity; }
    .strip > * { scroll-snap-align: start; }
    .dots { display: flex; justify-content: center; gap: 7px; margin-top: 12px; }
    .dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--text-3); transition: background .2s ease; }
    .dots i.on { background: #fff; }
    .tile { position: relative; aspect-ratio: 1; border-radius: 8px; overflow: hidden; background: var(--placeholder); }
    .tile img { width: 100%; height: 100%; object-fit: cover; }
    .tile span { position: absolute; left: 0; right: 0; bottom: 0; padding: 20px 8px 7px; font-size: 13px; font-weight: 600;
      background: linear-gradient(transparent, rgba(0,0,0,.72)); }
    .tile em { position: absolute; top: 6px; right: 6px; padding: 2px 6px; border-radius: 5px; font: 600 10px/1.3 -apple-system, system-ui, sans-serif;
      background: rgba(0,0,0,.55); -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px); }
    .pending { opacity: .4; }

    /* Rows: songs in search results, other sources */
    .row { display: flex; align-items: center; gap: 12px; width: 100%; padding: 6px 0; text-align: left; }
    button.row:active:not(:disabled) { transform: none; opacity: .55; }
    .row > div { flex: 1; min-width: 0; }
    .row b { font-size: 16px; font-weight: 400; }
    .row small { font-size: 14px; color: var(--text-2); }
    .row > button svg { width: 26px; height: 26px; }
    .thumb { flex: none; width: 50px; height: 50px; border-radius: 6px; overflow: hidden; background: var(--placeholder); }
    .thumb img { width: 100%; height: 100%; object-fit: cover; }

    /* An album or playlist, as a page of its own (the swipe back works too). */
    #albumView { display: none; min-height: 100svh; }
    body.in-album #home { display: none; }
    body.in-album #albumView { display: block; animation: push .35s var(--ease); }
    @keyframes push { from { opacity: 0; transform: translateX(28px); } }
    #back { position: fixed; z-index: 3; top: max(10px, env(safe-area-inset-top)); left: max(14px, env(safe-area-inset-left));
      display: grid; place-items: center; width: 38px; height: 38px; border-radius: 50%; color: #fff;
      background: rgba(44,44,48,.55); -webkit-backdrop-filter: blur(20px) saturate(1.6); backdrop-filter: blur(20px) saturate(1.6); }
    #back svg { width: 20px; height: 20px; margin-left: -2px; fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; }
    .album { padding: max(56px, calc(env(safe-area-inset-top) + 50px)) var(--pad) max(30px, env(safe-area-inset-bottom)); text-align: center; }
    .album .retry { margin-top: 4px; color: var(--accent); font-weight: 600; }
    .album .shelf .retry { display: block; margin-top: 10px; }
    #update { position: fixed; z-index: 5; top: max(10px, env(safe-area-inset-top)); left: 50%; transform: translateX(-50%);
      display: none; padding: 8px 16px; border-radius: 99px; font-size: 14px; white-space: nowrap;
      background: rgba(44,44,48,.75); -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px); }
    #update b { color: var(--accent); font-weight: 600; }
    body.outdated #update { display: block; animation: appear .35s var(--ease) both; }
    .album .cover { width: min(66vw, 280px, 46svh); aspect-ratio: 1; margin: 6px auto 18px; border-radius: 10px; overflow: hidden;
      background: var(--placeholder); box-shadow: 0 16px 40px rgba(0,0,0,.4); }
    .album .cover img { width: 100%; height: 100%; object-fit: cover; }
    .album h1 { margin: 0; font-size: 22px; font-weight: 700; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .album .by { margin-top: 2px; font-size: 20px; color: var(--accent); }
    .album .caption { margin-top: 4px; }
    .actions { display: flex; gap: 12px; max-width: 380px; margin: 20px auto 8px; }
    .actions button { flex: 1; display: flex; align-items: center; justify-content: center; gap: 7px; padding: 12px;
      border-radius: 12px; background: var(--fill); color: var(--accent); font-weight: 600; }
    .actions svg { width: 15px; height: 15px; }
    .actions .shuffle svg { width: 18px; height: 18px; }
    .tracks { margin-top: 10px; text-align: left; }
    .track { display: flex; align-items: center; gap: 14px; width: 100%; padding: 11px 0; border-bottom: .5px solid var(--hairline); }
    .track:active:not(:disabled) { transform: none; opacity: .55; }
    .track i { flex: none; width: 22px; font-style: normal; font-size: 15px; text-align: center; color: var(--text-2); font-variant-numeric: tabular-nums; }
    .track div { flex: 1; min-width: 0; }
    .track b { font-size: 16px; font-weight: 400; }
    .track small { font-size: 13px; color: var(--text-2); }
    .track time { flex: none; font-size: 14px; color: var(--text-2); font-variant-numeric: tabular-nums; }
    .track.current b, .track.current i { color: var(--accent); }

    /* An artist: a full-width photo with the name on it, like Apple Music. */
    .hero { position: relative; margin: 0 calc(-1 * var(--pad)) 6px; aspect-ratio: 4 / 3; max-height: 62svh; overflow: hidden; background: var(--placeholder); }
    .hero img { width: 100%; height: 100%; object-fit: cover; }
    .hero::after { content: ''; position: absolute; inset: 40% 0 0; background: linear-gradient(transparent, rgba(0,0,0,.65)); }
    .hero h1 { position: absolute; z-index: 1; left: var(--pad); right: var(--pad); bottom: 16px; margin: 0; text-align: left;
      font-size: 32px; font-weight: 800; -webkit-line-clamp: 2; }
    .album.artist { padding-top: 0; }
    .album .shelf { text-align: left; }
    .album .by.link { cursor: pointer; }

    /* Loading: shimmering stand-ins rather than "Loading…". */
    .skeleton { display: block; height: 12px; border-radius: 4px; background: linear-gradient(90deg, var(--fill-2) 25%, var(--fill) 50%, var(--fill-2) 75%);
      background-size: 200% 100%; animation: shimmer 1.3s linear infinite; }
    @keyframes shimmer { to { background-position: -200% 0; } }
    .track i.skeleton { width: 14px; margin: 0 4px; }
    .track div .skeleton { width: 62%; }
    .track time.skeleton { width: 30px; }

    /* The song playing, in a list: three bars bouncing (still while paused). */
    .eq { display: inline-flex; align-items: flex-end; justify-content: center; gap: 2px; height: 13px; }
    .eq span { width: 3px; height: 4px; border-radius: 1px; background: var(--accent); animation: eq .9s ease-in-out infinite alternate; }
    .eq span:nth-child(2) { animation-delay: -.35s; }
    .eq span:nth-child(3) { animation-delay: -.7s; }
    body.paused .eq span { animation-play-state: paused; }
    @keyframes eq { to { height: 13px; } }

    /* A tile's cover flying to its place on the album page. */
    .ghost { position: fixed; z-index: 20; object-fit: cover; transform-origin: 0 0; border-radius: 10px; pointer-events: none;
      box-shadow: 0 16px 40px rgba(0,0,0,.4); }
    body.fly #albumView { animation: fadein .3s ease; }
    @keyframes fadein { from { opacity: 0; } }

    /* Mini player, like Apple Music's, whenever the big one is out of sight. */
    #mini { position: fixed; z-index: 4; left: max(10px, env(safe-area-inset-left)); right: max(10px, env(safe-area-inset-right));
      bottom: max(10px, env(safe-area-inset-bottom)); display: flex; align-items: center; gap: 2px; padding: 7px 6px 7px 7px; border-radius: 18px;
      background: rgba(36,36,40,.72); -webkit-backdrop-filter: blur(30px) saturate(1.8); backdrop-filter: blur(30px) saturate(1.8);
      box-shadow: 0 10px 30px rgba(0,0,0,.35); transform: translateY(calc(100% + 40px)); transition: transform .45s var(--ease); }
    body.mini #mini { transform: none; }
    body.mini #home, body.mini #albumView { padding-bottom: 84px; }
    #miniOpen { flex: 1; min-width: 0; display: flex; align-items: center; gap: 11px; text-align: left; }
    #miniOpen:active:not(:disabled) { transform: none; opacity: .6; }
    #mini .thumb { width: 44px; height: 44px; border-radius: 8px; }
    .mini-text { display: block; min-width: 0; }
    .mini-text b { font-size: 15px; font-weight: 600; }
    .mini-text small { font-size: 13px; color: var(--text-2); }
    #miniToggle, #miniNext { flex: none; padding: 8px; }
    #miniToggle svg { width: 26px; height: 26px; }
    #miniNext svg { width: 28px; height: 28px; }

    /* Sideways, as on a charger in StandBy: a full screen player like Apple's own. */
    @media (orientation: landscape) and (max-height: 600px) {
      :root { --pad: max(44px, env(safe-area-inset-left)); }
      #player { height: 100svh; min-height: 0; flex-direction: row; align-items: center; gap: 6vw;
        padding: max(20px, env(safe-area-inset-top)) max(44px, env(safe-area-inset-right)) max(20px, env(safe-area-inset-bottom)) var(--pad); }
      #route { order: 4; }
      #route:not(.offline):not(.unpaired) { display: none; }
      #art { width: auto; height: min(80svh, 42vw); }
      #info { flex: 1; align-items: center; text-align: center; }
      #title { font-size: 30px; font-weight: 700; }
      #artist { font-size: 24px; }
      #controls { order: 1; width: 100%; max-width: 440px; margin-top: 20px; }
      #progress { order: 2; width: 100%; margin-top: 22px; }
      #start { order: 3; margin-top: 12px; }
      #volume, #controls .side { display: none !important; }
      #bar { height: 8px; border-radius: 4px; }
      #times { font-size: 15px; }
      #prev svg, #next svg { width: 54px; height: 54px; }
      #toggle svg { width: 60px; height: 60px; }
      .pager { grid-template-rows: repeat(2, auto); grid-auto-columns: calc((100% - 40px) / 6); }
      .pager > :nth-child(n) { scroll-snap-align: none; }
      .pager > :nth-child(12n+1) { scroll-snap-align: start; }
      .strip { grid-auto-columns: calc((100% - 32px) / 5); }
      .album .cover { width: min(40vw, 52svh); }
    }
    @media (prefers-reduced-motion: reduce) { *, *::before { transition: none !important; animation: none !important; } }
    </style>
    </head>
    <body class="paused">
    <div id="backdrop"><div class="layer"></div><div class="layer"></div></div>
    <section id="player">
        <button id="grab" aria-label="Close"></button>
        <div id="art"><svg viewBox="0 0 24 24"><path d="M9 17.5V6.6a1 1 0 0 1 .78-.98l9-2A1 1 0 0 1 20 4.6v10.9a2.5 2.5 0 1 1-1.5-2.29V8.1L10.5 9.9v7.6a2.5 2.5 0 1 1-1.5-2.29z"/></svg><img class="layer" alt=""><img class="layer" alt=""></div>
        <div id="info">
          <div id="title" class="line"></div>
          <div id="artist" class="line"></div>
          <div id="progress"><div id="bar"><div id="fill"></div></div><div id="times"><span id="elapsed"></span><span id="remaining"></span></div></div>
          <div id="controls">
            <button id="shuffleQueue" class="side hidden" aria-label="Shuffle"></button>
            <button id="prev" aria-label="Previous"></button>
            <button id="toggle" aria-label="Play or pause"></button>
            <button id="next" aria-label="Next"></button>
            <button id="repeat" class="side hidden" aria-label="Repeat"></button>
          </div>
          <div id="volume" class="hidden" role="slider" aria-label="Volume"><svg viewBox="0 0 24 24"><path d="M4 9.5v5h3.5l4.5 4V5.5l-4.5 4z"/></svg>
            <div id="volumeBar"><div id="volumeFill"></div></div>
            <svg class="loud" viewBox="0 0 24 24"><path d="M3 9.5v5h3.5l4.5 4V5.5l-4.5 4z"/><path class="stroke" d="M15 9a4.5 4.5 0 0 1 0 6M17.8 6.2a8.5 8.5 0 0 1 0 11.6"/></svg></div>
          <div id="route"><svg viewBox="0 0 24 24"><path class="stroke" d="M5 6.5A1.5 1.5 0 0 1 6.5 5h11A1.5 1.5 0 0 1 19 6.5V15H5zM3 18h18"/></svg><span id="routeText" class="line"></span></div>
          <div id="start"><button id="startButton"></button><p id="hint" class="caption"></p></div>
        </div>
    </section>
    <div id="playerSpacer"></div>
    <main id="home">
      <section id="search">
        <div class="searchbar">
          <label class="field"><svg viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L20 20"/></svg>
            <input id="query" type="search" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"></label>
          <button id="cancel"></button>
        </div>
        <div id="results"></div>
      </section>
      <section id="library"></section>
      <section id="others"></section>
    </main>
    <main id="albumView">
      <button id="back" aria-label="Back"><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg></button>
      <div id="albumBody"></div>
    </main>
    <div id="mini">
      <button id="miniOpen"><span class="thumb"><img id="miniArt" alt=""></span><span class="mini-text"><b id="miniTitle" class="line"></b><small id="miniArtist" class="line"></small></span></button>
      <button id="miniToggle" aria-label="Play or pause"></button>
      <button id="miniNext" aria-label="Next"></button>
    </div>
    <button id="update"></button>
    <audio id="silence" src="\#(silencePath)" loop preload="auto" playsinline></audio>
    <script>
    'use strict';

    // <crypto>
    const K = Uint32Array.of(
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));

    function sha256(bytes) {
      const length = ((bytes.length + 9 + 63) >> 6) << 6;
      const padded = new Uint8Array(length);
      padded.set(bytes);
      padded[bytes.length] = 0x80;
      const view = new DataView(padded.buffer);
      view.setUint32(length - 8, Math.floor(bytes.length / 0x20000000));
      view.setUint32(length - 4, (bytes.length * 8) >>> 0);
      const hash = Uint32Array.of(0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19);
      const w = new Uint32Array(64);
      for (let offset = 0; offset < length; offset += 64) {
        for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4);
        for (let i = 16; i < 64; i++) {
          const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
          const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
          w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        let [a, b, c, d, e, f, g, h] = hash;
        for (let i = 0; i < 64; i++) {
          const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) >>> 0;
          const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
          h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
        }
        hash[0] += a; hash[1] += b; hash[2] += c; hash[3] += d; hash[4] += e; hash[5] += f; hash[6] += g; hash[7] += h;
      }
      const out = new Uint8Array(32);
      const outView = new DataView(out.buffer);
      hash.forEach((word, i) => outView.setUint32(i * 4, word));
      return out;
    }

    function hmacSHA256(key, message) {
      const block = new Uint8Array(64);
      block.set(key.length > 64 ? sha256(key) : key);
      const inner = new Uint8Array(64 + message.length);
      const outer = new Uint8Array(64 + 32);
      for (let i = 0; i < 64; i++) { inner[i] = block[i] ^ 0x36; outer[i] = block[i] ^ 0x5c; }
      inner.set(message, 64);
      outer.set(sha256(inner), 64);
      return sha256(outer);
    }

    const hex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
    // </crypto>

    const $ = (id) => document.getElementById(id);
    const audio = $('silence');
    const encoder = new TextEncoder();
    const ICON = {
      play: '<svg viewBox="0 0 24 24"><path d="M7 4.8v14.4a1 1 0 0 0 1.52.85l11.5-7.2a1 1 0 0 0 0-1.7L8.52 3.95A1 1 0 0 0 7 4.8z"/></svg>',
      pause: '<svg viewBox="0 0 24 24"><rect x="5.5" y="4" width="4.6" height="16" rx="1.3"/><rect x="13.9" y="4" width="4.6" height="16" rx="1.3"/></svg>',
      next: '<svg viewBox="0 0 24 24"><path d="M2 6.3v11.4a.8.8 0 0 0 1.22.68L11.5 13.3v4.4a.8.8 0 0 0 1.22.68l9-5.7a.8.8 0 0 0 0-1.36l-9-5.7a.8.8 0 0 0-1.22.68v4.4L3.22 5.62A.8.8 0 0 0 2 6.3z"/></svg>',
      repeat: '<svg viewBox="0 0 24 24"><path class="stroke" d="M17 3l3 3-3 3M4 11V9.5A3.5 3.5 0 0 1 7.5 6H20M7 21l-3-3 3-3M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H4"/></svg>',
      shuffle: '<svg viewBox="0 0 24 24"><path class="stroke" d="M3 7h3.5c2 0 3.2.9 4.3 2.6l2.4 4.8c1.1 1.7 2.3 2.6 4.3 2.6H21M3 17h3.5c1.3 0 2.2-.4 3-1.1M14.2 8.1c.8-.7 1.7-1.1 3-1.1H21M18 4l3 3-3 3M18 14l3 3-3 3"/></svg>',
    };
    ICON.previous = ICON.next.replace('<svg ', '<svg style="transform: scaleX(-1)" ');

    const STRINGS = {
      de: {
        topSongs: 'Top-Titel', showAll: 'Alle anzeigen', mix: 'Mix', notPlaying: 'Keine Wiedergabe', start: 'Starten', hint: 'Danach iPhone sperren oder quer aufs Ladegerät legen.',
        others: 'Weitere Quellen', play: 'Abspielen', shuffle: 'Zufällig',
        noTracks: 'Die Titel konnten nicht geladen werden.', retry: 'Erneut versuchen',
        update: 'Neue Version', reload: 'Aktualisieren',
        search: 'Suchen', cancel: 'Abbrechen', searching: 'Sucht …', noResults: 'Keine Treffer',
        searchFailed: 'Die Suche hat nicht geklappt.', songs: 'Titel', albums: 'Alben und Playlists', playlists: 'Deine Playlists',
        offline: 'Mac nicht erreichbar', unpaired: 'Nicht gekoppelt: Code in den PlayPrio-Einstellungen am Mac scannen',
        failed: 'Konnte nicht starten', connecting: 'Verbinde …',
      },
      en: {
        topSongs: 'Top songs', showAll: 'Show all', mix: 'Mix', notPlaying: 'Not Playing', start: 'Start', hint: 'Then lock your iPhone or put it in StandBy.',
        others: 'Other sources', play: 'Play', shuffle: 'Shuffle',
        noTracks: 'Couldn’t load the songs.', retry: 'Try again',
        update: 'New version', reload: 'Reload',
        search: 'Search', cancel: 'Cancel', searching: 'Searching…', noResults: 'No results',
        searchFailed: 'The search didn’t work.', songs: 'Songs', albums: 'Albums and playlists', playlists: 'Your playlists',
        offline: 'Mac not reachable', unpaired: 'Not paired: scan the code in PlayPrio’s settings on your Mac',
        failed: 'Couldn’t start', connecting: 'Connecting…',
      },
    };

    // The page speaks YouTube Music's language, as most of what it shows is YouTube Music's own
    // words. Until the Mac has said which, the last one it said, or else the iPhone's.
    const languageOf = (code) => (/^de\b/i.test(code || '') ? 'de' : 'en');
    let language = 'en';
    try { language = languageOf(localStorage.getItem('playprio.language') || navigator.language); } catch {}
    let T = STRINGS[language];
    function useLanguage(code) {
      if (!code || languageOf(code) === language) return;
      language = languageOf(code);
      T = STRINGS[language];
      try { localStorage.setItem('playprio.language', language); } catch {}
      showLabels();
      if (state) render(); else setText('title', T.notPlaying);
    }

    // The key arrives in the address's "#" part (from the QR code) and is kept for later visits.
    let key = new URLSearchParams(location.hash.slice(1)).get('k') || '';
    try {
      if (key) localStorage.setItem('playprio.key', key);
      else key = localStorage.getItem('playprio.key') || '';
    } catch {}

    let state = null, rev = -1, receivedAt = 0, clockOffset = null, connection = 'connecting';
    let started = false, positionSource = null, poll = null, kicked = false;
    let library = [], libraryAt = 0;

    function element(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text != null) node.textContent = text;
      return node;
    }

    // MARK: Talking to the Mac

    async function signedFetch(method, target, body, signal) {
      const text = body ? JSON.stringify(body) : '';
      const time = String(Math.round(Date.now() / 1000 + (clockOffset || 0)));
      const nonce = hex(crypto.getRandomValues(new Uint8Array(16)));
      const signature = hex(hmacSHA256(encoder.encode(key), encoder.encode(`${method}\n${target}\n${time}\n${nonce}\n${text}`)));
      const headers = { 'X-PlayPrio-Time': time, 'X-PlayPrio-Nonce': nonce, 'X-PlayPrio-Signature': signature };
      if (body) headers['Content-Type'] = 'application/json';
      const response = await fetch(target, { method, headers, body: body ? text : undefined, cache: 'no-store', signal });
      if (response.status === 401) throw Object.assign(new Error('not paired'), { unpaired: true });
      if (!response.ok) throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status });
      return response.json();
    }

    function send(action, extra) {
      signedFetch('POST', '/api/command', { action, ...extra }).catch((error) => {
        if (error.status && !error.unpaired) return; // refused (nothing to seek in, say), not unreachable
        connection = error.unpaired ? 'unpaired' : 'offline';
        renderRoute();
      });
    }

    // Long poll: the Mac answers as soon as something changes (or after 25 s).
    async function pollLoop() {
      let delay = 1000;
      for (;;) {
        poll = new AbortController();
        const timeout = setTimeout(() => poll.abort(), 35000);
        try {
          if (clockOffset === null) {
            const hello = await (await fetch('/api/hello', { cache: 'no-store', signal: poll.signal })).json();
            clockOffset = hello.time - Date.now() / 1000;
          }
          const next = await signedFetch('GET', `/api/state?since=${rev}`, null, poll.signal);
          connection = 'ok';
          apply(next);
          if (!libraryAt) loadLibrary();
          delay = 1000;
        } catch (error) {
          if (kicked) { kicked = false; continue; }
          clockOffset = null;
          connection = error.unpaired ? 'unpaired' : 'offline';
          renderRoute();
          await new Promise((resolve) => { wake = resolve; setTimeout(resolve, delay); });
          wake = null;
          delay = Math.min(delay * 2, 15000);
        } finally {
          clearTimeout(timeout);
        }
      }
    }

    // Back in front: don't wait for a long poll that may have gone stale in the background,
    // nor out the pause before trying again.
    let wake = null;
    function kick() {
      if (wake) return wake();
      if (poll && !poll.signal.aborted) { kicked = true; poll.abort(); }
    }

    // PlayPrio restarted (a new build): offer the new page rather than reloading by itself,
    // which would stop the silence and with it iOS's Now Playing.
    const PAGE = '__PAGE_VERSION__';
    function apply(next) {
      if (next.page && next.page !== PAGE) document.body.classList.add('outdated');
      state = next;
      rev = next.rev;
      receivedAt = performance.now();
      render();
      syncNowPlaying();
    }

    // MARK: Player

    // Seconds into the track right now.
    function position(item) {
      if (!item || item.position == null) return null;
      const elapsed = item.state === 'playing' ? (performance.now() - receivedAt) / 1000 : 0;
      return item.duration ? Math.min(item.position + elapsed, item.duration) : item.position + elapsed;
    }

    // Without a track the Mac sends "Not Playing" (or nothing): said in the page's language.
    function artistLine(item) {
      return !item.hasTrack && item.artist ? T.notPlaying : item.artist;
    }

    // Between songs, or while YouTube Music reloads, there's briefly no song at all: keep the
    // last one on screen a few seconds rather than flashing "Not Playing".
    let lastSong = null, lastSongAt = 0, holdTimer = null;
    function shownItem() {
      const item = state && state.now;
      if (item && item.hasTrack) {
        lastSong = item;
        lastSongAt = performance.now();
        return item;
      }
      const held = performance.now() - lastSongAt;
      if (!lastSong || held > 6000) return item;
      clearTimeout(holdTimer);
      holdTimer = setTimeout(render, 6100 - held);
      return { ...lastSong, state: 'paused' };
    }

    function render() {
      const item = shownItem();
      const playing = !!item && item.state === 'playing';
      document.body.classList.toggle('paused', !playing);
      setText('title', item ? item.title : T.notPlaying);
      setText('artist', item ? artistLine(item) : '');
      showCover(item && item.artwork ? item.artwork : '');
      if (setIcon($('toggle'), playing ? 'pause' : 'play')) {
        $('toggle').classList.remove('pop');
        void $('toggle').offsetWidth; // restart the animation
        $('toggle').classList.add('pop');
      }
      $('toggle').disabled = !item;
      $('prev').disabled = $('next').disabled = !(item && item.canSkip);
      renderProgress();
      renderRoute();
      renderOthers();
      renderMini();
      markTracks();
      renderVolume();
      renderExtras();
      $('artist').classList.toggle('link', !!(state && state.player && state.player.artistId && item && state.now && item.title === state.now.title));
    }

    // The Mac's volume: follows the Mac (keys pressed there too), except while or right after
    // a drag here. Dragged anywhere along the bar, not on a knob.
    let volumeTouched = 0, volumeTimer = null, volumeLevel = 0, volumeDrag = false;
    function renderVolume() {
      const level = state && state.volume;
      $('volume').classList.toggle('hidden', level == null);
      if (level == null || volumeDrag || performance.now() - volumeTouched < 1500) return;
      showVolume(state.muted ? 0 : level);
    }
    function showVolume(level) {
      volumeLevel = level;
      $('volumeFill').style.width = `${level * 100}%`;
    }
    // How far along `bar` the finger is, 0…1.
    function fractionAlong(bar, event) {
      const rect = bar.getBoundingClientRect();
      return Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
    }
    function sendVolume() {
      if (!volumeTimer) volumeTimer = setTimeout(() => { volumeTimer = null; send('volume', { value: volumeLevel }); }, 120);
    }
    $('volume').addEventListener('pointerdown', (event) => {
      volumeDrag = true;
      $('volume').setPointerCapture(event.pointerId);
      $('volume').classList.add('dragging');
      showVolume(fractionAlong($('volumeBar'), event));
      sendVolume();
    });
    $('volume').addEventListener('pointermove', (event) => { if (volumeDrag) { showVolume(fractionAlong($('volumeBar'), event)); sendVolume(); } });
    for (const type of ['pointerup', 'pointercancel']) {
      $('volume').addEventListener(type, () => {
        if (!volumeDrag) return;
        volumeDrag = false;
        volumeTouched = performance.now();
        $('volume').classList.remove('dragging');
        send('volume', { value: volumeLevel });
      });
    }

    // YouTube Music's shuffle (mixes the queue once) and repeat (off, all, one).
    function renderExtras() {
      const player = state && state.player;
      $('shuffleQueue').classList.toggle('hidden', !player);
      $('repeat').classList.toggle('hidden', !player);
      if (!player) return;
      $('repeat').classList.toggle('on', player.repeatMode !== 'NONE');
      $('repeat').classList.toggle('one', player.repeatMode === 'ONE');
    }

    // The mini player shows whenever the big one is scrolled away or an album is open.
    let playerVisible = true;
    new IntersectionObserver(([entry]) => {
      playerVisible = entry.isIntersecting && entry.intersectionRatio > 0.2;
      renderMini();
    }, { threshold: [0, 0.2, 0.5] }).observe($('player'));

    function renderMini() {
      const item = shownItem();
      const song = !!item && item.hasTrack;
      document.body.classList.toggle('mini', song && (!!albumShown || !playerVisible));
      if (!song) return;
      $('miniTitle').textContent = item.title;
      $('miniArtist').textContent = artistLine(item);
      const art = item.artwork || '';
      if (($('miniArt').getAttribute('src') || '') !== art) {
        if (art) $('miniArt').src = art; else $('miniArt').removeAttribute('src');
      }
      setIcon($('miniToggle'), item.state === 'playing' ? 'pause' : 'play');
      $('miniNext').disabled = !item.canSkip;
    }

    // A button's icon is only rewritten when it changes, so it doesn't flicker. True if it did.
    function setIcon(button, icon) {
      if (button.dataset.icon === icon) return false;
      button.dataset.icon = icon;
      button.innerHTML = ICON[icon];
      return true;
    }

    // A new title or artist fades over instead of jumping in.
    function setText(id, value) {
      const node = $(id);
      if (node.dataset.text === value) return;
      node.dataset.text = value;
      if (!node.textContent) { node.textContent = value; return; }
      node.classList.add('swap');
      clearTimeout(node.swapTimer);
      node.swapTimer = setTimeout(() => { node.textContent = value; node.classList.remove('swap'); }, 180);
    }

    // A new cover replaces the old one once it's loaded, never a black square in between.
    let coverWanted = '', coverTimer = null, coverLayer = 0;
    function showCover(src) {
      if (src === coverWanted) return;
      coverWanted = src;
      clearTimeout(coverTimer);
      if (!src) {
        // The Mac may still be fetching the new song's cover.
        coverTimer = setTimeout(() => setCover(''), 3000);
        return;
      }
      const img = new Image();
      img.onload = () => { if (coverWanted === src) setCover(src); };
      img.onerror = () => { if (coverWanted === src) setCover(''); };
      img.src = src;
    }

    // Two layers each for the cover and the backdrop: the new one fades in over the old.
    function setCover(src) {
      const art = $('art').querySelectorAll('.layer'), back = $('backdrop').querySelectorAll('.layer');
      if (!src) {
        [...art, ...back].forEach((layer) => layer.classList.remove('on'));
        $('art').classList.remove('cover');
        return;
      }
      coverLayer = 1 - coverLayer;
      const img = art[coverLayer];
      img.src = src;
      back[coverLayer].style.backgroundImage = `url("${src}")`;
      (img.decode ? img.decode() : Promise.resolve()).catch(() => {}).then(() => {
        if (img.getAttribute('src') !== src) return;
        for (const layers of [art, back]) {
          layers[coverLayer].classList.add('on');
          layers[1 - coverLayer].classList.remove('on');
        }
        $('art').classList.add('cover');
      });
    }

    let progressSong = '';
    function renderProgress() {
      if (scrubbing) return;
      const item = shownItem();
      $('progress').classList.toggle('seekable', !!(item && item.canSeek));
      const now = position(item);
      const shown = !!(item && item.duration && now != null);
      $('progress').style.visibility = shown ? 'visible' : 'hidden';
      if (!shown) return;
      // A new song starts its bar at once, rather than sliding back from the old one's end.
      const song = item.id + item.title;
      $('fill').classList.toggle('instant', song !== progressSong);
      progressSong = song;
      $('fill').style.width = `${(now / item.duration) * 100}%`;
      $('elapsed').textContent = format(now);
      $('remaining').textContent = '−' + format(item.duration - now);
    }

    function format(seconds) {
      const total = Math.max(0, Math.floor(seconds));
      const s = String(total % 60).padStart(2, '0'), m = Math.floor(total / 60) % 60, h = Math.floor(total / 3600);
      return h ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
    }

    // Dragging along the bar (or tapping it) jumps there, where the source allows it.
    let scrubbing = 0;
    function previewScrub(fraction) {
      $('fill').style.width = `${fraction * 100}%`;
      $('elapsed').textContent = format(fraction * scrubbing);
      $('remaining').textContent = '−' + format(scrubbing * (1 - fraction));
    }
    $('progress').addEventListener('pointerdown', (event) => {
      const item = state && state.now;
      if (!item || !item.canSeek || !item.duration) return;
      scrubbing = item.duration;
      $('progress').setPointerCapture(event.pointerId);
      $('progress').classList.add('scrubbing');
      previewScrub(fractionAlong($('bar'), event));
    });
    $('progress').addEventListener('pointermove', (event) => { if (scrubbing) previewScrub(fractionAlong($('bar'), event)); });
    $('progress').addEventListener('pointerup', (event) => {
      if (!scrubbing) return;
      const target = fractionAlong($('bar'), event) * scrubbing;
      scrubbing = 0;
      $('progress').classList.remove('scrubbing');
      seek(target);
    });
    $('progress').addEventListener('pointercancel', () => {
      scrubbing = 0;
      $('progress').classList.remove('scrubbing');
      renderProgress();
    });

    function seek(seconds) {
      const item = state && state.now;
      if (!item || !item.canSeek || !item.duration) return;
      // Shown right away; the Mac confirms with its next update.
      item.position = Math.max(0, Math.min(seconds, item.duration - 1));
      receivedAt = performance.now();
      told = null;
      renderProgress();
      syncNowPlaying();
      send('seek', { position: item.position });
    }

    // Where the music comes from, in the spot Apple Music shows the speaker it plays on.
    function renderRoute() {
      const item = state && state.now;
      $('route').className = connection;
      $('routeText').textContent = {
        // The Mac by name; the app only when it isn't the usual one.
        ok: state ? [item && item.app !== 'YouTube Music' ? item.app : '', state.mac].filter(Boolean).join(' · ') : '',
        offline: T.offline, unpaired: T.unpaired, connecting: T.connecting,
      }[connection];
    }

    // MARK: iOS's Now Playing

    // What iOS was last told about the position. Telling it again on every small difference
    // makes its bar jitter; it only hears again after a jump, a pause or a new song.
    let told = null, seekable = null;
    function tellPosition(item, now) {
      const playing = item.state === 'playing';
      if (told && told.id === item.id && told.title === item.title && told.duration === item.duration && told.playing === playing) {
        const expected = Math.min(told.position + (playing ? (performance.now() - told.at) / 1000 : 0), item.duration);
        if (Math.abs(expected - now) < 2) return;
      }
      navigator.mediaSession.setPositionState({ duration: item.duration, position: now, playbackRate: 1 });
      told = { id: item.id, title: item.title, duration: item.duration, position: now, playing, at: performance.now() };
    }

    // iOS shows a cover only once Safari has loaded it, and the page's icon until then: after
    // every new MediaMetadata and every change of its artwork. So covers are read ahead into
    // data here, and the metadata changes only where it has to. A new song keeps the last
    // cover until its own is in (the Mac may still be fetching it), for up to 3 s.
    const NO_COVER = '\#(noCoverPath)';
    const coverData = new Map();
    function readCover(src) {
      if (coverData.has(src)) return coverData.get(src);
      coverData.set(src, null);
      if (coverData.size > 8) coverData.delete(coverData.keys().next().value);
      fetch(src)
        .then((response) => response.ok ? response.blob() : Promise.reject())
        .then((blob) => new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = reject;
          reader.readAsDataURL(blob);
        }))
        .then((data) => { coverData.set(src, data); syncNowPlaying(); }, () => coverData.delete(src));
      return null;
    }

    let nowPlayingCover = '', coverMissingSince = 0;
    function coverForNowPlaying(item) {
      if (item.artwork && readCover(item.artwork)) {
        coverMissingSince = 0;
        return nowPlayingCover = item.artwork;
      }
      if (!coverMissingSince) {
        coverMissingSince = performance.now();
        setTimeout(syncNowPlaying, 3100);
      }
      if (!nowPlayingCover || performance.now() - coverMissingSince >= 3000) nowPlayingCover = NO_COVER;
      return nowPlayingCover;
    }

    let metadataCover = '';
    function setMetadata(item) {
      const session = navigator.mediaSession;
      if (!item) {
        if (session.metadata) session.metadata = null;
        nowPlayingCover = '';
        return;
      }
      const cover = coverForNowPlaying(item);
      const fields = { title: item.title || '', artist: artistLine(item) || '', album: item.album || '' };
      const artwork = [{ src: readCover(cover) || new URL(cover, location.href).href, sizes: '600x600' }];
      if (!session.metadata) {
        session.metadata = new MediaMetadata({ ...fields, artwork });
      } else {
        for (const key in fields) if (session.metadata[key] !== fields[key]) session.metadata[key] = fields[key];
        if (cover !== metadataCover) session.metadata.artwork = artwork;
      }
      metadataCover = cover;
    }

    // Hands the track to iOS. The silence plays while the Mac plays, so iOS shows Pause,
    // and stops while it doesn’t, so iOS shows Play.
    function syncNowPlaying() {
      if (!started || !('mediaSession' in navigator)) return;
      const item = state && state.now;
      const playing = !!item && item.state === 'playing';
      setMetadata(item);
      if (playing && audio.paused) audio.play().catch(() => {});
      if (!playing && !audio.paused) audio.pause();
      navigator.mediaSession.playbackState = playing ? 'playing' : 'paused';
      const now = position(item);
      try {
        if (item && item.duration && now != null) {
          tellPosition(item, now);
          positionSource = item.id;
        } else if (!item || item.id !== positionSource) {
          // A source without a length: don't leave the last one's bar running.
          navigator.mediaSession.setPositionState({ duration: 0, position: 0, playbackRate: 1 });
          told = null;
          positionSource = item && item.id;
        }
        // Same source without a length: a new song still loading. The bar stays until it has one.
      } catch {}
      // iOS's own bar can be dragged only while there's somewhere to send it.
      const canSeek = !!(item && item.canSeek);
      if (canSeek !== seekable) {
        seekable = canSeek;
        try { navigator.mediaSession.setActionHandler('seekto', canSeek ? (details) => seek(details.seekTime) : null); } catch {}
      }
    }

    function setUpButtons() {
      const handlers = {
        play: () => { audio.play().catch(() => {}); navigator.mediaSession.playbackState = 'playing'; send('play'); },
        pause: () => { audio.pause(); navigator.mediaSession.playbackState = 'paused'; send('pause'); },
        nexttrack: () => send('next'),
        previoustrack: () => send('previous'),
        // Without these iOS would offer ±10 s instead of the track buttons.
        seekbackward: null, seekforward: null,
      };
      for (const [action, handler] of Object.entries(handlers)) {
        try { navigator.mediaSession.setActionHandler(action, handler); } catch {}
      }
    }

    // MARK: Shelves, search and other sources

    function image(src) {
      const img = element('img', 'fade');
      img.alt = '';
      img.loading = 'lazy';
      img.decoding = 'async';
      img.referrerPolicy = 'no-referrer';
      img.onload = () => img.classList.add('loaded');
      // Not every video has a 1280 × 720 thumbnail; all have the 320 × 180 one.
      img.onerror = () => { if (img.src.endsWith('/hq720.jpg')) img.src = img.src.replace('/hq720.jpg', '/mqdefault.jpg'); };
      if (src) img.src = src;
      return img;
    }

    function thumb(src) {
      const box = element('span', 'thumb');
      box.append(image(src));
      return box;
    }

    function tile(item) {
      const button = element('button', 'tile');
      button.setAttribute('aria-label', [item.title, item.badge, item.subtitle].filter(Boolean).join(', '));
      button.append(image(item.image), element('span', 'line', item.title));
      if (item.badge) button.append(element('em', '', item.badge));
      button.onclick = () => pick(button, item);
      // Albums start loading on touch, a moment before the tap ends.
      if (item.id.startsWith('browse/')) button.addEventListener('pointerdown', () => fetchAlbum(item.id), { passive: true });
      return button;
    }

    function row(item, onclick) {
      const button = element('button', 'row');
      const text = element('div');
      text.append(element('b', 'line', item.title), element('small', 'line', item.subtitle));
      button.append(thumb(item.image), text);
      button.onclick = onclick;
      return button;
    }

    // YouTube Music's home shelves and the user's playlists, as pages of tiles.
    async function loadLibrary() {
      libraryAt = performance.now();
      try {
        const home = await signedFetch('GET', '/api/library');
        useLanguage(home.language);
        library = home.shelves || [];
        renderLibrary();
      } catch {
        libraryAt = 0;
      }
    }

    function renderLibrary() {
      $('library').replaceChildren(...library.map((shelf) => {
        const section = element('div', 'shelf appear');
        if (shelf.strapline) section.append(element('small', 'strapline', shelf.strapline));
        section.append(element('h2', '', shelf.title || (shelf.kind === 'playlists' ? T.playlists : '')));
        const pager = element('div', 'pager');
        shelf.items.forEach((item) => pager.append(tile(item)));
        section.append(pager, pageDots(pager));
        return section;
      }));
    }

    // One dot per screenful of tiles; how many fit depends on the orientation.
    function pageDots(pager) {
      const dots = element('div', 'dots');
      const update = () => {
        const style = getComputedStyle(pager);
        const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
        const page = pager.clientWidth - padding + 8; // the columns that fit, plus one gap
        const pages = Math.max(1, Math.ceil((pager.scrollWidth - padding + 8) / page - 0.05));
        if (dots.children.length !== pages) dots.replaceChildren(...Array.from({ length: pages }, () => element('i')));
        const current = Math.min(pages - 1, Math.round(pager.scrollLeft / page));
        [...dots.children].forEach((dot, i) => dot.classList.toggle('on', i === current));
        dots.style.visibility = pages > 1 ? 'visible' : 'hidden';
      };
      pager.addEventListener('scroll', update, { passive: true });
      pager.updateDots = update;
      requestAnimationFrame(update);
      return dots;
    }
    addEventListener('resize', () => document.querySelectorAll('.pager').forEach((pager) => pager.updateDots()));

    // Plays it on the Mac; the mini player shows it start. Albums and playlists open first,
    // to pick a song from.
    function pick(button, item) {
      if (item.id.startsWith('browse/')) return openAlbum(item, button);
      button.classList.add('pending');
      setTimeout(() => button.classList.remove('pending'), 1500);
      $('query').blur();
      send('playItem', { id: item.id });
    }

    // Typing searches YouTube Music once it pauses; an answer to an older query is dropped.
    // The field moves to the top first and the results keep their height, so nothing jumps.
    let searchCount = 0, searchTimer = null;
    $('query').addEventListener('focus', () => {
      document.body.classList.add('search-focus');
      const top = $('search').getBoundingClientRect().top + window.scrollY;
      if (Math.abs(window.scrollY - top) > 4) window.scrollTo({ top, behavior: 'smooth' });
    });
    $('query').addEventListener('blur', () => { if (!$('query').value.trim()) document.body.classList.remove('search-focus'); });
    $('query').addEventListener('input', () => {
      clearTimeout(searchTimer);
      const query = $('query').value.trim();
      if (!query) return endSearch(false);
      document.body.classList.add('searching');
      searchTimer = setTimeout(() => search(query), 400);
    });
    $('query').addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      clearTimeout(searchTimer);
      search($('query').value.trim());
      $('query').blur();
    });
    $('cancel').onclick = () => endSearch(true);

    function endSearch(leave) {
      clearTimeout(searchTimer);
      searchCount++;
      $('results').replaceChildren();
      document.body.classList.remove('searching');
      if (!leave) return;
      $('query').value = '';
      $('query').blur();
      document.body.classList.remove('search-focus');
    }

    async function search(query) {
      if (!query) return;
      const count = ++searchCount;
      if (!$('results').children.length) $('results').replaceChildren(element('div', 'note', T.searching));
      try {
        const results = await signedFetch('GET', `/api/search?q=${encodeURIComponent(query)}`);
        if (count === searchCount) renderResults(results);
      } catch {
        if (count === searchCount) $('results').replaceChildren(element('div', 'note', T.searchFailed));
      }
    }

    // Songs as rows (title and artist matter), albums and playlists as a strip of tiles.
    function renderResults(results) {
      const parts = [];
      if (results.songs.length) {
        const shelf = element('div', 'shelf appear');
        shelf.append(element('h2', '', T.songs));
        appendSongs(shelf, results.songs);
        parts.push(shelf);
      }
      if (results.albums.length) parts.push(strip(T.albums, results.albums));
      $('results').replaceChildren(...(parts.length ? parts : [element('div', 'note', T.noResults)]));
    }

    // Song rows that fade in one after another.
    function appendSongs(shelf, songs) {
      songs.forEach((item, i) => {
        const button = row(item, () => pick(button, item));
        button.classList.add('appear');
        button.style.animationDelay = `${Math.min(i, 12) * 22}ms`;
        shelf.append(button);
      });
    }

    // A titled strip of tiles, scrolling sideways.
    function strip(title, items) {
      const section = element('div', 'shelf appear');
      const tiles = element('div', 'strip');
      items.forEach((item) => tiles.append(tile(item)));
      section.append(element('h2', '', title), tiles);
      return section;
    }

    // Grey rows standing in for the songs until they're in.
    function skeletons(list, count) {
      for (let i = 0; i < count; i++) {
        const line = element('div', 'track');
        const text = element('div');
        text.append(element('span', 'skeleton'));
        line.append(element('i', 'skeleton'), text, element('time', 'skeleton'));
        list.append(line);
      }
      return list;
    }

    function actionButton(icon, label, kind, onclick) {
      const button = element('button', kind);
      button.innerHTML = ICON[icon];
      button.append(element('span', '', label));
      button.onclick = onclick;
      return button;
    }

    // Other sound on the Mac, below everything else.
    function renderOthers() {
      const item = state && state.now;
      const rows = state ? state.rows.filter((other) => other.id !== (item && item.id) && other.canControl && other.state !== 'absent') : [];
      if (!rows.length) return $('others').replaceChildren();
      const shelf = element('div', 'shelf');
      shelf.append(element('h2', '', T.others));
      for (const other of rows.slice(0, 5)) {
        const line = element('div', 'row');
        const text = element('div');
        const subtitle = other.artist && other.artist !== other.title && other.artist !== other.app ? `${artistLine(other)} · ${other.app}` : other.app;
        text.append(element('b', 'line', other.title), element('small', 'line', subtitle));
        const button = element('button');
        button.innerHTML = other.state === 'playing' ? ICON.pause : ICON.play;
        button.onclick = () => send('playPause', { id: other.id });
        line.append(thumb(other.artwork), text, button);
        shelf.append(line);
      }
      $('others').replaceChildren(shelf);
    }

    // MARK: The player as a sheet

    // Opens over whatever is showing; the page behind keeps its place (on the home page a
    // spacer holds the player's room while it floats).
    function openPlayer() {
      if (document.body.classList.contains('player-open')) return;
      if (!albumShown) {
        $('playerSpacer').style.height = `${$('player').offsetHeight}px`;
        $('playerSpacer').style.display = 'block';
      }
      document.body.classList.add('player-open');
      $('player').scrollTop = 0;
    }

    function closePlayer(animated = true) {
      if (!document.body.classList.contains('player-open')) return;
      const done = () => {
        const y = window.scrollY;
        document.body.classList.remove('player-open');
        $('player').style.transition = '';
        $('player').style.transform = '';
        $('playerSpacer').style.display = '';
        window.scrollTo(0, y);
        renderMini();
      };
      if (!animated) return done();
      $('player').style.transition = 'transform .3s var(--ease)';
      $('player').style.transform = 'translateY(100%)';
      setTimeout(done, 290);
    }

    // Pulling the sheet down from its top closes it (not when the touch is on a slider).
    let pull = null;
    $('player').addEventListener('touchstart', (event) => {
      if (!document.body.classList.contains('player-open') || $('player').scrollTop > 0 || event.target.closest('#progress, #volume')) return;
      const touch = event.touches[0];
      pull = { x: touch.clientX, y: touch.clientY, dy: 0, at: performance.now(), vertical: null };
    }, { passive: true });
    $('player').addEventListener('touchmove', (event) => {
      if (!pull) return;
      const touch = event.touches[0];
      const dx = touch.clientX - pull.x, dy = touch.clientY - pull.y;
      if (pull.vertical === null && Math.hypot(dx, dy) > 10) pull.vertical = dy > 0 && Math.abs(dy) > Math.abs(dx);
      if (!pull.vertical) return;
      event.preventDefault();
      pull.dy = Math.max(0, dy);
      $('player').style.transition = 'none';
      $('player').style.transform = `translateY(${pull.dy}px)`;
    }, { passive: false });
    $('player').addEventListener('touchend', () => {
      if (!pull) return;
      const { dy, at, vertical } = pull;
      pull = null;
      if (!vertical) return;
      if (dy > 120 || (dy > 40 && dy / (performance.now() - at) > 0.5)) return closePlayer();
      $('player').style.transition = 'transform .3s var(--ease)';
      $('player').style.transform = '';
    });

    // MARK: Albums, playlists and artists

    // Pages of their own over the home page, one stacked on another (an artist, then one of
    // their albums), each pushed onto the history so Back and the swipe back go one step back.
    let albumShown = null, homeScroll = 0;
    const pages = [];

    function openAlbum(item, source) {
      // Where the tile's cover is now, to fly it from there once the page is up.
      const cover = source && source.querySelector('img.loaded');
      pushPage({ kind: 'album', key: item.id, item, fly: cover ? { cover, from: cover.getBoundingClientRect() } : null });
    }

    function openArtist(id, name) {
      pushPage({ kind: 'artist', key: `artist:${id}`, id, name });
    }

    function pushPage(page) {
      $('query').blur();
      closePlayer(false);
      if (pages.length) pages[pages.length - 1].scroll = window.scrollY; else homeScroll = window.scrollY;
      pages.push(page);
      history.pushState(null, '', location.href);
      showPage(page, true);
    }

    function showPage(page, fresh) {
      albumShown = page.key;
      resetSwipe();
      if (page.kind === 'album') {
        renderAlbum({ title: page.item.title, artist: page.item.subtitle, subtitle: page.item.badge, image: page.item.image, tracks: null }, page.item);
        loadAlbum(page.item);
      } else {
        renderArtist(null, page);
        loadArtist(page);
      }
      document.body.classList.toggle('fly', !!(fresh && page.fly));
      document.body.classList.add('in-album');
      restoreScroll(fresh ? 0 : page.scroll || 0);
      renderMini();
      if (fresh && page.fly) flyCover(page.fly.cover, page.fly.from, $('albumBody').querySelector('.cover'));
    }

    function closeAlbum() {
      albumShown = null;
      pages.length = 0;
      document.body.classList.remove('in-album', 'fly');
      resetSwipe();
      restoreScroll(homeScroll);
      renderMini();
    }

    // Safari restores its own idea of the position after Back; this page keeps track itself,
    // and sets it again once the page has been laid out.
    if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
    function restoreScroll(y) {
      window.scrollTo(0, y);
      requestAnimationFrame(() => window.scrollTo(0, y));
    }

    addEventListener('popstate', () => {
      if (!pages.length) return;
      pages.pop();
      if (pages.length) showPage(pages[pages.length - 1], false); else closeAlbum();
    });

    // Albums and artists are asked for once and kept, so a touch can start the request and
    // reopening is instant. A failed request is forgotten, to be tried again.
    const fetched = new Map();
    function fetchOnce(target) {
      if (!fetched.has(target)) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 15000);
        const request = signedFetch('GET', target, null, controller.signal).finally(() => clearTimeout(timeout));
        request.catch(() => fetched.delete(target));
        fetched.set(target, request);
      }
      return fetched.get(target);
    }
    const fetchAlbum = (id) => fetchOnce(`/api/album?id=${encodeURIComponent(id)}`);

    function loadArtist(page) {
      fetchOnce(`/api/artist?id=${encodeURIComponent(page.id)}`)
        .then((artist) => { if (albumShown === page.key) renderArtist(artist, page); })
        .catch(() => { if (albumShown === page.key) renderArtist({ name: page.name, image: '', songs: [], shelves: [], failed: true }, page); });
    }

    // A photo across the top with the name on it, Shuffle and Mix, the top songs, then
    // albums, singles and videos as strips of tiles.
    function renderArtist(artist, page) {
      const body = element('div', 'album artist');
      body.dataset.id = page.key;
      const hero = element('div', 'hero');
      if (artist && artist.image) hero.append(image(artist.image));
      hero.append(element('h1', '', (artist && artist.name) || page.name || ''));
      body.append(hero);
      if (artist && !artist.failed) {
        const actions = element('div', 'actions');
        // Without YouTube Music's own Shuffle and Mix, Play starts the top songs.
        const play = !artist.shuffle && !artist.radio && artist.songs[0];
        const buttons = play ? [[{ item: play }, 'play', T.play, '']]
          : [[artist.shuffle, 'shuffle', T.shuffle, 'shuffle'], [artist.radio, 'play', T.mix, '']];
        for (const [start, icon, label, kind] of buttons) {
          if (!start) continue;
          actions.append(actionButton(icon, label, kind, () => start.item ? send('playItem', { id: start.item.id })
            : send('playTrack', { videoId: start.videoId || undefined, playlistId: start.playlistId || undefined, params: start.params })));
        }
        if (actions.children.length) body.append(actions);
      }
      if (!artist) {
        body.append(skeletons(element('div', 'tracks'), 5));
      } else if (artist.failed) {
        body.append(element('div', 'note', T.noTracks));
      } else {
        if (artist.songs.length) {
          const shelf = element('div', 'shelf');
          shelf.append(element('h2', '', T.topSongs));
          appendSongs(shelf, artist.songs);
          if (artist.allSongsId) {
            const all = element('button', 'retry', T.showAll);
            all.onclick = () => openAlbum({ id: artist.allSongsId, title: `${artist.name}: ${T.topSongs}`, subtitle: artist.name, badge: '', image: artist.image });
            shelf.append(all);
          }
          body.append(shelf);
        }
        for (const shelf of artist.shelves) body.append(strip(shelf.title, shelf.items));
      }
      $('albumBody').replaceChildren(body);
    }

    function loadAlbum(item) {
      fetchAlbum(item.id)
        .then((album) => { if (albumShown === item.id) renderAlbum({ ...album, image: album.image || item.image }, item); })
        .catch(() => {
          if (albumShown === item.id) renderAlbum({ title: item.title, artist: item.subtitle, subtitle: item.badge, image: item.image, tracks: [], failed: true }, item);
        });
    }

    function flyCover(source, from, box) {
      if (!box || !box.animate) return;
      const to = box.getBoundingClientRect();
      if (!from.width || !to.width) return;
      const ghost = source.cloneNode();
      ghost.className = 'ghost';
      Object.assign(ghost.style, { left: `${to.left}px`, top: `${to.top}px`, width: `${to.width}px`, height: `${to.height}px` });
      document.body.append(ghost);
      box.style.visibility = 'hidden';
      const scale = from.width / to.width;
      ghost.animate([
        { transform: `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${scale})`, borderRadius: `${8 / scale}px` },
        { transform: 'none', borderRadius: '10px' },
      ], { duration: 420, easing: 'cubic-bezier(.2,.8,.2,1)' }).finished.finally(() => { box.style.visibility = ''; ghost.remove(); });
    }


    // Swiping right closes it, the page following the finger like iOS's own back swipe.
    let swipe = null;
    const albumView = $('albumView');
    albumView.addEventListener('touchstart', (event) => {
      if (event.touches.length !== 1) return;
      const touch = event.touches[0];
      swipe = { x: touch.clientX, y: touch.clientY, dx: 0, at: performance.now(), horizontal: null };
    }, { passive: true });
    albumView.addEventListener('touchmove', (event) => {
      if (!swipe) return;
      const touch = event.touches[0];
      const dx = touch.clientX - swipe.x, dy = touch.clientY - swipe.y;
      if (swipe.horizontal === null && Math.hypot(dx, dy) > 10) swipe.horizontal = dx > 0 && Math.abs(dx) > Math.abs(dy) * 1.2;
      if (!swipe.horizontal) return;
      event.preventDefault(); // no scrolling while the page follows the finger
      swipe.dx = Math.max(0, dx);
      albumView.style.transition = 'none';
      albumView.style.transform = `translateX(${swipe.dx}px)`;
      albumView.style.opacity = String(1 - (swipe.dx / innerWidth) * 0.6);
    }, { passive: false });
    albumView.addEventListener('touchend', () => {
      if (!swipe) return;
      const { dx, at, horizontal } = swipe;
      swipe = null;
      if (!horizontal) return;
      albumView.style.transition = 'transform .28s var(--ease), opacity .28s ease';
      if (dx > innerWidth * 0.3 || (dx > 40 && dx / (performance.now() - at) > 0.5)) {
        albumView.style.transform = `translateX(${innerWidth}px)`;
        albumView.style.opacity = '0';
        setTimeout(() => history.back(), 250);
      } else {
        albumView.style.transform = '';
        albumView.style.opacity = '';
      }
    });

    function resetSwipe() {
      albumView.style.transition = '';
      albumView.style.transform = '';
      albumView.style.opacity = '';
    }

    // Cover, title, artist, Play and Shuffle and the songs, the way Apple Music shows an album.
    // Drawn again once the songs are in; the cover stays, so it doesn't load twice.
    function renderAlbum(album, item) {
      const previous = $('albumBody').firstElementChild;
      const body = element('div', 'album');
      body.dataset.id = item.id;
      let cover = previous && previous.dataset.id === item.id ? previous.querySelector('.cover') : null;
      if (!cover || (album.image && !cover.querySelector('img[src]'))) {
        cover = element('div', 'cover');
        cover.append(image(album.image));
      }
      body.append(cover, element('h1', '', album.title));
      if (album.artist) {
        const by = element('div', album.artistId ? 'by line link' : 'by line', album.artist);
        if (album.artistId) by.onclick = () => openArtist(album.artistId, album.artist);
        body.append(by);
      }
      if (album.subtitle) body.append(element('div', 'caption', album.subtitle));

      const actions = element('div', 'actions');
      actions.append(actionButton('play', T.play, '', () => album.playlistId
        ? send('playTrack', { playlistId: album.playlistId }) : send('playItem', { id: item.id })));
      if (album.shuffleParams) {
        actions.append(actionButton('shuffle', T.shuffle, 'shuffle',
          () => send('playTrack', { playlistId: album.playlistId, params: album.shuffleParams })));
      }
      body.append(actions);

      const list = element('div', 'tracks');
      if (!album.tracks) {
        skeletons(list, 6);
      } else if (!album.tracks.length) {
        const note = element('div', 'note', T.noTracks);
        if (album.failed) {
          const retry = element('button', 'retry', T.retry);
          retry.onclick = () => { fetched.delete(`/api/album?id=${encodeURIComponent(item.id)}`); renderAlbum({ ...album, tracks: null, failed: false }, item); loadAlbum(item); };
          note.append(element('br'), retry);
        }
        list.append(note);
      } else {
        album.tracks.forEach((track, i) => {
          const line = element('button', 'track appear');
          line.style.animationDelay = `${Math.min(i, 14) * 22}ms`;
          line.dataset.title = track.title;
          line.dataset.index = track.index;
          line.disabled = !track.playable;
          const text = element('div');
          text.append(element('b', 'line', track.title));
          if (track.artist && track.artist !== album.artist) text.append(element('small', 'line', track.artist));
          line.append(element('i', '', track.index), text, element('time', '', track.duration));
          // Stays on the album, like Apple Music; the mini player shows the song start.
          line.onclick = () => {
            pendingTitle = track.title;
            markTracks();
            send('playTrack', { videoId: track.videoId, playlistId: album.playlistId || undefined });
          };
          list.append(line);
        });
      }
      body.append(list);
      $('albumBody').replaceChildren(body);
      markTracks();
    }

    // The song playing gets the bouncing bars instead of its number. A tapped song shows
    // them at once, until the Mac reports what really plays.
    let pendingTitle = null;
    function markTracks() {
      const now = state && state.now;
      if (pendingTitle && now && now.title === pendingTitle) pendingTitle = null;
      const title = pendingTitle || (now && now.title);
      document.querySelectorAll('#albumBody .track[data-title]').forEach((line) => {
        const current = line.dataset.title === title;
        line.classList.toggle('current', current);
        const marker = line.querySelector('i');
        if ((marker.dataset.current === 'yes') === current) return;
        marker.dataset.current = current ? 'yes' : 'no';
        if (current) marker.innerHTML = '<span class="eq"><span></span><span></span><span></span></span>';
        else marker.textContent = line.dataset.index;
      });
    }

    // MARK: Start

    $('prev').innerHTML = ICON.previous;
    $('next').innerHTML = ICON.next;
    $('toggle').innerHTML = ICON.play;
    $('prev').onclick = () => send('previous');
    $('next').onclick = () => send('next');
    $('toggle').onclick = () => send('playPause');
    $('back').onclick = () => history.back();
    $('miniOpen').onclick = openPlayer;
    $('grab').onclick = closePlayer;
    $('artist').onclick = () => {
      const player = state && state.player;
      if ($('artist').classList.contains('link') && player) openArtist(player.artistId, $('artist').textContent);
    };
    $('shuffleQueue').innerHTML = ICON.shuffle;
    $('shuffleQueue').onclick = () => {
      $('shuffleQueue').classList.add('on');
      setTimeout(() => $('shuffleQueue').classList.remove('on'), 900);
      send('shuffle');
    };
    $('repeat').innerHTML = ICON.repeat;
    $('repeat').onclick = () => send('repeat');
    $('miniToggle').onclick = () => send('playPause');
    $('miniNext').innerHTML = ICON.next;
    $('miniNext').onclick = () => send('next');
    $('update').onclick = () => location.reload();
    function showLabels() {
      document.documentElement.lang = language;
      $('update').innerHTML = `${T.update} · <b>${T.reload}</b>`;
      $('query').placeholder = T.search;
      $('cancel').textContent = T.cancel;
      $('startButton').textContent = T.start;
      $('hint').textContent = T.hint;
    }
    showLabels();
    $('startButton').onclick = async () => {
      try {
        await audio.play(); // needs this tap; afterwards the page may start and stop it itself
      } catch (error) {
        $('hint').textContent = `${T.failed}: ${error.message}`;
        return;
      }
      started = true;
      setUpButtons();
      document.body.classList.add('started');
      syncNowPlaying();
    };
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible') return;
      kick();
      if (performance.now() - libraryAt > 60000) loadLibrary();
    });
    setInterval(() => { if (document.visibilityState === 'visible') renderProgress(); }, 500);

    setText('title', T.notPlaying);
    $('prev').disabled = $('next').disabled = $('toggle').disabled = true;
    if (key) {
      renderRoute();
      pollLoop();
    } else {
      connection = 'unpaired';
      renderRoute();
      $('startButton').disabled = true;
    }
    </script>
    </body>
    </html>
    """#
}
