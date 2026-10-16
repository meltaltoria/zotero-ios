# Zotero for iOS

## Experimental PDF Translation

This fork contains an experimental native PDF translation integration for iOS/iPadOS.

### Current workflow

1. Open a PDF in Zotero and select text.
2. Tap **Translate** in the PSPDFKit text-selection menu.
3. The default service is Google Translate and does not require an API key.
4. Results are shown in an iPad-friendly popover with the original text, translation, and copy action.
5. Zotero highlights/underlines expose **Translate Annotation**; the translated result can be saved to the annotation comment.
6. Translation settings are available from Zotero Settings → Translation.

### OpenAI-compatible service

The Translation settings support an OpenAI-compatible `/chat/completions` endpoint. API keys are stored in the iOS Keychain. The default academic prompt preserves equations, chemical formulas, material names, abbreviations, citations, and technical terminology. Use `{{targetLanguage}}` in a custom prompt to insert the configured target language.

This feature is intentionally kept on the `feature/pdf-translate-ios` branch until it has been tested on a physical iPad.

## Building

1. `git clone --recursive https://github.com/zotero/zotero-ios.git`
1. `cd zotero-ios`
1. `./scripts/setup.sh`
1. If you have your own PSPDFKit license, add it to `licenses/licenses.plist`. Otherwise you will be using a time-limited evaluation version.
1. Open `Zotero.xcodeproj` and build the project.
