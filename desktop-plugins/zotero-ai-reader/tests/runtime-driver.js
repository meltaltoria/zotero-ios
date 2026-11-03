/* Test-only add-on. Never included in the distributed XPI. */
function install() {}
function uninstall() {}
function shutdown() {}
function startup() { run().catch(reportFailure); }
const ROOT = "/workspace/work/zotero-ai-reader";
const result = { checks: [], success: false };
async function screenshot(win, name) {
  await Zotero.Promise.delay(200);
  const locale = Services.locale.appLocaleAsBCP47;
  const x = Math.max(0, Math.round(win.mozInnerScreenX + win.innerWidth - 480));
  const y = Math.max(0, Math.round(win.mozInnerScreenY));
  const url = `http://127.0.0.1:18761/__snapshot?name=${name}-${locale}&x=${x}&y=${y}&w=480&h=${Math.round(win.innerHeight)}`;
  await Zotero.HTTP.request('GET', url);
}
function check(name, value) {
  if (!value) throw new Error(name);
  result.checks.push(name);
}
async function waitFor(test, message) {
  for (let i = 0; i < 150; i++) {
    if (test()) return;
    await Zotero.Promise.delay(100);
  }
  throw new Error(message);
}
async function visiblePanel(win, plugin, details, phase) {
  await win.document.l10n.translateFragment(details);
  if (details.sidenav) await win.document.l10n.translateFragment(details.sidenav);
  await Zotero.Promise.delay(200);
  const panel = [...plugin.panels].find(p => p.body.closest('item-details') === details);
  check(phase + ' panel is connected after localization', panel?.root.isConnected);
  check(phase + ' question is in the live document', panel.el('question').isConnected);
  const box = panel.root.getBoundingClientRect();
  check(phase + ' panel has visible dimensions', box.width > 180 && box.height > 300);
  const pane = details.getPane(plugin.sectionID);
  const section = pane?.querySelector('collapsible-section') || pane;
  check(phase + ' localized title uses label attribute', section?.getAttribute('label')?.startsWith('AI '));
  const button = [...(details.sidenav?.querySelectorAll('[data-pane]') || [])]
    .find(node => node.getAttribute('data-pane') === plugin.sectionID);
  result[phase + '_sidenav'] = {
    pane_id: plugin.sectionID, sidenav_tag: details.sidenav?.tagName,
    button_exists: Boolean(button), text: button?.textContent,
    tooltip: button?.getAttribute('tooltiptext'),
    candidates: [...win.document.querySelectorAll('[data-pane]')].filter(x => x.getAttribute('data-pane') === plugin.sectionID).map(x => ({ tag: x.tagName, cls: x.getAttribute('class'), text: x.textContent.slice(0,60) }))
  };
  await screenshot(win, 'sidebar-' + phase);
  check(phase + ' sidenav is icon-only', button && button.textContent.trim() === '');
  check(phase + ' sidenav tooltip is localized', button.getAttribute('tooltiptext')?.startsWith('AI '));
  return panel;
}
async function writeResult() {
  const tag = Zotero.Prefs.get('aiReaderTest.runTag') || Zotero.version;
  await Zotero.File.putContentsAsync(ROOT + "/tests/artifacts/runtime-" + tag + ".json", JSON.stringify(result, null, 2));
  Services.startup.quit(Components.interfaces.nsIAppStartup.eForceQuit);
}
async function reportFailure(error) {
  result.error = String(error?.message || error) + '\n' + String(error?.stack || '');
  try { await writeResult(); } catch (_) { Zotero.logError(error); }
}
async function run() {
  await Zotero.initializationPromise;
  await Zotero.uiReadyPromise;
  const { AddonManager } = ChromeUtils.importESModule('resource://gre/modules/AddonManager.sys.mjs');
  const sourceManifest = JSON.parse(await Zotero.File.getContentsAsync(ROOT + '/src/manifest.json'));
  const oldPath = ROOT + '/dist/zotero-ai-reader-1.0.1.xpi';
  let oldRejected = false;
  try {
    const broken = await AddonManager.getInstallForFile(Zotero.File.pathToFile(oldPath));
    result.old_install = { error: broken?.error, state: broken?.state, addon_id: broken?.addon?.id || null };
    oldRejected = !broken || Boolean(broken.error);
  } catch (error) {
    result.old_install = { error: String(error.message || error) };
    oldRejected = true;
  }
  check('old 1.0.1 rejected by real Zotero installer', oldRejected);
  const install = await AddonManager.getInstallForFile(Zotero.File.pathToFile(ROOT + '/dist/zotero-ai-reader-' + sourceManifest.version + '.xpi'));
  result.new_install = { error: install?.error, state: install?.state, addon_id: install?.addon?.id || null, compatible: install?.addon?.isCompatible };
  check('new XPI passes real manifest validation', install && !install.error && install.addon?.isCompatible);
  await new Promise((resolve, reject) => {
    const timer = Zotero.getMainWindow().setTimeout(() => reject(new Error('Native add-on install timed out')), 20000);
    const finish = error => { Zotero.getMainWindow().clearTimeout(timer); install.removeListener(listener); error ? reject(error) : resolve(); };
    const listener = {
      onInstallEnded: () => finish(),
      onInstallFailed: current => finish(new Error('Native install failed: ' + current.error)),
      onDownloadFailed: current => finish(new Error('Native add-on read failed: ' + current.error))
    };
    install.addListener(listener);
    Promise.resolve(install.install()).catch(finish);
  });
  check('native add-on installation completed', true);
  for (let i = 0; i < 100 && !Zotero.AIReader; i++) await Zotero.Promise.delay(100);
  check("extension booted", Zotero.AIReader);
  const plugin = Zotero.AIReader.owner;
  check("official sidebar section registered", plugin.sectionID);
  check("settings registered", Zotero.PreferencePanes.pluginPanes.some(p => p.id === "ai-reader-preferences"));
  const win = Zotero.getMainWindow();
  check("Tools menu installed", win.document.getElementById("ai-reader-settings-menu"));
  const fixtureKey = "fixture-only-no-real-credential";
  const config = { ...plugin.getSettings(), baseURL: "http://127.0.0.1:18761/v1", model: "fixture-model", noAuth: false, timeout: 30 };
  await plugin.saveSettings(config, fixtureKey, false);
  check("password manager roundtrip", plugin.hasKey(config.baseURL));
  check("credentials isolated by endpoint", !plugin.hasKey("http://127.0.0.1:18761/other"));
  check("no plaintext key in preferences", !JSON.stringify(plugin.getSettings()).includes(fixtureKey));
  const test = await plugin.testConnection(config);
  check("privileged HTTP and SSE in Zotero", test.text.includes("测试回答"));
  const noStream = await plugin.request({ ...config, stream: false }, fixtureKey, [{ role: "user", content: "nonstream" }]);
  check("nonstream provider response", noStream.text.includes("测试回答"));
  try {
    await plugin.request(config, fixtureKey, [{ role: "user", content: "error401" }]);
    throw new Error("expected unauthorized error");
  } catch (e) { check("HTTP errors redact credentials", e.message.includes("401") && !e.message.includes(fixtureKey)); }
  const item = new Zotero.Item("journalArticle");
  item.libraryID = Zotero.Libraries.userLibraryID;
  item.setField("title", "AI Reader integration fixture");
  item.setField("abstractNote", "A controlled experiment about reading assistance.");
  item.setField("date", "2026");
  await item.saveTx();
  const attachment = await Zotero.Attachments.linkFromFile({ file: Zotero.File.pathToFile(ROOT + "/tests/fixture.pdf"), parentItemID: item.id });
  check("PDF fixture attached", attachment.id);
  const excerpt = await plugin.readContext({ source: "fulltext", attachmentID: attachment.id, item, state: {} });
  check("real Zotero PDF text extraction", excerpt.text.includes("Controlled reading experiment"));
  await win.ZoteroPane.selectItem(item.id);
  let libraryDetails;
  await waitFor(() => {
    libraryDetails = [...win.document.querySelectorAll('item-details')].find(x => x.item?.id === item.id);
    return libraryDetails?.getPane(plugin.sectionID);
  }, 'Library item details did not render');
  libraryDetails.pinnedPane = plugin.sectionID;
  await libraryDetails.scrollToPane(plugin.sectionID, 'instant');
  await waitFor(() => [...plugin.panels].some(p => p.body.closest('item-details') === libraryDetails), 'Library AI panel did not render');
  const libraryPanel = await visiblePanel(win, plugin, libraryDetails, 'library');
  libraryPanel.el('source').value = 'abstract';
  libraryPanel.el('source').dispatchEvent(new win.Event('change', { bubbles: true }));
  await waitFor(() => !libraryPanel.state.loading && libraryPanel.state.context.includes('controlled experiment'), 'Library material control did not load the abstract');
  check('library source selector loads material through UI', libraryPanel.el('context').value.includes('controlled experiment'));
  await screenshot(win, 'sidebar-library');
  const reader = await Zotero.Reader.open(attachment.id);
  for (let i = 0; i < 100 && !reader._internalReader; i++) await Zotero.Promise.delay(100);
  check("PDF reader opened", reader._internalReader);
  plugin.openSidebar(reader);
  const readerDetails = win.document.getElementById(reader.tabID + '-context');
  let panel;
  for (let i = 0; i < 100 && !panel; i++) {
    panel = [...plugin.panels].find(p => p.attachmentID === attachment.id && p.body.closest('item-details') === readerDetails);
    if (!panel) await Zotero.Promise.delay(100);
  }
  check("sidebar rendered by Zotero lifecycle", panel);
  const itemDetails = readerDetails;
  await win.document.l10n.translateFragment(itemDetails);
  await Zotero.Promise.delay(200);
  result.visible_dom = {
    panel_connected: panel.root.isConnected,
    live_question: Boolean(win.document.querySelector('.air-panel [data-role="question"]')),
    section_label: itemDetails.getPane(plugin.sectionID)?.querySelector('collapsible-section')?.getAttribute('label')
  };
  await screenshot(win, 'sidebar-reader');
  check('sidebar stays connected after Fluent translation', panel.root.isConnected);
  check('sidebar question exists in live document after Fluent translation', panel.el('question').isConnected);
  await visiblePanel(win, plugin, itemDetails, 'reader');
  check("reader sidebar uses current attachment", panel.attachmentID === attachment.id);
  check("safe sidebar DOM", panel.root.querySelector('[data-action="send"]'));
  check('native XHTML question control retained', panel.el('question') instanceof win.HTMLTextAreaElement);
  let button;
  plugin.onSelection({ reader, doc: win.document, params: { annotation: { text: "Controlled selection text", position: { pageIndex: 0 } } }, append: el => { button = el; } });
  button.click();
  const state = plugin.getState(attachment.id);
  check("selection popup transfers text without sending", state.context === "[p. 1]\nControlled selection text" && !state.messages.length);
  panel.el('question').value = '请解释';
  panel.el('question').dispatchEvent(new win.Event('input', { bubbles: true }));
  panel.el('question').scrollIntoView({ block: 'center' });
  await Zotero.Promise.delay(100);
  const questionBox = panel.el('question').getBoundingClientRect();
  check('reader question control can be scrolled into the viewport', questionBox.top >= 0 && questionBox.bottom <= win.innerHeight);
  await screenshot(win, 'sidebar-reader-controls');
  panel.root.querySelector('[data-action="send"]').click();
  await waitFor(() => !state.busy && state.messages.length === 2, 'Send button did not complete a conversation');
  check("document conversation complete", state.messages.length === 2 && state.messages[1].content.includes("测试回答"));
  check('AI answer is visible in connected reader DOM', panel.root.isConnected && panel.el('chat').textContent.includes('测试回答'));
  check("stream request cleaned up", !state.busy && plugin.requests.size === 0);
  check("other document conversation isolated", plugin.getState(item.id + 1000).messages.length === 0);
  panel.root.querySelector('[data-action="copy"]').click();
  await waitFor(() => state.status.includes('已复制'), 'Copy button did not complete');
  check('copy button writes the native clipboard', Zotero.Utilities.Internal.getClipboard('text/plain').includes('测试回答'));
  panel.root.querySelector('[data-action="save"]').click();
  await waitFor(() => state.status.includes('已保存'), 'Save-note button did not complete');
  const noteID = await Zotero.DB.valueQueryAsync('SELECT itemID FROM itemNotes WHERE parentItemID=? ORDER BY itemID DESC LIMIT 1', [item.id]);
  const note = Zotero.Items.get(noteID);
  check("native Zotero child note saved", note.parentID === item.id && note.getNote().includes("测试回答"));
  check("note does not contain executable AI HTML", !note.getNote().includes('<img'));
  panel.el('question').value = 'slow';
  panel.root.querySelector('[data-action="send"]').click();
  await waitFor(() => state.busy && state.partial.length > 0, 'Slow request did not start from UI');
  panel.root.querySelector('[data-action="stop"]').click();
  await waitFor(() => !state.busy, 'Stop button did not abort the request');
  check("stop generation aborts request", state.status.includes("已停止") && !state.busy && plugin.requests.size === 0);
  // Load the actual preferences fragment through Zotero's own window route.
  panel.root.querySelector('[data-action="settings"]').click();
  let prefWin;
  for (let i = 0; i < 60; i++) {
    prefWin = Services.wm.getMostRecentWindow("zotero:pref");
    if (prefWin?.document.getElementById("air-model")?.value === "fixture-model") break;
    await Zotero.Promise.delay(100);
  }
  check("settings fragment and script loaded", prefWin?.document.getElementById("air-model")?.value === "fixture-model");
  check("settings never reveal saved key", prefWin.document.getElementById("air-key").value === "");
  await plugin.saveSettings(config, "", true);
  check("saved credential can be deleted", !plugin.hasKey(config.baseURL));
  prefWin.close();
  plugin.stop();
  check("shutdown removes sidebar and bridge", plugin.panels.size === 0 && !Zotero.AIReader);
  check("shutdown removes Tools menu", !win.document.getElementById("ai-reader-settings-menu"));
  result.success = true;
  await writeResult();
}
