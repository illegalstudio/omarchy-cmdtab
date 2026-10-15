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
  local globals = 0
  for _, item in ipairs(bindings) do
    if item.submap == "default" then
      globals = globals + 1
      assert(item.key == modifier .. " + TAB" or item.key == modifier .. " + SHIFT + TAB")
    else
      assert(not item.options.non_consuming, "Modal bindings must consume their keys")
    end
  end
  assert(globals == 2, "Global H/L and Escape must remain untouched")

  binding(modifier .. " + TAB", "default").handler()
  assert(actions[1].kind == "submap" and actions[1].value == "omarchy-cmdtab",
    "Capture must begin before launching shell IPC")
  assert(actions[2].value:find('cycle "1 ' .. modifier:lower() .. '"', 1, true))

  for _, key in ipairs({ "H", "L" }) do
    clear()
    local item = binding(key)
    assert(item.options.ignore_mods, "H/L must be captured while the modifier is held")
    item.handler()
    assert(#actions == 1 and actions[1].kind == "exec")
    assert(actions[1].value:find('vimNavigate "' .. key:lower() .. '"', 1, true))
  end

  clear()
  assert(binding("ESCAPE").options.ignore_mods)
  binding("ESCAPE").handler()
  assert(actions[1].value == "reset", "Escape must release capture even if shell IPC fails")
  assert(actions[2].value:find('dismiss ""', 1, true))

  local keys = modifier == "SUPER" and { "Super_L", "Super_R" } or { "Alt_L", "Alt_R" }
  for _, key in ipairs(keys) do
    clear()
    local item = binding(key)
    assert(item.options.release and item.options.ignore_mods)
    item.handler()
    assert(actions[1].value == "reset")
    assert(actions[2].value:find('release "' .. modifier:lower() .. '"', 1, true))
  end

  clear()
  binding("catchall").handler()
  assert(#actions == 0, "Unused keys must be swallowed without executing anything")
  print("ok - " .. modifier .. " submap captures modal keys and restores default bindings")
end

local ok = pcall(function() install("invalid") end)
assert(not ok, "Invalid modifier must be rejected")
print("3 Hyprland binding tests passed")
