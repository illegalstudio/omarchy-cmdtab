local install = assert(loadfile("hyprland.lua"))()

local function fixture(modifier)
  local bindings, dispatched, removed = {}, {}, {}
  local current = "default"
  hl = {
    dsp = {
      submap = function(name) return { kind = "submap", value = name } end,
      exec_cmd = function(command) return { kind = "exec", value = command } end,
    },
    dispatch = function(action) table.insert(dispatched, action) end,
    unbind = function(key) table.insert(removed, key) end,
    bind = function(key, handler, options)
      table.insert(bindings, { key = key, handler = handler, options = options or {}, submap = current })
    end,
    define_submap = function(name, callback)
      current = name
      callback()
      current = "default"
    end,
  }
  install(modifier)
  local function binding(key, submap)
    for _, item in ipairs(bindings) do
      if item.key == key and item.submap == (submap or "omarchy-cmdtab") then return item end
    end
    error("Missing binding: " .. key)
  end
  local function clear()
    for i = #dispatched, 1, -1 do dispatched[i] = nil end
  end
  return bindings, dispatched, removed, binding, clear
end

for _, modifier in ipairs({ "SUPER", "ALT" }) do
  local bindings, actions, removed, binding, clear = fixture(modifier)
  assert(#removed == 2, "Only the switcher entry bindings may be replaced")
  local keys = modifier == "SUPER" and { "Super_L", "Super_R" } or { "Alt_L", "Alt_R" }
  local globals = 0
  for _, item in ipairs(bindings) do
    if item.submap == "default" then
      globals = globals + 1
      if item.key == keys[1] or item.key == keys[2] then
        local o = item.options
        assert(o.release and o.ignore_mods and o.transparent and o.non_consuming and o.submap_universal,
          "Modifier release must fire although it was pressed outside the submap")
      else
        assert(item.key == modifier .. " + TAB" or item.key == modifier .. " + SHIFT + TAB")
      end
    else
      assert(not item.options.non_consuming, "Modal bindings must consume their keys")
      assert(not item.options.submap_universal, "Modal bindings must not become universal")
    end
  end
  assert(globals == 4, "Global H/L, arrows, Enter and Escape must remain untouched")

  local held = modifier:lower()
  local function session(command)
    return command:match('"[^"]* (%d+%-%d+)"$')
  end

  -- Releasing the modifier outside a gesture must not spawn shell IPC.
  binding(keys[1], "default").handler()
  assert(#actions == 0, "Ordinary modifier releases must be ignored")

  binding(modifier .. " + TAB", "default").handler()
  assert(actions[1].kind == "submap" and actions[1].value == "omarchy-cmdtab",
    "Capture must begin before launching shell IPC")
  assert(actions[2].value:find('cycle "1 ' .. held .. ' ', 1, true))
  local first = assert(session(actions[2].value), "cycle must carry a gesture id")

  clear()
  binding("TAB").handler()
  assert(#actions == 1, "Tab inside the submap must not re-enter it")
  assert(session(actions[1].value) == first, "Tabs of one gesture share its id")

  for key, direction in pairs({ H = "h", L = "l", LEFT = "h", RIGHT = "l" }) do
    clear()
    local item = binding(key)
    assert(item.options.ignore_mods, key .. " must be captured while the modifier is held")
    item.handler()
    assert(#actions == 1 and actions[1].kind == "exec")
    assert(actions[1].value:find('vimNavigate "' .. direction .. '"', 1, true))
  end

  for _, key in ipairs({ "RETURN", "KP_Enter" }) do
    clear()
    local item = binding(key)
    assert(item.options.ignore_mods, key .. " must work while the modifier is held")
    item.handler()
    assert(actions[1].value == "reset", "Enter must release capture even if shell IPC fails")
    assert(actions[2].value:find('confirm "', 1, true))
  end

  clear()
  assert(binding("ESCAPE").options.ignore_mods)
  binding(modifier .. " + TAB", "default").handler()
  local escaped = session(actions[2].value)
  assert(escaped ~= first, "Every gesture from the default map gets a new id")
  clear()
  binding("ESCAPE").handler()
  assert(actions[1].value == "reset", "Escape must release capture even if shell IPC fails")
  assert(actions[2].value == 'omarchy-shell shell call illegalstudio.omarchy-cmdtab dismiss "' .. escaped .. '"')

  for _, key in ipairs(keys) do
    clear()
    binding(modifier .. " + SHIFT + TAB", "default").handler()
    local id = session(actions[2].value)
    assert(actions[2].value:find('cycle "-1 ' .. held .. ' ', 1, true))
    clear()
    binding(key, "default").handler()
    assert(actions[1].value == "reset")
    assert(actions[2].value:find('release "' .. held .. ' ' .. id .. '"', 1, true))
    clear()
    binding(key, "default").handler()
    assert(#actions == 0, "A gesture ends once")
  end

  clear()
  binding("catchall").handler()
  assert(#actions == 0, "Unused keys must be swallowed without executing anything")
  print("ok - " .. modifier .. " submap captures modal keys and restores default bindings")
end

local ok = pcall(function() install("invalid") end)
assert(not ok, "Invalid modifier must be rejected")
print("3 Hyprland binding tests passed")
