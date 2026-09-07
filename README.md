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
  An Omarchy shell overlay that lists every open window in the order you last used them, the way Cmd+Tab does on macOS. Tap SUPER+TAB and press Enter to land back on the window you just came from, hold SUPER and keep tapping TAB to go further back, or type a few letters to jump straight to a window on any workspace.
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
```

Hyprland reloads on save. Bind `cycle`, not `shell toggle`: `cycle` opens the overlay when it is closed and moves the highlight when it is already open, which is what makes holding SUPER and tapping TAB repeatedly walk down the list instead of closing it again.

Any pair of keys works. On a keyboard where ALT is where a Mac's CMD would be, `ALT + TAB` and `ALT + SHIFT + TAB` are the closer match, and are bound by Omarchy to `cycle_next` by default.

## Remove

```bash
omarchy plugin disable illegalstudio.omarchy-cmdtab
omarchy plugin remove illegalstudio.omarchy-cmdtab
```

Then delete the bindings from `~/.config/hypr/bindings.lua`. The `hl.unbind` lines are what suppress the Omarchy defaults, so removing all four restores next and previous workspace.

## Using the switcher

Windows are listed most recently used first: row 0 is the window you are on, row 1 the one before it, and so on across every workspace. Opening the switcher highlights row 1, so **SUPER+TAB then Enter** goes back to the window you last used, and doing it again returns you where you were. Holding SUPER and tapping TAB again moves one row further back for each tap.

Each row shows the window title, its application class, and the workspace it lives on. Typing filters on all three at once, so `slack`, `inbox`, or `3` all narrow the list, and the most recently used match is highlighted first. Activating a window focuses it on whichever workspace it is on, switching workspace if needed.

Clicking a row activates it. The mouse only takes over the highlight once the pointer actually moves over the overlay, so opening it under a resting cursor, or scrolling rows underneath one, never overrides what you selected with the keyboard.

## Keyboard controls

| Key | Action |
| --- | --- |
| `Tab`, `↓`, `Ctrl+N` | Next window, further back in time. |
| `Shift+Tab`, `↑`, `Ctrl+P` | Previous window. |
| Any character | Filter by title, application, or workspace. |
| `Backspace`, `Ctrl+Backspace`, `Ctrl+U` | Delete a character, a word, or the whole filter. |
| `Enter` | Focus the highlighted window. |
| `Esc` | Clear the filter, or close the switcher when it is empty. |

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

None. The overlay reads its colours, fonts, corner radius, and borders from the active Omarchy theme, so it follows whatever `omarchy theme set` you are running.

## IPC

```bash
omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle 1
omarchy-shell shell call illegalstudio.omarchy-cmdtab cycle -1
omarchy-shell shell call illegalstudio.omarchy-cmdtab confirm ""
omarchy-shell shell call illegalstudio.omarchy-cmdtab dismiss ""
```

`cycle` opens the switcher or moves the highlight by the given step. `confirm` does what Enter does and answers `closed` when the overlay is not up. These are what the keybindings call, and what the tests drive.

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

The overlay only ever runs `hyprctl`: `-j activewindow` and `-j clients` to read, and `eval` to focus the window you picked. Arguments are passed as a fixed array, never through a shell, and the only value that varies is a window address that came from Hyprland itself in the same breath. It writes nothing, and reads nothing outside the compositor.

## License

[MIT](LICENSE)
