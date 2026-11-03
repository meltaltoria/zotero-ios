/* SPDX-License-Identifier: MIT */
var readerAIScope;
var chromeHandle;

function install() {}
function uninstall() {}

async function startup({ id, version, rootURI }) {
  await Zotero.initializationPromise;
  await Zotero.uiReadyPromise;
  const aom = Components.classes["@mozilla.org/addons/addon-manager-startup;1"]
    .getService(Components.interfaces.amIAddonManagerStartup);
  chromeHandle = aom.registerChrome(Services.io.newURI(rootURI + "manifest.json"), [
    ["content", "ai-reader", rootURI + "content/"],
    ["locale", "ai-reader", "en-US", rootURI + "locale/en-US/"],
    ["locale", "ai-reader", "zh-CN", rootURI + "locale/zh-CN/"]
  ]);
  readerAIScope = { Zotero, Services, Components, ChromeUtils, rootURI };
  try {
    Services.scriptloader.loadSubScript(rootURI + "content/core.js", readerAIScope);
    Services.scriptloader.loadSubScript(rootURI + "content/panel.js", readerAIScope);
    Services.scriptloader.loadSubScript(rootURI + "content/host.js", readerAIScope);
    readerAIScope.plugin = new readerAIScope.AIReaderPlugin({ id, version, rootURI });
    await readerAIScope.plugin.start();
  } catch (error) {
    readerAIScope?.plugin?.stop();
    chromeHandle?.destruct();
    chromeHandle = undefined;
    readerAIScope = undefined;
    throw error;
  }
}

function onMainWindowLoad({ window }) {
  readerAIScope?.plugin?.addWindow(window);
}

function onMainWindowUnload({ window }) {
  readerAIScope?.plugin?.removeWindow(window);
}

function shutdown() {
  readerAIScope?.plugin?.stop();
  readerAIScope = undefined;
  chromeHandle?.destruct();
  chromeHandle = undefined;
}
