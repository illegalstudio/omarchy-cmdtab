#!/usr/bin/env node
// Runs the pure logic of Cmdtab.qml under node. The functions are extracted
// from the QML source itself rather than duplicated here, so the tests fail
// when the shipped behaviour changes.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "Cmdtab.qml"), "utf8");
const fixture = fs.readFileSync(
  path.join(__dirname, "fixtures", "clients.json"), "utf8");

// Everything the overlay decides with, minus the parts that talk to Hyprland,
// Quickshell, or the scene graph. Those are stubbed on the fake root below.
const EXTRACTED = [
  "loadClients", "rowIndexOf", "rebuildDisplay", "selectIndex",
  "moveSelection", "clickIndex", "hoverIndex", "cycle", "open", "toggle", "dismiss",
  "close", "confirm",
  "release", "endEarly", "vimNavigate", "normalizedAppId", "applicationFor", "iconSource", "findMissingIcons", "iconsFound", "activate", "handleKey", "syncKeyboard", "keyboardFinished",
];

function extract(name) {
  const start = source.indexOf(`\n  function ${name}(`);
  assert.ok(start >= 0, `function not found in Cmdtab.qml: ${name}`);
  let depth = 0;
  for (let i = source.indexOf("{", start); i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(start + 1, i + 1);
  }
  throw new Error(`unbalanced braces in ${name}`);
}

const build = new Function("displayModel", "resultList", "keyCatcher", "Qt", "ListView",
  "DesktopEntries", "Quickshell", "Util", "keyboardProc", "iconProc", `
  const root = {
    opened: false, loading: false, selectedIndex: 0, windows: [],
    activeAddress: "", selectedAddress: "", pendingInitial: false, initialStep: 1,
    desktopEntries: [], shell: null, manifest: null, activated: -1,
    holdModifier: "super", confirmOnLoad: false, runActivation: false,
    keyboardApplied: false, keyboardTarget: false, pointerPosition: null,
    session: "", closedSession: "", earlyEnd: null,
    iconFiles: {}, iconSearched: {}, iconLookupScript: "lookup",
    refresh() { root.refreshes = (root.refreshes || 0) + 1; },
    activate(index) { root.activated = index; if (root.runActivation) activate(index); },
  };
  ${EXTRACTED.map(extract).join("\n\n")}
  ${EXTRACTED.filter((name) => name !== "activate").map((name) => `root.${name} = ${name};`).join("\n")}
  return root;
`);

const QT = {
  Key_Escape: 0x01000000, Key_Tab: 0x01000001, Key_Backtab: 0x01000002,
  Key_H: 72, Key_L: 76, Key_Return: 0x01000004, Key_Enter: 0x01000005,
  Key_Left: 0x01000012, Key_Right: 0x01000014,
  Key_N: 78, Key_P: 80, Key_A: 65, Key_Backspace: 0x01000003,
  ShiftModifier: 0x02000000, ControlModifier: 0x04000000,
  AltModifier: 0x08000000, MetaModifier: 0x10000000,
  callLater(fn) { fn(); },
};

function makeRoot() {
  const displayModel = {
    rows: [],
    clear() { this.rows = []; },
    append(row) { this.rows.push(row); },
    get(index) { return this.rows[index]; },
    get count() { return this.rows.length; },
  };
  const commands = [];
  const keyboardProc = { running: false, command: [] };
  const iconProc = { running: false, command: [] };
  // Theme icons Qt resolves; anything else counts as missing from the theme.
  const themeIcons = new Set(["kitty", "application-x-executable"]);
  const root = build(
    displayModel,
    { positionViewAtIndex() {} },
    { forceActiveFocus() {} },
    QT,
    { Contain: 0 },
    { heuristicLookup() { return null; } },
    { execDetached(command) { commands.push(command); },
      iconPath(icon) { return themeIcons.has(icon) ? "image://icon/" + icon : ""; } },
    { fileUrl(file) { return "file://" + file; } }, keyboardProc, iconProc);
  root.commands = commands;
  root.keyboardProc = keyboardProc;
  root.iconProc = iconProc;
  root.themeIcons = themeIcons;
  return root;
}

// Most-recently-used order the overlay is expected to produce: every mapped
// client, sorted by how recently it held focus.
const clients = JSON.parse(fixture);
const mru = clients
  .filter((client) => client.mapped !== false)
  .sort((a, b) => a.focusHistoryID - b.focusHistoryID);
const addresses = mru.map((client) => client.address);
const ACTIVE = addresses[0];

// A switcher opened with SUPER+TAB, its window list already loaded.
function openedSwitcher(step = 1, raw = fixture) {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  root.cycle(String(step));
  root.loadClients(raw);
  return root;
}

let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log(`ok - ${name}`);
}

test("windows are ordered by focus history", () => {
  const root = makeRoot();
  root.loadClients(fixture);
  assert.deepEqual(root.windows.map((w) => w.address), addresses);
  assert.deepEqual(root.windows.map((w) => w.focusOrder),
    mru.map((client) => client.focusHistoryID));
});

test("unmapped clients are left out", () => {
  const root = makeRoot();
  root.loadClients(fixture);
  assert.equal(root.windows.length, addresses.length);
  assert.equal(root.windows.some((w) => w.address === "0x1004"), false);
});

test("SUPER+TAB highlights the window you last used", () => {
  const root = openedSwitcher(1);
  assert.equal(root.opened, true);
  assert.equal(root.selectedIndex, 1);
  assert.equal(root.selectedAddress, addresses[1]);
});

test("SUPER+SHIFT+TAB starts from the far end", () => {
  const root = openedSwitcher(-1);
  assert.equal(root.selectedIndex, addresses.length - 1);
  assert.equal(root.selectedAddress, addresses[addresses.length - 1]);
});

test("with nothing focused, row 0 is already the last window used", () => {
  const forward = makeRoot();
  forward.cycle("1");
  forward.loadClients(fixture);
  assert.equal(forward.selectedIndex, 0);
  assert.equal(forward.selectedAddress, addresses[0]);

  const backward = makeRoot();
  backward.cycle("-1");
  backward.loadClients(fixture);
  assert.equal(backward.selectedIndex, addresses.length - 1);
});

test("repeated SUPER+TAB walks the list instead of closing", () => {
  const root = openedSwitcher(1);
  root.cycle("1");
  assert.equal(root.selectedIndex, 2);
  root.cycle("1");
  assert.equal(root.selectedIndex, 3);
  root.cycle("-1");
  assert.equal(root.selectedIndex, 2);
  assert.equal(root.opened, true);
  assert.equal(root.selectedAddress, addresses[2]);
});

test("the selection wraps in both directions", () => {
  const root = openedSwitcher(1);
  const count = addresses.length;
  root.selectIndex(0);
  root.moveSelection(-1);
  assert.equal(root.selectedIndex, count - 1);
  root.moveSelection(1);
  assert.equal(root.selectedIndex, 0);
  root.moveSelection(-(count + 3));
  assert.ok(root.selectedIndex >= 0 && root.selectedIndex < count);
});

test("Vim h/l navigate and wrap without changing window focus", () => {
  const root = openedSwitcher();
  assert.equal(root.vimNavigate("h"), "ok");
  assert.equal(root.selectedIndex, 0);
  root.vimNavigate("h");
  assert.equal(root.selectedIndex, addresses.length - 1);
  root.vimNavigate("l");
  assert.equal(root.selectedIndex, 0);
  assert.deepEqual(root.commands, []);
});

test("Vim navigation during loading is applied after clients arrive", () => {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  root.cycle("1");
  root.vimNavigate("l");
  root.vimNavigate("l");
  root.vimNavigate("h");
  root.loadClients(fixture);
  assert.equal(root.selectedIndex, 2);
});

test("Vim navigation outside the switcher has no global side effects", () => {
  const root = makeRoot();
  assert.equal(root.vimNavigate("h"), "closed");
  assert.equal(root.vimNavigate("l"), "closed");
  assert.deepEqual(root.commands, []);
});

test("a refresh cannot move the highlight to another window", () => {
  const root = openedSwitcher(1);
  root.moveSelection(2);
  const held = root.selectedAddress;

  // The 1.5s poll answering with the list shuffled and one window gone.
  const shuffled = JSON.parse(fixture)
    .filter((client) => client.address !== addresses[addresses.length - 1])
    .reverse();
  root.loadClients(JSON.stringify(shuffled));

  assert.equal(root.selectedAddress, held);
  assert.deepEqual(root.windows.map((w) => w.address), addresses.slice(0, -1));
});

test("Hyprland builds without focusHistoryID still list every window", () => {
  const legacy = JSON.parse(fixture).map(({ focusHistoryID, ...rest }) => rest);
  const root = openedSwitcher(1, JSON.stringify(legacy));
  const grouped = legacy
    .filter((client) => client.mapped !== false)
    .sort((a, b) => (a.workspace.id - b.workspace.id)
      || String(a.class).localeCompare(String(b.class)))
    .map((client) => client.address);
  assert.deepEqual(root.windows.map((w) => w.address), grouped);
});

test("degenerate window lists do not throw", () => {
  const empty = openedSwitcher(1, "[]");
  assert.equal(empty.selectedIndex, 0);
  assert.equal(empty.selectedAddress, "");
  empty.moveSelection(1);
  assert.equal(empty.selectedIndex, 0);
  empty.selectIndex(3);
  assert.equal(empty.selectedIndex, 0);

  const broken = openedSwitcher(1, "not json at all");
  assert.deepEqual(broken.windows, []);

  const single = openedSwitcher(1, JSON.stringify([clients[0]]));
  assert.equal(single.selectedIndex, 0);
});

test("cycle survives a missing or unusable step", () => {
  assert.equal(openedSwitcher("garbage").selectedIndex, 1);
  assert.equal(openedSwitcher(0).selectedIndex, 1);
  assert.equal(openedSwitcher("").selectedIndex, 1);
  assert.equal(openedSwitcher(1).cycle("2"), "ok");
});

test("confirm activates the highlighted row, and only when open", () => {
  const closed = makeRoot();
  assert.equal(closed.confirm(), "closed");
  assert.equal(closed.activated, -1);

  const root = openedSwitcher(1);
  assert.equal(root.confirm(), "ok");
  assert.equal(root.activated, 1);
});

test("releasing SUPER activates the selection without Enter", () => {
  const root = openedSwitcher();
  assert.equal(root.release("alt"), "ignored");
  assert.equal(root.activated, -1);
  assert.equal(root.release("super"), "ok");
  assert.equal(root.activated, 1);
  root.dismiss();
  assert.equal(root.release("super"), "closed");
});

test("ALT bindings activate only when ALT is released", () => {
  const root = makeRoot();
  root.cycle("1 alt");
  root.loadClients(fixture);
  assert.equal(root.release("super"), "ignored");
  assert.equal(root.release("alt"), "ok");
  assert.equal(root.activated, 0);
});

test("a quick tap waits for the initial client query before activating", () => {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  root.cycle("1");
  assert.equal(root.release("super"), "pending");
  assert.equal(root.activated, -1);
  root.loadClients(fixture);
  assert.equal(root.activated, 1);
});

test("extra Tab presses during loading are counted", () => {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  root.cycle("1");
  root.cycle("1");
  root.cycle("1");
  root.cycle("-1");
  root.loadClients(fixture);
  assert.equal(root.selectedIndex, 2);
});

test("opening never activates rows left over from the previous invocation", () => {
  const root = openedSwitcher();
  root.dismiss();
  root.cycle("1");
  root.release("super");
  assert.equal(root.activated, -1);
  root.loadClients("[]");
  assert.equal(root.opened, false);
});

test("cancelling during loading prevents delayed activation", () => {
  const root = makeRoot();
  root.cycle("1");
  root.release("super");
  root.dismiss();
  root.loadClients(fixture);
  assert.equal(root.activated, -1);
});

test("SUPER+ESCAPE cancels the switcher without opening the system menu", () => {
  const root = openedSwitcher();
  assert.equal(root.handleKey(QT.Key_Escape, QT.MetaModifier), true);
  assert.equal(root.opened, false);
  assert.equal(root.release("super"), "closed");
  assert.equal(root.activated, -1);
  assert.deepEqual(root.commands, []);
});

test("SUPER+ESCAPE during loading cancels a pending confirmation", () => {
  const root = makeRoot();
  root.cycle("1");
  root.release("super");
  assert.equal(root.handleKey(QT.Key_Escape, QT.MetaModifier), true);
  root.loadClients(fixture);
  assert.equal(root.opened, false);
  assert.equal(root.activated, -1);
  assert.deepEqual(root.commands, []);
});

test("malformed client payloads produce an empty result instead of throwing", () => {
  for (const payload of ['null', '{}', '[null]']) {
    const root = openedSwitcher(1, payload);
    assert.equal(root.windows.length, 0);
    assert.equal(root.pendingInitial, false);
    assert.equal(root.confirm(), "empty");
  }
});

test("activation focuses and raises the chosen window, including floating clients", () => {
  const root = openedSwitcher();
  root.runActivation = true;
  root.confirm();
  assert.equal(root.opened, false);
  assert.equal(root.commands.length, 1);
  assert.equal(root.commands[0][0], "hyprctl");
  const lua = root.commands[0][2];
  assert.ok(lua.includes('address:' + addresses[1]));
  assert.ok(lua.indexOf("hl.dsp.focus") < lua.indexOf("hl.dsp.window.bring_to_top"));
});

test("desktop icons resolve without the shell's menu-only application library", () => {
  const root = makeRoot();
  root.desktopEntries = [
    { id: "org.gnome.Nautilus", name: "Files", icon: "org.gnome.Nautilus" },
    { id: "obsidian", name: "Obsidian", icon: "obsidian" },
    { id: "some-editor", name: "Editor", startupClass: "editor-class", icon: "editor" },
  ];
  assert.equal(root.applicationFor({ class: "org.gnome.Nautilus" }).name, "Files");
  assert.equal(root.applicationFor({ class: "md.obsidian.Obsidian", initialClass: "obsidian" }).icon, "obsidian");
  assert.equal(root.applicationFor({ class: "editor-class" }).icon, "editor");
});

test("Brave and Chrome webapps retain dedicated icons and names", () => {
  const root = makeRoot();
  root.desktopEntries = [
    { id: "brave-browser", name: "Brave", icon: "brave-browser" },
    { id: "Telegram", name: "Telegram", icon: "telegram", execString: 'omarchy-launch-webapp "https://web.telegram.org/k/"' },
    { id: "WhatsApp", name: "WhatsApp", icon: "/icons/WhatsApp.png", execString: 'omarchy-launch-webapp "https://web.whatsapp.com/"' },
    { id: "Todoist", name: "Todoist", icon: "todoist", execString: 'omarchy-launch-webapp "https://app.todoist.com/app/today"' },
    { id: "InstalledPWA", name: "PWA", icon: "pwa", startupClass: "chrome-abcdef-Default" },
  ];
  for (const browser of ["brave", "chrome", "chromium", "msedge"]) {
    assert.equal(root.applicationFor({ class: browser + "-web.telegram.org__k_-Default" }).icon, "telegram");
    assert.equal(root.applicationFor({ class: browser + "-app.todoist.com__app_today-Profile_1" }).name, "Todoist");
  }
  assert.equal(root.applicationFor({ class: "brave-web.whatsapp.com__-Default" }).icon, "/icons/WhatsApp.png");
  assert.equal(root.applicationFor({ class: "chrome-abcdef-Default" }).icon, "pwa");
});

test("webapps sharing a host prefer their matching path regardless of entry order", () => {
  const root = makeRoot();
  root.desktopEntries = [
    { id: "Home", name: "Home", icon: "home", execString: "browser --app=https://example.com/" },
    { id: "Mail", name: "Mail", icon: "mail", execString: "browser --app=https://example.com/mail/" },
  ];
  assert.equal(root.applicationFor({ class: "brave-example.com__mail_-Default" }).icon, "mail");
  assert.notEqual(root.applicationFor({ class: "brave-evil-example.com__mail_-Default" }).icon, "mail");
});

test("icon sources preserve absolute paths and existing URLs", () => {
  const root = makeRoot();
  assert.equal(root.iconSource("/icons/My App.png"), "file:///icons/My App.png");
  assert.equal(root.iconSource("file:///icons/app.svg"), "file:///icons/app.svg");
  assert.equal(root.iconSource("image://icon/kitty"), "image://icon/kitty");
  assert.equal(root.iconSource("kitty"), "image://icon/kitty");
});

test("icons Qt cannot resolve are looked up on disk once per opening", () => {
  const root = openedSwitcher();
  assert.equal(root.iconSource("gleaner"), "image://icon/application-x-executable");
  root.iconProc.running = false;
  root.findMissingIcons([{ appIcon: "kitty" }, { appIcon: "gleaner" }, { appIcon: "gleaner" },
    { appIcon: "/icons/app.png" }, { appIcon: "-rf" }, { appIcon: "a b" }]);
  assert.equal(root.iconProc.running, true);
  assert.deepEqual(root.iconProc.command, ["sh", "-c", "lookup", "sh", "gleaner"]);

  root.iconsFound("gleaner\t/usr/share/icons/hicolor/512x512/apps/gleaner.png\nbogus\trelative.png\n");
  assert.equal(root.iconSource("gleaner"), "file:///usr/share/icons/hicolor/512x512/apps/gleaner.png");
  assert.equal(root.iconFiles.bogus, undefined);

  // A name already searched in this opening is not searched again, even
  // when the disk had nothing for it.
  root.iconProc.running = false;
  root.iconProc.command = [];
  root.findMissingIcons([{ appIcon: "gleaner" }, { appIcon: "missing" }]);
  assert.deepEqual(root.iconProc.command, ["sh", "-c", "lookup", "sh", "missing"]);
  root.iconProc.running = false;
  root.iconProc.command = [];
  root.findMissingIcons([{ appIcon: "missing" }]);
  assert.equal(root.iconProc.running, false);

  // The next opening retries names that were missing, for apps installed
  // while the shell runs.
  root.dismiss();
  root.cycle("1");
  root.findMissingIcons([{ appIcon: "missing" }]);
  assert.deepEqual(root.iconProc.command, ["sh", "-c", "lookup", "sh", "missing"]);
});

test("the theme keeps priority over icons found on disk", () => {
  const root = makeRoot();
  root.iconsFound("kitty\t/opt/kitty.png\n");
  assert.equal(root.iconSource("kitty"), "image://icon/kitty");
});

test("h/l, arrows and Tab navigate, with modifiers still held", () => {
  const root = openedSwitcher();
  root.handleKey(QT.Key_L, QT.MetaModifier);
  assert.equal(root.selectedIndex, 2);
  root.handleKey(QT.Key_H, QT.MetaModifier | QT.ShiftModifier);
  assert.equal(root.selectedIndex, 1);
  root.handleKey(QT.Key_Right, QT.MetaModifier);
  assert.equal(root.selectedIndex, 2);
  root.handleKey(QT.Key_Left, QT.MetaModifier);
  assert.equal(root.selectedIndex, 1);
  root.handleKey(QT.Key_Tab, QT.MetaModifier);
  assert.equal(root.selectedIndex, 2);
  root.handleKey(QT.Key_Tab, QT.MetaModifier | QT.ShiftModifier);
  assert.equal(root.selectedIndex, 1);
  assert.deepEqual(root.commands, []);
});

test("Enter activates the current selection", () => {
  for (const key of [QT.Key_Return, QT.Key_Enter]) {
    const root = openedSwitcher();
    root.handleKey(QT.Key_Right, QT.MetaModifier);
    assert.equal(root.handleKey(key, QT.MetaModifier), true);
    assert.equal(root.activated, 2);
  }
});

test("Enter during loading waits for the clients before activating", () => {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  root.cycle("1");
  root.handleKey(QT.Key_Return, 0);
  assert.equal(root.activated, -1);
  root.loadClients(fixture);
  assert.equal(root.activated, 1);
});

test("clicking an icon selects and activates that window", () => {
  const root = openedSwitcher();
  root.clickIndex(3);
  assert.equal(root.selectedAddress, addresses[3]);
  assert.equal(root.activated, 3);
});

test("clicks are ignored while loading or after closing", () => {
  const loading = makeRoot();
  loading.cycle("1");
  loading.clickIndex(0);
  assert.equal(loading.activated, -1);
  const closed = openedSwitcher();
  closed.dismiss();
  closed.clickIndex(0);
  assert.equal(closed.activated, -1);
});

test("moving the pointer over an icon selects it like the arrow keys", () => {
  const root = openedSwitcher();
  root.hoverIndex(3, 100, 50);
  assert.equal(root.selectedIndex, 1, "the first position only records where the pointer is");
  root.hoverIndex(3, 104, 50);
  assert.equal(root.selectedAddress, addresses[3]);
  root.hoverIndex(0, 20, 50);
  assert.equal(root.selectedIndex, 0);
  root.handleKey(QT.Key_Right, QT.MetaModifier);
  assert.equal(root.selectedIndex, 1);
  assert.equal(root.activated, -1);
  assert.deepEqual(root.commands, []);
});

test("a still pointer never steals the selection", () => {
  const root = openedSwitcher();
  root.hoverIndex(4, 100, 50);
  root.handleKey(QT.Key_Right, QT.MetaModifier);
  // Scrolling the strip under a stationary cursor re-delivers the same point.
  root.hoverIndex(3, 100, 50);
  assert.equal(root.selectedIndex, 2);
});

test("hover state does not carry over between invocations or apply while loading", () => {
  const root = openedSwitcher();
  root.hoverIndex(3, 100, 50);
  root.dismiss();
  root.cycle("1");
  assert.equal(root.pointerPosition, null);
  root.hoverIndex(3, 100, 50);
  root.hoverIndex(3, 110, 50);
  root.loadClients(fixture);
  assert.equal(root.selectedIndex, 1);
});

test("a modifier release that overtakes the opening cycle still switches", () => {
  const root = makeRoot();
  root.activeAddress = ACTIVE;
  assert.equal(root.release("super 7-1"), "closed");
  root.cycle("1 super 7-1");
  assert.equal(root.opened, true);
  root.loadClients(fixture);
  assert.equal(root.activated, 1);
});

test("Enter and Escape that overtake the opening cycle are applied", () => {
  const entered = makeRoot();
  entered.activeAddress = ACTIVE;
  entered.confirm("7-2");
  entered.cycle("1 super 7-2");
  entered.loadClients(fixture);
  assert.equal(entered.activated, 1);

  const escaped = makeRoot();
  escaped.dismiss("7-3");
  escaped.cycle("1 super 7-3");
  assert.equal(escaped.opened, false);
  escaped.loadClients(fixture);
  assert.equal(escaped.activated, -1);
});

test("late calls of a finished gesture neither reopen nor end the next one", () => {
  const root = openedSwitcher("1 super 8-1");
  root.runActivation = true;
  root.release("super 8-1");
  assert.equal(root.opened, false);
  // A second Tab of the same gesture arriving after the release.
  assert.equal(root.cycle("1 super 8-1"), "ignored");
  assert.equal(root.opened, false);
  // A duplicate release must not be remembered for a later gesture.
  root.release("super 8-1");
  assert.equal(root.earlyEnd, null);
  root.cycle("1 super 8-2");
  assert.equal(root.opened, true);
});

test("an early end for another gesture does not close the one being opened", () => {
  const root = makeRoot();
  root.release("super 9-1");
  root.cycle("1 super 9-2");
  root.loadClients(fixture);
  assert.equal(root.opened, true);
  assert.equal(root.activated, -1);
});

test("the overlay's own modifier release does not need a gesture id", () => {
  const root = openedSwitcher("1 super 10-1");
  assert.equal(root.release("super"), "ok");
  assert.equal(root.activated, 1);
});

test("typing and unbound shortcuts are consumed without performing an action", () => {
  const root = openedSwitcher();
  const held = root.selectedAddress;
  for (const key of [QT.Key_A, QT.Key_Backspace, QT.Key_N, QT.Key_P]) {
    assert.equal(root.handleKey(key, QT.MetaModifier | QT.ControlModifier), true);
    assert.equal(root.selectedAddress, held);
    assert.equal(root.opened, true);
    assert.equal(root.activated, -1);
  }
  assert.equal(root.windows.length, addresses.length);
  assert.deepEqual(root.commands, []);
});

test("capture is restored even when closing before the enter process finishes", () => {
  const root = openedSwitcher();
  assert.equal(root.keyboardProc.running, true);
  assert.ok(root.keyboardProc.command[2].includes('submap("omarchy-cmdtab")'));
  root.dismiss();
  root.keyboardProc.running = false;
  root.keyboardFinished(0);
  assert.equal(root.keyboardProc.running, true);
  assert.ok(root.keyboardProc.command[2].includes('submap("reset")'));
  root.keyboardProc.running = false;
  root.keyboardFinished(0);
  assert.equal(root.keyboardApplied, false);
  assert.equal(root.keyboardProc.running, false);
});

test("a capture process failure closes the switcher", () => {
  const root = openedSwitcher();
  root.keyboardProc.running = false;
  root.keyboardFinished(1);
  assert.equal(root.opened, false);
  assert.equal(root.keyboardProc.running, true);
  assert.ok(root.keyboardProc.command[2].includes('submap("reset")'));
  root.keyboardProc.running = false;
  root.keyboardFinished(0);
  assert.equal(root.keyboardApplied, false);
});

console.log(`\n${passed} switcher tests passed`);
