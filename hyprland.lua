-- Isolate Cmdtab keys from the normal Omarchy bindings while switching.
-- Load with dofile(".../hyprland.lua")("SUPER") or use "ALT" instead.
return function(modifier)
  modifier = modifier or "SUPER"
  assert(modifier == "SUPER" or modifier == "ALT", "Cmdtab modifier must be SUPER or ALT")

  local held = modifier == "SUPER" and "super" or "alt"
  local submap = "omarchy-cmdtab"
  -- Every gesture gets its own id so the shell can order IPC calls that
  -- overtake each other. The seed keeps ids unique across config reloads.
  local seed = tostring(os and os.time and os.time() or 0)
  local count = 0
  local session = nil
  local function call(method, argument)
    local command = "omarchy-shell shell call illegalstudio.omarchy-cmdtab "
      .. method .. " " .. string.format("%q", argument or "")
    hl.dispatch(hl.dsp.exec_cmd(command))
  end

  local function start(step)
    -- Capture synchronously, before the shell IPC process starts. Entry from
    -- the default map always begins a new gesture.
    hl.dispatch(hl.dsp.submap(submap))
    count = count + 1
    session = seed .. "-" .. count
    call("cycle", step .. " " .. held .. " " .. session)
  end

  local function cycle(step)
    call("cycle", step .. " " .. held .. " " .. (session or ""))
  end

  local function finish(method, argument)
    hl.dispatch(hl.dsp.submap("reset"))
    local id = session or ""
    session = nil
    call(method, argument and (argument .. " " .. id) or id)
  end

  hl.unbind(modifier .. " + TAB")
  hl.unbind(modifier .. " + SHIFT + TAB")
  hl.bind(modifier .. " + TAB", function() start("1") end,
    { description = "Window switcher" })
  hl.bind(modifier .. " + SHIFT + TAB", function() start("-1") end,
    { description = "Window switcher (backwards)" })

  hl.define_submap(submap, function()
    hl.bind("H", function() call("vimNavigate", "h") end, { ignore_mods = true, repeating = true })
    hl.bind("L", function() call("vimNavigate", "l") end, { ignore_mods = true, repeating = true })
    -- Arrows only exist inside this submap, so the global SUPER+arrow
    -- bindings keep working whenever the switcher is closed.
    hl.bind("LEFT", function() call("vimNavigate", "h") end, { ignore_mods = true, repeating = true })
    hl.bind("RIGHT", function() call("vimNavigate", "l") end, { ignore_mods = true, repeating = true })
    for _, prefix in ipairs({ "", modifier .. " + " }) do
      hl.bind(prefix .. "TAB", function() cycle("1") end)
      hl.bind(prefix .. "SHIFT + TAB", function() cycle("-1") end)
    end

    hl.bind("ESCAPE", function() finish("dismiss") end, { ignore_mods = true })

    for _, key in ipairs({ "RETURN", "KP_Enter" }) do
      hl.bind(key, function() finish("confirm") end, { ignore_mods = true })
    end

    -- Swallow unused keys rather than forwarding them to applications.
    hl.bind("catchall", function() end, { ignore_mods = true })
  end)

  -- The modifier is pressed before the submap exists, and Hyprland only runs
  -- release binds of the submap active at press time, shadowing any bind on a
  -- key still held. This bind is therefore universal and transparent, and
  -- non-consuming so applications still receive the modifier. It does
  -- nothing unless a switcher gesture is in progress.
  local keys = modifier == "SUPER" and { "Super_L", "Super_R" } or { "Alt_L", "Alt_R" }
  for _, key in ipairs(keys) do
    hl.bind(key, function()
      if session then finish("release", held) end
    end, { release = true, ignore_mods = true, transparent = true,
      non_consuming = true, submap_universal = true })
  end
end
