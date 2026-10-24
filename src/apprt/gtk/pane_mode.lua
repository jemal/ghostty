-- Optional personal bindings. Older binaries safely skip this block.
if ghostty.stack then
  local table_name = "pane"
  ghostty.action {
    name = "pane_mode",
    title = "Pane Mode",
    run = function()
      if ghostty.invoke("activate_key_table_once:" .. table_name) then
        ghostty.toast("Pane: HJKL stack · Shift+HJKL unstack · N new · U all · Esc cancel")
      end
    end,
  }
  for _, key_table in ipairs { "", "vim" } do
    ghostty.bind("alt+p", "pane_mode", key_table ~= "" and { table = key_table } or nil)
  end
  local opts = { table = table_name }
  for key, direction in pairs { h = "left", j = "down", k = "up", l = "right" } do
    ghostty.bind(key, function()
      if not ghostty.invoke("stack_pane:" .. direction) then
        ghostty.toast("No compatible neighboring tile to stack")
      end
    end, opts)
    ghostty.bind("shift+" .. key, function()
      if not ghostty.invoke("unstack_pane:" .. direction) then
        ghostty.toast("This pane is not in a stack")
      end
    end, opts)
  end
  ghostty.bind("n", function()
    if not ghostty.invoke("new_stacked_terminal") then ghostty.toast("Cannot add a stack member here") end
  end, opts)
  ghostty.bind("u", function()
    if not ghostty.invoke("unstack_all") then ghostty.toast("This pane is not in a stack") end
  end, opts)
  -- A once table pops automatically after any valid binding, including these.
  ghostty.bind("escape", function() end, opts)
  ghostty.bind("catch_all", function() end, opts)
end
