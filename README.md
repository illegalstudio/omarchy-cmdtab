<p align="center">
  <img src="assets/logo-mark.svg" alt="Omarchy Cmdtab logo" width="130">
</p>

<h1 align="center">Omarchy Cmdtab</h1>

<p align="center">
  <em>macOS Cmd+Tab for Hyprland, in the Omarchy shell.</em>
</p>

<p align="center">
  <a href="https://github.com/illegalstudio/omarchy-cmdtab/stargazers"><img src="https://img.shields.io/github/stars/illegalstudio/omarchy-cmdtab?style=flat-square&logo=github&logoColor=white&label=stars&color=38BDF8" alt="Stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/illegalstudio/omarchy-cmdtab?style=flat-square&color=38BDF8" alt="License: MIT"></a>
  <a href="https://omarchy.org"><img src="https://img.shields.io/badge/Omarchy-4.x-38BDF8?style=flat-square" alt="Omarchy 4.x"></a>
  <a href="https://x.com/nahime0"><img src="https://img.shields.io/badge/Follow-%40nahime0-38BDF8?style=flat-square&logo=x&logoColor=white" alt="Follow @nahime0 on X"></a>
</p>

<p align="center">
  <strong>Most-recently-used order &middot; One tap goes back &middot; Type to filter &middot; Every workspace at once</strong>
</p>

<p align="center">
  An Omarchy shell overlay that lists every open window in the order you last used them, the way Cmd+Tab does on macOS. Hold SUPER and tap TAB to select the window you just came from, keep tapping TAB to go further back, then release SUPER to bring the selection to the front. Type a few letters while holding SUPER to find a window on any workspace.
</p>

<p align="center">
  <a href="https://opensource.nahi.me"><strong>Official Website</strong></a>
</p>

---

## Install

### 1. Add the plugin

```bash
omarchy plugin add https://github.com/illegalstudio/omarchy-cmdtab.git --enable
```

### 2. Bind it

The overlay has no keybinding of its own. Add one in `~/.config/hypr/bindings.lua`:

```lua
-- SUPER+TAB is bound to "Next workspace" by default, SUPER+SHIFT+TAB to
-- "Previous workspace", so unbind both before taking them over.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
o.bind("SUPER + TAB", "Window switcher", "omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle 1")
o.bind("SUPER + SHIFT + TAB", "Window switcher (backwards)", "omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle -1")

-- SUPER+ESCAPE normally opens the system menu. While switching, cancel instead.
hl.unbind("SUPER + ESCAPE")
o.bind("SUPER + ESCAPE", "Cancel window switcher or open system menu", "omarchy-shell shell call illegalstudio.omarchy-cmdtab cancelOrMenu ''")

-- Catch quick releases even before the overlay has acquired keyboard focus.
-- ignore_mods also covers releasing SUPER while SHIFT is still held.
for _, key in ipairs({ "Super_L", "Super_R" }) do
  o.bind(key, nil, "omarchy-shell shell call illegalstudio.omarchy-cmdtab release super",
    { release = true, locked = true, ignore_mods = true, non_consuming = true })
end
```

Hyprland reloads on save. Bind `cycle`, not `shell toggle`: `cycle` opens the overlay when it is closed and moves the highlight when it is already open, which is what makes holding SUPER and tapping TAB repeatedly walk down the list instead of closing it again.

If you already use SUPER+H/L to focus neighboring windows, route those bindings through the plugin so they navigate the switcher while it is open and keep directional focus while it is closed:

```lua
hl.unbind("SUPER + H")
hl.unbind("SUPER + L")
o.bind("SUPER + H", "Previous switcher icon or focus left", "omarchy-shell shell call illegalstudio.omarchy-cmdtab vimNavigate h")
o.bind("SUPER + L", "Next switcher icon or focus right", "omarchy-shell shell call illegalstudio.omarchy-cmdtab vimNavigate l")
```

For ALT+TAB, unbind Omarchy's existing `ALT + TAB` and `ALT + SHIFT + TAB` bindings, use `cycle "1 alt"` and `cycle "-1 alt"`, and replace the release bindings with `Alt_L`/`Alt_R` calling `release alt`. The modifier argument ensures releasing an unrelated modifier does not confirm the selection.

## Remove

```bash
omarchy plugin disable illegalstudio.omarchy-cmdtab
omarchy plugin remove illegalstudio.omarchy-cmdtab
```

Then delete the bindings from `~/.config/hypr/bindings.lua`. The `hl.unbind` lines are what suppress the Omarchy defaults, so removing the switcher block restores next and previous workspace.

## Using the switcher

Windows appear in a compact horizontal strip with large application icons, a rounded translucent background, and a highlight around the selection. Only the selected icon shows its application name beneath it. The strip scrolls when there are more windows than fit on screen.

Windows are ordered most recently used first across every workspace. The first icon is the current window, the second is the one before it. **Hold SUPER, tap TAB, then release SUPER** to switch back. Keep holding SUPER and tap TAB again to continue through the list. SHIFT+TAB moves backwards. Enter remains available as an alternative.

Typing filters by window title, application name, class, and workspace. Icons and application names come from desktop entries, including Omarchy webapps launched through Brave, Chrome, Chromium, and Edge. The selected window receives focus and is explicitly raised above other windows, including in floating workspaces.

Clicking an icon activates it. The mouse only takes over the highlight once the pointer actually moves, so a resting cursor never overrides the keyboard selection.

## Keyboard controls

| Key | Action |
| --- | --- |
| Release `SUPER` | Focus and raise the selected window. |
| `l`, `Tab`, `→`, `↓`, `Ctrl+N` | Next window, further back in time. |
| `h`, `Shift+Tab`, `←`, `↑`, `Ctrl+P` | Previous window. |
| Other characters | Filter by title, application, or workspace. Lowercase `h` and `l` are reserved for navigation. |
| `Backspace`, `Ctrl+Backspace`, `Ctrl+U` | Delete a character, a word, or the whole filter. |
| `Enter` | Focus and raise the selected window. |
| `Esc`, `SUPER+Esc` | Cancel and close the switcher. Outside the switcher, `SUPER+Esc` opens the system menu. |

## How the order is decided

Hyprland already ranks every client by how recently it held focus and reports it as `focusHistoryID` in `hyprctl -j clients`, where `0` is the focused window. The overlay sorts on that field, so the order always matches what the compositor itself believes, with no history of its own to drift or to lose across a shell restart.

The highlight starts one step past the focused window. When no window is focused at all, on an empty workspace for instance, row 0 is already the window you last used, so the highlight starts there instead of skipping it.

Hyprland builds that predate `focusHistoryID` still work: the list falls back to grouping by workspace and then by application name.

## Requirements

- Omarchy 4 or newer with the current shell plugin system.
- A Hyprland that reports `focusHistoryID` in `hyprctl -j clients`; check with
  `hyprctl -j clients | grep -m1 focusHistoryID`. Developed against 0.56. Builds
  without it still list every window, just not in recency order.

## Configuration

The overlay uses the active Omarchy theme for its background, with a rounded macOS-style horizontal layout showing icons and the selected application's name. No configuration is required beyond the keybindings.

## IPC

```bash
omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle 1
omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle -1
omarchy-shell shell call illegalstudio.omarchy-cmdtab release super
omarchy-shell shell call illegalstudio.omarchy-cmdtab confirm ""
omarchy-shell shell call illegalstudio.omarchy-cmdtab dismiss ""
omarchy-shell shell call illegalstudio.omarchy-cmdtab cancelOrMenu ""
```

`cycle` opens the switcher or moves the highlight by the given step. An optional `alt` argument, for example `cycle "1 alt"`, selects ALT release instead of SUPER release. `release` confirms only when its modifier matches. `confirm` does what Enter does and answers `closed` when the overlay is not up. A release received during the initial client query waits for the results before activating, so quick taps work too.

`cancelOrMenu` cancels an open switcher, or toggles Omarchy's system menu when the switcher is closed. Bind `SUPER+ESCAPE` to this method so the compositor does not open the menu while SUPER is still held during switching.

## Development install

From a local checkout, expose the repository through the user plugin directory. Do not modify the packaged Omarchy files under `/usr/share/omarchy`.

```bash
ln -s "$PWD" "$HOME/.config/omarchy/plugins/illegalstudio.omarchy-cmdtab"
omarchy plugin enable illegalstudio.omarchy-cmdtab
```

Validate the manifest and run the test suite with:

```bash
make check
```

The tests extract the overlay's pure functions from `Cmdtab.qml` and run them under node against a recorded `hyprctl clients` payload, so they exercise the shipped code rather than a copy of it.

`keepLoaded` plugins are instantiated once and kept, so editing the QML is not picked up by the shell's hot reload. Apply changes with `omarchy restart shell`.

## Safety

The overlay runs `hyprctl`: `-j activewindow` and `-j clients` to read, and `eval` to focus the window you picked. The `cancelOrMenu` method also runs `omarchy-menu toggle system` when the switcher is closed to preserve the default system-menu shortcut. Commands are passed as fixed argument arrays, never through a shell. Window addresses are validated as hexadecimal before interpolation into Lua. Application metadata and icons are read through Quickshell's desktop-entry index and icon lookup. The plugin writes no files.

## License

[MIT](LICENSE)
