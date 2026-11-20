import CryptoKit
import Foundation

public enum AppleWebManagementPage {
    /// The app's own three-bar mark, drawn inline so the page needs no
    /// external image and carries no other product's name. The geometry is
    /// `OpenStreamThreeBarMark` at the launch screen's 74×52 box: a
    /// full-width middle bar between two bars at 72% width, bar height 18%
    /// and gap 12% of the box, capsule ends.
    static let brandMark = """
    <svg class="mark" viewBox="0 0 74 52" width="37" height="26" fill="currentColor" role="img" aria-label="oStream">\
    <rect x="10.36" y="5.72" width="53.28" height="9.36" rx="4.68"/>\
    <rect x="0" y="21.32" width="74" height="9.36" rx="4.68"/>\
    <rect x="10.36" y="36.92" width="53.28" height="9.36" rx="4.68"/>\
    </svg>
    """

    static let sourceTypes: [(value: String, label: String)] = [("m3u", "M3U Playlist"), ("login", "Provider Login")]

    public static var defaultSourceType: String { sourceTypes[0].value }

    /// Renders the whole portal. `pairingCode == nil` means the browser is
    /// paired (cookie or code accepted), so the add card and remove buttons
    /// are shown; otherwise only the address and the pairing field appear.
    public static func setup(
        error: String? = nil,
        pairingCode: String? = nil,
        notice: String? = nil,
        sources: [AppleSource] = [],
        address: String? = nil,
        sourceType: String = defaultSourceType,
        draft: [String: String] = [:],
        lineupName: String? = nil
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
                <section id="pairingPanel" hidden>
                  <p class="feedback error" role="alert">Session ended — scan the code again</p>
                  \(pairingForm())
                </section>
                <div class="lead">\(addressRow)</div>
            \(feedback.isEmpty ? "" : "<section>\(feedback)</section>")
            \(addCard(sourceType: sourceType, draft: draft))
                <section>
                  <h2>Channel Lineup</h2>
                  \(lineupName.map { "<p>" + escape($0) + "</p>" } ?? "")
                  <form method="post" action="/lineup" enctype="multipart/form-data">
                    <label for="lineup">Lineup file</label>
                    <input id="lineup" name="lineup" type="file" accept=".oslineup,.json,application/json" required>
                    <button type="submit">Import Lineup</button>
                  </form>
                </section>
                <section>
                  <h2>Sources</h2>
                  \(sourceList(sources))
                </section>
            """
            : """
                <section id="pairingPanel">
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
          <title>oStream</title>
          <style>\(styles)</style>
        </head>
        <body>
          <main data-paired="\(isPaired)">
            <header>\(brandMark)<span class="wordmark">oStream</span></header>
            <h1 class="visually-hidden">oStream</h1>
        \(body)
          </main>
          <script>\(script)</script>
        </body>
        </html>
        """
    }

    public static func success(sourceName: String) -> String {
        setup(notice: "Added \(sourceName)")
    }

    private static func pairingForm() -> String {
        """
        <form id="pairForm" method="post" action="/" autocomplete="off">
                <input type="hidden" name="action" value="pair">
                <label for="pairingCode">Pairing code</label>
                <input id="pairingCode" name="pairingCode" type="text" required inputmode="text"
                  autocomplete="one-time-code" autocapitalize="characters" spellcheck="false">
                <button type="submit">Continue</button>
              </form>
        """
    }

    /// One card, one form. The type is a radio group; CSS shows the fields
    /// for the checked type. Type-specific
    /// fields carry no `required` attribute because a hidden required field
    /// blocks submission silently; the server names the missing value.
    private static func addCard(sourceType: String, draft: [String: String]) -> String {
        let selected = sourceTypes.contains { $0.value == sourceType } ? sourceType : defaultSourceType
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
                <div class="fields m3u">
                  <label for="m3uName">Name</label>
                  <input id="m3uName" name="m3uName" type="text" autocapitalize="words" spellcheck="false"
                    value="\(escape(draft["m3uName"] ?? ""))">
                  <label for="playlistURL">Playlist URL</label>
                  <input id="playlistURL" name="playlistURL" type="url" inputmode="url"
                    value="\(escape(draft["playlistURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                  <label for="epgURL">EPG URL (optional)</label>
                  <input id="epgURL" name="epgURL" type="url" inputmode="url"
                    value="\(escape(draft["epgURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                </div>
                <div class="fields login">
                  <label for="loginName">Name</label>
                  <input id="loginName" name="loginName" type="text" autocapitalize="words" spellcheck="false"
                    value="\(escape(draft["loginName"] ?? ""))">
                  <label for="serverURL">Server URL</label>
                  <input id="serverURL" name="serverURL" type="url" inputmode="url"
                    value="\(escape(draft["serverURL"] ?? ""))"
                    autocapitalize="none" autocomplete="url" spellcheck="false">
                  <label for="username">Username</label>
                  <input id="username" name="username" type="text" autocomplete="username"
                    value="\(escape(draft["username"] ?? ""))"
                    autocapitalize="none" spellcheck="false">
                  <label for="password">Password</label>
                  <div class="secure-field">
                    <input id="password" name="password" type="password" autocomplete="current-password">
                    <button type="button" class="reveal" data-reveal="password" aria-label="Show password" aria-pressed="false">
                      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                        <g data-symbol="eye"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></g>
                        <path data-symbol="eye.slash" d="M3 3l18 18" hidden/>
                      </svg>
                    </button>
                  </div>
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

    static var scriptHash: String {
        Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
    }

    // Drafts live only in this page's closure, including while the app is
    // unavailable. Re-pairing never persists a password or resubmits a mutation.
    static let script = #"""
    (() => {
      let pendingDraft = null;
      let busy = false;
      const sanitizeCredential = value => value.replace(/[\s\u0085]+/gu, '');
      const main = () => document.querySelector('main');
      const captureDraft = () => Array.from(main().querySelectorAll('input:not([name="pairingCode"])'))
        .map(input => ({id: input.id, value: input.value, checked: input.checked})).filter(item => item.id);
      const restoreDraft = draft => {
        for (const item of draft || []) {
          const input = document.getElementById(item.id);
          if (input) { input.value = item.value; input.checked = item.checked; }
        }
      };
      const showSessionEnded = () => {
        main().dataset.paired = 'false';
        const panel = document.getElementById('pairingPanel');
        panel.hidden = false;
        let feedback = panel.querySelector('.feedback');
        if (!feedback) {
          feedback = document.createElement('p');
          feedback.className = 'feedback error';
          feedback.setAttribute('role', 'alert');
          panel.prepend(feedback);
        }
        feedback.textContent = 'Session ended — scan the code again';
        for (const button of main().querySelectorAll('form:not(#pairForm) button[type="submit"]')) button.disabled = true;
        document.getElementById('pairingCode').focus();
      };
      async function submit(form) {
        if (busy) return;
        busy = true;
        const pairing = form.id === 'pairForm';
        for (const input of form.querySelectorAll('input[type="url"], #username, #password')) {
          input.value = input.value.trim();
          if (input.id === 'username' || input.id === 'password') input.value = sanitizeCredential(input.value);
        }
        if (!pairing) pendingDraft = captureDraft();
        const data = form.enctype === 'multipart/form-data' ? new FormData(form) : new URLSearchParams(new FormData(form));
        const buttons = Array.from(form.querySelectorAll('button[type="submit"]'));
        buttons.forEach(button => { button.disabled = true; });
        try {
          const response = await fetch(form.getAttribute('action') || '/', {method: 'POST', body: data, credentials: 'same-origin'});
          const page = new DOMParser().parseFromString(await response.text(), 'text/html');
          const next = page.querySelector('main');
          if (!next) throw new Error('Session unavailable');
          main().replaceWith(next);
          if (response.status === 401) {
            showSessionEnded();
          } else if ((pairing && next.dataset.paired === 'true') || !response.ok) {
            restoreDraft(pendingDraft);
          } else {
            pendingDraft = null;
          }
        } catch {
          showSessionEnded();
        } finally {
          busy = false;
          buttons.forEach(button => { button.disabled = false; });
        }
      }
      document.addEventListener('submit', event => {
        if (!(event.target instanceof HTMLFormElement)) return;
        event.preventDefault();
        void submit(event.target);
      });
      document.addEventListener('input', event => {
        const input = event.target;
        if (input.id === 'username' || input.id === 'password') {
          const position = input.selectionStart;
          const prefix = position === null ? null : sanitizeCredential(input.value.slice(0, position)).length;
          input.value = sanitizeCredential(input.value);
          if (prefix !== null) input.setSelectionRange(prefix, prefix);
        }
      });
      document.addEventListener('focusout', event => {
        if (event.target.matches('input[type="url"]')) event.target.value = event.target.value.trim();
      });
      document.addEventListener('click', event => {
        const button = event.target.closest('[data-reveal]');
        if (!button) return;
        const input = document.getElementById(button.dataset.reveal);
        const reveal = input.type === 'password';
        input.type = reveal ? 'text' : 'password';
        button.setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
        button.setAttribute('aria-pressed', String(reveal));
        button.querySelector('[data-symbol="eye.slash"]').toggleAttribute('hidden', !reveal);
      });
      const address = new URL(location.href);
      const code = address.searchParams.get('pair');
      if (code !== null) {
        address.searchParams.delete('pair');
        history.replaceState(null, '', address.pathname + address.search + address.hash);
        if (main().dataset.paired !== 'true') {
          const pairForm = document.getElementById('pairForm');
          document.getElementById('pairingCode').value = code;
          void (async () => { await submit(pairForm); })();
        }
      }
    })();
    """#

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
    [hidden]{display:none!important}\
    .secure-field{position:relative}\
    .secure-field input{padding-right:52px}\
    button.reveal{min-width:44px;min-height:44px;position:absolute;right:1px;top:1px;margin:0;padding:0;display:grid;place-items:center;background:transparent;color:inherit}\
    body{min-height:100vh;margin:0;padding:max(24px,env(safe-area-inset-top)) max(18px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(18px,env(safe-area-inset-left));background:#000}\
    main{width:min(100%,560px);margin:0 auto}\
    @media(min-width:1024px){main{width:min(100%,720px)}}\
    header{display:flex;align-items:center;gap:10px;margin:0 0 28px 2px}\
    .mark{display:block;color:#f5f5f7}\
    .wordmark{font-size:19px;font-weight:600;letter-spacing:-.015em;color:#f5f5f7}\
    .visually-hidden{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0,0,0,0);border:0}\
    section{margin-bottom:12px;padding:22px 20px;border:1px solid #232325;border-radius:14px;background:#0c0c0d}\
    h2{margin:0 0 16px;font-size:15px;font-weight:600;color:#98989d}\
    form{position:relative;display:grid;gap:8px}\
    label{font-size:13px;font-weight:500;color:#98989d}\
    input[type=text],input[type=url],input[type=password]{width:100%;min-height:46px;padding:12px 14px;border:1px solid #3a3a3c;border-radius:10px;background:#1c1c1e;color:#f5f5f7;font:inherit;outline:none}\
    input:focus-visible,button:focus-visible{outline:2px solid #FF3366;outline-offset:2px}\
    input:focus{border-color:#f5f5f7}\
    button{min-height:46px;margin-top:6px;padding:0 18px;border:0;border-radius:10px;background:#f5f5f7;color:#000;font:inherit;font-weight:600;cursor:pointer}\
    button:active{opacity:.7}\
    button.secondary{min-height:44px;margin:0;padding:0 8px;border:0;background:transparent;color:#98989d;font-size:13px;font-weight:500}\
    button.secondary:hover,button.secondary:focus-visible{color:#FF3366}\
    .type{position:absolute;width:1px;height:1px;margin:-1px;opacity:0;pointer-events:none}\
    .types{display:grid;grid-template-columns:repeat(\(sourceTypes.count),1fr);gap:4px;margin-bottom:6px;padding:1px;border:1px solid #3a3a3c;border-radius:10px}\
    .types label{min-height:44px;display:grid;place-items:center;border-radius:7px;color:#f5f5f7;font-size:14px;font-weight:500;text-align:center;cursor:pointer}\
    #type-m3u:checked~.types label[for=type-m3u],#type-login:checked~.types label[for=type-login]{background:#f5f5f7;color:#000}\
    #type-m3u:focus-visible~.types label[for=type-m3u],#type-login:focus-visible~.types label[for=type-login]{outline:2px solid #FF3366;outline-offset:2px}\
    .fields{display:none;gap:8px}\
    #type-m3u:checked~.fields.m3u,#type-login:checked~.fields.login{display:grid}\
    .address{margin:0;font-size:22px;font-weight:600;font-variant-numeric:tabular-nums;word-break:break-all}\
    .lead{margin:-18px 0 22px 2px}\
    .lead .address{font-size:13px;font-weight:400;color:#98989d}\
    ::placeholder{color:#9a9a9e}\
    .address+.feedback,.address+form{margin-top:14px}\
    .feedback{margin:0;font-size:14px;line-height:1.4}\
    .feedback.error{color:#FF3366}\
    .feedback+form{margin-top:14px}\
    .sources{display:grid;gap:14px;margin:0;padding:0;list-style:none}\
    .sources li{display:flex;align-items:center;justify-content:space-between;gap:14px;padding-bottom:7px;border-bottom:1px solid #2c2c2e}\
    .sources li:last-child{border-bottom:0;padding-bottom:0}\
    .detail{display:grid;gap:3px;min-width:0}\
    .detail span,.empty{color:#98989d;font-size:13px}\
    .detail strong{font-weight:600;overflow-wrap:anywhere}\
    .remove{display:block;flex:none}\
    .empty{margin:0}\
    @media(max-width:420px){body{padding:16px 13px}section{padding:17px 15px;border-radius:12px}.types label{font-size:13px}}
    """
}
