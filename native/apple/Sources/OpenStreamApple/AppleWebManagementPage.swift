import Foundation

public enum AppleWebManagementPage {
    /// The app's own three-bar mark, drawn inline so the page needs no
    /// external image and carries no other product's name. The geometry is
    /// `OpenStreamThreeBarMark` at the launch screen's 74×52 box: a
    /// full-width middle bar between two bars at 72% width, bar height 18%
    /// and gap 12% of the box, capsule ends.
    static let brandMark = """
    <svg class="mark" viewBox="0 0 74 52" width="37" height="26" fill="currentColor" role="img" aria-label="OpenStream">\
    <rect x="10.36" y="5.72" width="53.28" height="9.36" rx="4.68"/>\
    <rect x="0" y="21.32" width="74" height="9.36" rx="4.68"/>\
    <rect x="10.36" y="36.92" width="53.28" height="9.36" rx="4.68"/>\
    </svg>
    """

    static let sourceTypes: [(value: String, label: String)] = [
        ("addon", "Add-on"),
        ("m3u", "IPTV playlist"),
        ("xtream", "Xtream"),
    ]

    /// Renders the whole portal. `pairingCode == nil` means the browser is
    /// paired (cookie or code accepted), so the add card and remove buttons
    /// are shown; otherwise only the address and the pairing field appear.
    public static func setup(
        manifest: String = "",
        error: String? = nil,
        pairingCode: String? = nil,
        notice: String? = nil,
        sources: [AppleSource] = [],
        address: String? = nil,
        sourceType: String = "addon",
        draft: [String: String] = [:]
    ) -> String {
        let feedback = error.map {
            "<p class=\"feedback error\" role=\"alert\">\(escape($0))</p>"
        } ?? notice.map {
            "<p class=\"feedback notice\" role=\"status\">\(escape($0))</p>"
        } ?? ""
        let addressRow = address.map {
            "<p class=\"address\">\(escape($0))</p>"
        } ?? ""
        let isPaired = pairingCode == nil
        let body = isPaired
            ? """
                <div class="lead">\(addressRow)</div>
            \(feedback.isEmpty ? "" : "<section>\(feedback)</section>")
            \(addCard(manifest: manifest, sourceType: sourceType, draft: draft))
                <section>
                  <h2>Sources</h2>
                  \(sourceList(sources))
                </section>
            """
            : """
                <section>
                  \(addressRow)
                  \(feedback)
                  \(pairingForm())
                </section>
            """

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <meta name="color-scheme" content="dark">
          <title>OpenStream</title>
          <style>\(styles)</style>
        </head>
        <body>
          <main>
            <header>\(brandMark)<span class="wordmark">OpenStream</span></header>
        \(body)
          </main>
        </body>
        </html>
        """
    }

    public static func success(sourceName: String) -> String {
        setup(notice: "Added \(sourceName)")
    }

    private static func pairingForm() -> String {
        """
        <form method="post" action="/" autocomplete="off">
                <input type="hidden" name="action" value="pair">
                <label for="pairingCode">Pairing code</label>
                <input id="pairingCode" name="pairingCode" type="text" required inputmode="text"
                  autocomplete="one-time-code" autocapitalize="characters" spellcheck="false">
                <button type="submit">Continue</button>
              </form>
        """
    }

    /// One card, one form. The type is a radio group; CSS shows the fields
    /// for the checked type, so the page needs no script. Type-specific
    /// fields carry no `required` attribute because a hidden required field
    /// blocks submission silently; the server names the missing value.
    private static func addCard(manifest: String, sourceType: String, draft: [String: String]) -> String {
        let selected = sourceTypes.contains { $0.value == sourceType } ? sourceType : "addon"
        let radios = sourceTypes.map { type in
            "<input type=\"radio\" class=\"type\" id=\"type-\(type.value)\" name=\"sourceType\" value=\"\(type.value)\"\(type.value == selected ? " checked" : "")>"
        }.joined()
        let tabs = sourceTypes.map { type in
            "<label for=\"type-\(type.value)\">\(type.label)</label>"
        }.joined()
        return """
            <section>
              <h2>Add a source</h2>
              <form method="post" action="/" autocomplete="off">
                \(radios)
                <div class="types" role="radiogroup" aria-label="Source type">\(tabs)</div>
                <div class="fields addon">
                  <label for="manifest">Manifest URL</label>
                  <input id="manifest" name="manifest" type="url" inputmode="url"
                    value="\(escape(manifest))"
                    placeholder="https://example.com/manifest.json"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                </div>
                <div class="fields m3u">
                  <label for="m3uName">Name</label>
                  <input id="m3uName" name="m3uName" type="text" autocapitalize="words" spellcheck="false"
                    value="\(escape(draft["m3uName"] ?? ""))">
                  <label for="playlistURL">Playlist URL</label>
                  <input id="playlistURL" name="playlistURL" type="url" inputmode="url"
                    value="\(escape(draft["playlistURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                  <label for="epgURL">EPG URL</label>
                  <input id="epgURL" name="epgURL" type="url" inputmode="url"
                    value="\(escape(draft["epgURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                </div>
                <div class="fields xtream">
                  <label for="xtreamName">Name</label>
                  <input id="xtreamName" name="xtreamName" type="text" autocapitalize="words" spellcheck="false"
                    value="\(escape(draft["xtreamName"] ?? ""))">
                  <label for="serverURL">Server URL</label>
                  <input id="serverURL" name="serverURL" type="url" inputmode="url"
                    value="\(escape(draft["serverURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                  <label for="username">Username</label>
                  <input id="username" name="username" type="text" autocomplete="username"
                    value="\(escape(draft["username"] ?? ""))"
                    autocapitalize="none" spellcheck="false">
                  <label for="password">Password</label>
                  <input id="password" name="password" type="password" autocomplete="current-password">
                </div>
                <button type="submit">Add</button>
              </form>
            </section>
        """
    }

    private static func sourceList(_ sources: [AppleSource]) -> String {
        guard !sources.isEmpty else { return "<p class=\"empty\">No sources</p>" }
        return "<ul class=\"sources\">\(sources.map(sourceRow).joined())</ul>"
    }

    private static func sourceRow(_ source: AppleSource) -> String {
        let capability = source.capabilities.isEmpty ? "" : " · \(escape(source.capabilities.joined(separator: ", ")))"
        return """
        <li><span class="detail"><strong>\(escape(source.name))</strong>\
        <span>\(escape(source.kind.title))\(capability)</span></span>\
        <form method="post" action="/" class="remove">\
        <input type="hidden" name="action" value="remove">\
        <input type="hidden" name="sourceID" value="\(escape(source.id.uuidString))">\
        <button type="submit" class="secondary">Remove</button>\
        </form></li>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Monochrome: black page, white text, greys for borders and secondary
    /// text, one muted red for failure text. Nothing blue.
    private static let styles = """
    :root{font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;color:#f5f5f7;background:#000}\
    *{box-sizing:border-box}\
    body{min-height:100vh;margin:0;padding:max(24px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left));background:#000}\
    main{width:min(100%,560px);margin:0 auto}\
    header{display:flex;align-items:center;gap:10px;margin:0 0 28px 2px}\
    .mark{display:block;color:#f5f5f7}\
    .wordmark{font-size:19px;font-weight:600;letter-spacing:-.015em;color:#f5f5f7}\
    section{margin-bottom:12px;padding:22px 20px;border:1px solid #232325;border-radius:14px;background:#0c0c0d}\
    h2{margin:0 0 16px;font-size:13px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#98989d}\
    form{position:relative;display:grid;gap:8px}\
    label{font-size:13px;font-weight:500;color:#98989d}\
    input[type=text],input[type=url],input[type=password]{width:100%;min-height:46px;padding:12px 14px;border:1px solid #3a3a3c;border-radius:10px;background:#1c1c1e;color:#f5f5f7;font:inherit;outline:none}\
    input:focus{border-color:#f5f5f7}\
    button{min-height:46px;margin-top:6px;padding:0 18px;border:0;border-radius:10px;background:#f5f5f7;color:#000;font:inherit;font-weight:600;cursor:pointer}\
    button:active{opacity:.7}\
    button.secondary{min-height:34px;margin:0;padding:0 8px;border:0;background:transparent;color:#98989d;font-size:13px;font-weight:500}\
    button.secondary:hover,button.secondary:focus-visible{color:#ff453a}\
    .type{position:absolute;width:1px;height:1px;margin:-1px;opacity:0;pointer-events:none}\
    .types{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-bottom:6px;padding:4px;border:1px solid #3a3a3c;border-radius:10px}\
    .types label{min-height:38px;display:grid;place-items:center;border-radius:7px;color:#f5f5f7;font-size:14px;font-weight:500;text-align:center;cursor:pointer}\
    #type-addon:checked~.types label[for=type-addon],#type-m3u:checked~.types label[for=type-m3u],#type-xtream:checked~.types label[for=type-xtream]{background:#f5f5f7;color:#000}\
    #type-addon:focus-visible~.types label[for=type-addon],#type-m3u:focus-visible~.types label[for=type-m3u],#type-xtream:focus-visible~.types label[for=type-xtream]{outline:2px solid #f5f5f7;outline-offset:1px}\
    .fields{display:none;gap:8px}\
    #type-addon:checked~.fields.addon,#type-m3u:checked~.fields.m3u,#type-xtream:checked~.fields.xtream{display:grid}\
    .address{margin:0;font-size:22px;font-weight:600;font-variant-numeric:tabular-nums;word-break:break-all}\
    .lead{margin:-18px 0 22px 2px}\
    .lead .address{font-size:13px;font-weight:400;color:#98989d}\
    ::placeholder{color:#5a5a5e}\
    .address+.feedback,.address+form{margin-top:14px}\
    .feedback{margin:0;font-size:14px;line-height:1.4}\
    .feedback.error{color:#ff9a9f}\
    .feedback+form{margin-top:14px}\
    .sources{display:grid;gap:14px;margin:0;padding:0;list-style:none}\
    .sources li{display:flex;align-items:center;justify-content:space-between;gap:14px;padding-bottom:12px;border-bottom:1px solid #2c2c2e}\
    .sources li:last-child{border-bottom:0;padding-bottom:0}\
    .detail{display:grid;gap:3px;min-width:0}\
    .detail span,.empty{color:#98989d;font-size:13px}\
    .detail strong{font-weight:600;overflow-wrap:anywhere}\
    .remove{display:block;flex:none}\
    .empty{margin:0}\
    @media(max-width:420px){body{padding:16px 13px}section{padding:17px 15px;border-radius:12px}.types label{font-size:13px}}
    """
}
