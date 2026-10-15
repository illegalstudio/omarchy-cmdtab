-- Isolate Cmdtab keys from the normal Omarchy bindings while switching.
-- Load with dofile(".../hyprland.lua")("SUPER") or use "ALT" instead.
return function(modifier)
  modifier = modifier or "SUPER"
  assert(modifier == "SUPER" or modifier == "ALT", "Cmdtab modifier must be SUPER or ALT")

  local held = modifier == "SUPER" and "super" or "alt"
  local submap = "omarchy-cmdtab"
  local function call(method, argument)
    local command = "omarchy-shell shell call illegalstudio.omarchy-cmdtab "
      .. method .. " " .. string.format("%q", argument or "")
    hl.dispatch(hl.dsp.exec_cmd(command))
  end

  local function start(step)
    -- Capture synchronously, before the shell IPC process starts.
    hl.dispatch(hl.dsp.submap(submap))
    call("cycle", step .. " " .. held)
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
    for _, prefix in ipairs({ "", modifier .. " + " }) do
      hl.bind(prefix .. "TAB", function() call("cycle", "1 " .. held) end)
      hl.bind(prefix .. "SHIFT + TAB", function() call("cycle", "-1 " .. held) end)
    end

    hl.bind("ESCAPE", function()
      hl.dispatch(hl.dsp.submap("reset"))
      call("dismiss", "")
    end, { ignore_mods = true })

    local keys = modifier == "SUPER" and { "Super_L", "Super_R" } or { "Alt_L", "Alt_R" }
    for _, key in ipairs(keys) do
      hl.bind(key, function()
        hl.dispatch(hl.dsp.submap("reset"))
        call("release", held)
      end, { release = true, ignore_mods = true })
    end

    -- Swallow unused keys rather than forwarding them to applications.
    hl.bind("catchall", function() end, { ignore_mods = true })
  end)
end
