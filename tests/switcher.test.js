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
  "loadClients", "rowIndexOf", "rebuildDisplay", "setFilter", "selectIndex",
  "moveSelection", "notePointer", "cycle", "open", "toggle", "dismiss",
  "close", "confirm",
  "release", "cancelOrMenu", "vimNavigate", "normalizedAppId", "applicationFor", "iconSource", "activate",
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
  "DesktopEntries", "Quickshell", "Util", `
  const root = {
    opened: false, loading: false, filterText: "", selectedIndex: 0, windows: [],
    activeAddress: "", selectedAddress: "", pendingInitial: false, initialStep: 1,
    pointerEngaged: false, pointerPrimed: false, pointerX: -1, pointerY: -1,
    desktopEntries: [], shell: null, manifest: null, activated: -1,
    holdModifier: "super", confirmOnLoad: false, runActivation: false,
    refresh() { root.refreshes = (root.refreshes || 0) + 1; },
    activate(index) { root.activated = index; if (root.runActivation) activate(index); },
  };
  ${EXTRACTED.map(extract).join("\n\n")}
  ${EXTRACTED.filter((name) => name !== "activate").map((name) => `root.${name} = ${name};`).join("\n")}
  return root;
`);

function makeRoot() {
  const displayModel = {
    rows: [],
    clear() { this.rows = []; },
    append(row) { this.rows.push(row); },
    get(index) { return this.rows[index]; },
    get count() { return this.rows.length; },
  };
  const commands = [];
  const root = build(
    displayModel,
    { positionViewAtIndex() {} },
    { forceActiveFocus() {} },
    { callLater(fn) { fn(); } },
    { Contain: 0 },
    { heuristicLookup() { return null; } },
    { execDetached(command) { commands.push(command); },
      iconPath(icon) { return "image://icon/" + icon; } },
    { fileUrl(file) { return "file://" + file; } });
  root.commands = commands;
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

test("Vim h/l navigate and wrap without editing the filter or changing window focus", () => {
  const root = openedSwitcher();
  assert.equal(root.vimNavigate("h"), "ok");
  assert.equal(root.selectedIndex, 0);
  root.vimNavigate("h");
  assert.equal(root.selectedIndex, addresses.length - 1);
  root.vimNavigate("l");
  assert.equal(root.selectedIndex, 0);
  assert.equal(root.filterText, "");
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

test("Vim bindings preserve directional focus when the switcher is closed", () => {
  const root = makeRoot();
  assert.equal(root.vimNavigate("h"), "focus");
  assert.equal(root.vimNavigate("l"), "focus");
  assert.deepEqual(root.commands, [
    ["hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({ direction = "l" }))'],
    ["hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({ direction = "r" }))'],
  ]);
  assert.equal(root.vimNavigate("other"), "ignored");
  assert.equal(root.commands.length, 2);
});

test("filtering jumps to the most recently used match", () => {
  const root = openedSwitcher(1);
  root.setFilter("chrome");
  assert.equal(root.selectedIndex, 0);
  assert.equal(root.selectedAddress, "0x1001");

  root.setFilter("no such window");
  assert.equal(root.selectedIndex, 0);
  assert.equal(root.selectedAddress, "");
});

test("the title, class, and workspace are all searchable", () => {
  const root = openedSwitcher(1);
  root.setFilter("obsidian");
  assert.equal(root.selectedAddress, "0x1003");
  root.setFilter("downloads");
  assert.equal(root.selectedAddress, "0x1002");
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

test("hover is ignored until the pointer actually moves", () => {
  const root = openedSwitcher(1);
  // Opening under a resting pointer: the first position is only a baseline.
  assert.equal(root.notePointer(500, 400), false);
  assert.equal(root.notePointer(500, 400), false);
  // A real movement hands control to the mouse.
  assert.equal(root.notePointer(520, 400), true);
  assert.equal(root.notePointer(520, 400), true);
  // Any keyboard move takes it back, so scrolling rows cannot steal it.
  root.moveSelection(1);
  assert.equal(root.pointerEngaged, false);
  assert.equal(root.notePointer(520, 400), false);
});

test("reopening forgets the previous pointer position", () => {
  const root = openedSwitcher(1);
  root.notePointer(500, 400);
  root.notePointer(700, 600);
  assert.equal(root.pointerEngaged, true);
  root.dismiss();
  root.cycle("1");
  root.loadClients(fixture);
  assert.equal(root.pointerEngaged, false);
  assert.equal(root.notePointer(900, 800), false);
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
  root.setFilter("obsidian");
  assert.equal(root.cancelOrMenu(), "cancelled");
  assert.equal(root.opened, false);
  assert.equal(root.release("super"), "closed");
  assert.equal(root.activated, -1);
  assert.deepEqual(root.commands, []);
});

test("SUPER+ESCAPE during loading cancels a pending confirmation", () => {
  const root = makeRoot();
  root.cycle("1");
  root.release("super");
  assert.equal(root.cancelOrMenu(), "cancelled");
  root.loadClients(fixture);
  assert.equal(root.opened, false);
  assert.equal(root.activated, -1);
  assert.deepEqual(root.commands, []);
});

test("SUPER+ESCAPE keeps the system-menu shortcut when the switcher is closed", () => {
  const root = makeRoot();
  assert.equal(root.cancelOrMenu(), "menu");
  assert.deepEqual(root.commands, [["omarchy-menu", "toggle", "system"]]);
});

test("filtering before clients arrive still waits for the query on release", () => {
  const root = makeRoot();
  root.cycle("1");
  root.setFilter("obsidian");
  assert.equal(root.release("super"), "pending");
  assert.equal(root.opened, true);
  root.loadClients(fixture);
  assert.equal(root.selectedAddress, "0x1003");
  assert.equal(root.activated, 0);
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

console.log(`\n${passed} switcher tests passed`);
