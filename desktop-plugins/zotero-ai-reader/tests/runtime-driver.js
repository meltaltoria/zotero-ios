/* Test-only add-on. Never included in the distributed XPI. */
function install() {}
function uninstall() {}
function shutdown() {}
function startup() { run().catch(reportFailure); }
const ROOT = "/workspace/work/zotero-ai-reader";
const result = { checks: [], success: false };
function check(name, value) {
  if (!value) throw new Error(name);
  result.checks.push(name);
}
async function writeResult() {
  await Zotero.File.putContentsAsync(ROOT + "/tests/artifacts/runtime-" + Zotero.version + ".json", JSON.stringify(result, null, 2));
  Services.startup.quit(Components.interfaces.nsIAppStartup.eForceQuit);
}
async function reportFailure(error) {
  result.error = String(error?.stack || error);
  try { await writeResult(); } catch (_) { Zotero.logError(error); }
}
async function run() {
  await Zotero.initializationPromise;
  await Zotero.uiReadyPromise;
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
  const reader = await Zotero.Reader.open(attachment.id);
  for (let i = 0; i < 100 && !reader._internalReader; i++) await Zotero.Promise.delay(100);
  check("PDF reader opened", reader._internalReader);
  plugin.openSidebar(reader);
  let panel;
  for (let i = 0; i < 100 && !panel; i++) {
    panel = [...plugin.panels].find(p => p.attachmentID === attachment.id);
    if (!panel) await Zotero.Promise.delay(100);
  }
  check("sidebar rendered by Zotero lifecycle", panel);
  check("reader sidebar uses current attachment", panel.attachmentID === attachment.id);
  check("safe sidebar DOM", panel.root.querySelector('[data-action="send"]'));
  let button;
  plugin.onSelection({ reader, doc: win.document, params: { annotation: { text: "Controlled selection text", position: { pageIndex: 0 } } }, append: el => { button = el; } });
  button.click();
  const state = plugin.getState(attachment.id);
  check("selection popup transfers text without sending", state.context === "[p. 1]\nControlled selection text" && !state.messages.length);
  await plugin.ask({ state, item, attachmentID: attachment.id, question: "请解释" });
  check("document conversation complete", state.messages.length === 2 && state.messages[1].content.includes("测试回答"));
  check("stream request cleaned up", !state.busy && plugin.requests.size === 0);
  check("other document conversation isolated", plugin.getState(item.id + 1000).messages.length === 0);
  const noteID = await plugin.saveNote({ state, item, attachmentID: attachment.id });
  const note = Zotero.Items.get(noteID);
  check("native Zotero child note saved", note.parentID === item.id && note.getNote().includes("测试回答"));
  check("note does not contain executable AI HTML", !note.getNote().includes('<img'));
  const pending = plugin.ask({ state, item, attachmentID: attachment.id, question: "slow" });
  await Zotero.Promise.delay(250);
  plugin.cancel(state); await pending;
  check("stop generation aborts request", state.status.includes("已停止") && !state.busy && plugin.requests.size === 0);
  // Load the actual preferences fragment through Zotero's own window route.
  plugin.openSettings(win);
  let prefWin;
  for (let i = 0; i < 60; i++) {
    prefWin = Services.wm.getMostRecentWindow("zotero:pref");
    if (prefWin?.document.getElementById("air-model")) break;
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
