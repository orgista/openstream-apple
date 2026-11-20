import Testing
@testable import OpenStreamApple

@Suite("Web Management Page Style Tests")
struct AppleWebManagementPageStyleTests {

    @Test func pairingAndSessionRecoveryPreserveDrafts() {
        let html = AppleWebManagementPage.setup(pairingCode: "ABCD2345")
        #expect(html.contains("searchParams.get('pair')"))
        #expect(html.contains("history.replaceState"))
        #expect(html.contains("await submit(pairForm)"))
        #expect(html.contains("credentials: 'same-origin'"))
        #expect(html.contains("Session ended — scan the code again"))
        #expect(html.contains("restoreDraft"))
        #expect(!html.contains("localStorage"))
        #expect(!html.contains("ABCD2345"))
    }

    @Test func liveSourceFieldsMatchTheApp() {
        let html = AppleWebManagementPage.setup()
        #expect(html.contains("M3U Playlist"))
        #expect(html.contains("Provider Login"))
        #expect(!html.contains("IPTV playlist"))
        #expect(html.contains("data-reveal=\"password\""))
        #expect(html.contains("aria-label=\"Show password\""))
        #expect(html.contains("eye.slash"))
        #expect(html.contains("min-width:44px;min-height:44px"))
        #expect(html.contains("sanitizeCredential"))
        #expect(html.contains("addEventListener('input'"))
        #expect(html.contains("input.value.trim()"))
    }

    @Test("Page applies correct CSS and HTML per style guidelines")
    func pageHasCorrectStyling() {
        // The rendering entry point is AppleWebManagementPage.setup()
        let pairedHtml = AppleWebManagementPage.setup(pairingCode: nil)
        let unpairedHtml = AppleWebManagementPage.setup(pairingCode: "123456")
        
        for html in [pairedHtml, unpairedHtml] {
            // no `outline:none` without `:focus-visible` rule present
            if html.contains("outline:none") {
                #expect(html.contains(":focus-visible{outline:"))
            }
            
            // #ff453a and #ff9a9f absent
            #expect(!html.contains("#ff453a"))
            #expect(!html.contains("#ff9a9f"))
            
            // #FF3366 present
            #expect(html.contains("#FF3366"))
            
            // min-height:44px present for .types label and button.secondary
            #expect(html.contains(".types label{min-height:44px"))
            #expect(html.contains("button.secondary{min-height:44px"))
            
            // h1 text is "oStream" and appears exactly once
            let h1Elements = html.components(separatedBy: "<h1")
            #expect(h1Elements.count == 2)
            #expect(html.contains("<h1 class=\"visually-hidden\">oStream</h1>"))
            
            // a <h1 precedes the first <h2 (only check if h2 exists)
            if let h2Index = html.range(of: "<h2")?.lowerBound {
                let h1Index = html.range(of: "<h1")?.lowerBound
                #expect(h1Index != nil)
                if let h1 = h1Index {
                    #expect(h1 < h2Index)
                }
            }
            
            // placeholder colour equals #9a9a9e
            #expect(html.contains("::placeholder{color:#9a9a9e}"))
        }
    }
}
