# Zotero for iOS

## Experimental PDF Translation

This fork contains an experimental native PDF translation integration for iOS/iPadOS.

### Current workflow

1. Open a PDF in Zotero and select text.
2. Tap **Translate** in the PSPDFKit text-selection menu.
3. The default service is Google Translate and does not require an API key. Apple Translation is also available on iPadOS 18+ and uses Apple's system translation UI.
4. Results are shown in an iPad-friendly popover with the original text, translation, and copy action.
5. Zotero highlights/underlines expose **Translate Annotation**; the translated result can be saved to the annotation comment.
6. When a Zotero note editor is active, the result also offers **Add to Note**, inserting the original text and translation through the bundled ProseMirror editor.
7. Translation settings are available from Zotero Settings → Translation.

### CI / automated build

The repository includes `.github/workflows/ios-pdf-translation.yml`.

- The workflow is mirrored on the `master` default branch so GitHub exposes **Run workflow**.
- The default ref is `feature/pdf-translate-ios`.
- The build uses GitHub's `macos-26` runner, Xcode 26.5, and an **iPad Pro 13-inch (M5)** simulator on iOS 26.5.
- The workflow runs `scripts/setup.sh`, resolves Swift packages, and executes `xcodebuild clean test` with ad-hoc simulator signing. No developer certificate is needed; signing preserves entitlements used by App Groups and background sessions.
- The Xcode log is uploaded as a workflow artifact even when the build fails.

### OpenAI-compatible service

The Translation settings support an OpenAI-compatible `/chat/completions` endpoint. API keys are stored in the iOS Keychain. The default academic prompt preserves equations, chemical formulas, material names, abbreviations, citations, and technical terminology. Use `{{targetLanguage}}` in a custom prompt to insert the configured target language.

This feature is intentionally kept on the `feature/pdf-translate-ios` branch until it has been tested on a physical iPad. See the [iPad installation and verification guide](docs/ipad-translation-verification.md) for signing setup and the acceptance checklist.

## Building

1. `git clone --recursive https://github.com/meltaltoria/zotero-ios.git`
1. `cd zotero-ios`
1. `git checkout feature/pdf-translate-ios`
1. `./scripts/setup.sh`
1. If you have your own PSPDFKit license, add it to `licenses/licenses.plist`. Otherwise you will be using a time-limited evaluation version.
1. Open `Zotero.xcodeproj` and build the project.
