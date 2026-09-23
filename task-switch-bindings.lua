-- ewweberlin.quickswitch bindings. Load with dofile() from
-- ~/.config/hypr/bindings.lua, or paste this block there instead if you prefer
-- plugin updates never to change your Hyprland config (see README).

-- SUPER+TAB opens the switcher while the plugin is loaded (it sets
-- quickswitch_loaded via hyprctl eval) and falls back to the Omarchy default
-- "Next workspace" otherwise, so a disabled/removed plugin leaves no dead key.
hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Task switch", function()
  if quickswitch_loaded then
    hl.dispatch(hl.dsp.global("ewweberlin.quickswitch:next"))
  else
    hl.dispatch(hl.dsp.focus({ workspace = "e+1" }))
  end
end, { repeating = true })

-- Keys active only while the switcher is open (the plugin enters/leaves this
-- submap). Normal SUPER+arrows / SUPER+Q bindings stay untouched outside it.
-- ESCAPE always leaves the submap, even if the plugin has died.
hl.define_submap("quickswitch", function()
  local qs = function(name) return hl.dsp.global("ewweberlin.quickswitch:" .. name) end
  hl.bind("SUPER + TAB", qs("next"), { repeating = true })
  hl.bind("SUPER + SHIFT + TAB", qs("prev"), { repeating = true })
  hl.bind("SUPER + LEFT", qs("focus-left"), { repeating = true })
  hl.bind("SUPER + RIGHT", qs("focus-right"), { repeating = true })
  hl.bind("SUPER + UP", qs("focus-up"), { repeating = true })
  hl.bind("SUPER + DOWN", qs("focus-down"), { repeating = true })
  hl.bind("SUPER + Q", qs("quit"))
  for _, keys in ipairs({ "ESCAPE", "SUPER + ESCAPE" }) do
    hl.bind(keys, function()
      hl.dispatch(qs("cancel"))
      hl.dispatch(hl.dsp.submap("reset"))
    end)
  end
end)

hl.layer_rule({ match = { namespace = "ewweberlin.quickswitch" }, no_anim = true })
