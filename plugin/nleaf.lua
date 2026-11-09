-- nleaf: commands and <Plug> mappings only. No default keymaps; modules load on first use.

if vim.g.loaded_nleaf then
  return
end
vim.g.loaded_nleaf = true

local LAYOUTS = { "float", "right", "left", "bottom", "top", "tab" }
local SUBCOMMANDS = { "close", "picker", "diff", "sync", "image" }
local IMAGE_BACKENDS = { "viewim", "snacks", "system" }

local function complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local index = #words + (cmdline:match("%s$") and 1 or 0)
  local candidates
  if index <= 2 then
    candidates = vim.list_extend(vim.deepcopy(LAYOUTS), SUBCOMMANDS)
  elseif index == 3 and words[2] == "sync" then
    candidates = { "live", "save" }
  elseif index == 3 and words[2] == "picker" then
    candidates = LAYOUTS
  elseif index == 3 and words[2] == "image" then
    candidates = IMAGE_BACKENDS
  else
    return {}
  end
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates)
end

vim.api.nvim_create_user_command("NLeaf", function(cmd)
  local nleaf = require("nleaf")
  local args = cmd.fargs
  local sub = args[1]
  if sub == nil then
    nleaf.toggle()
  elseif vim.tbl_contains(LAYOUTS, sub) then
    nleaf.toggle({ layout = sub })
  elseif sub == "close" then
    nleaf.close()
  elseif sub == "picker" then
    nleaf.picker({ layout = args[2] })
  elseif sub == "diff" then
    nleaf.diff(vim.list_slice(args, 2))
  elseif sub == "image" then
    nleaf.image({ backend = args[2] })
  elseif sub == "sync" then
    if args[2] == nil then
      local mode = require("nleaf.config").get().sync
      vim.notify("nleaf: sync = " .. mode, vim.log.levels.INFO, { title = "nleaf" })
    else
      nleaf.set_sync(args[2])
    end
  else
    vim.notify(("nleaf: unknown subcommand '%s'"):format(sub), vim.log.levels.ERROR, { title = "nleaf" })
  end
end, {
  nargs = "*",
  complete = complete,
  desc = "Leaf Markdown preview: [float|right|left|bottom|top|tab|close|picker|diff|sync|image]",
})

vim.keymap.set("n", "<Plug>(NLeafImage)", function()
  require("nleaf").image()
end, { desc = "nleaf: show the image under the cursor" })

vim.keymap.set({ "n", "t" }, "<Plug>(NLeafToggle)", function()
  require("nleaf").toggle()
end, { desc = "nleaf: toggle preview" })

vim.keymap.set({ "n", "t" }, "<Plug>(NLeafClose)", function()
  require("nleaf").close()
end, { desc = "nleaf: close preview" })

for _, layout in ipairs(LAYOUTS) do
  local name = layout:sub(1, 1):upper() .. layout:sub(2)
  vim.keymap.set({ "n", "t" }, ("<Plug>(NLeaf%s)"):format(name), function()
    require("nleaf").toggle({ layout = layout })
  end, { desc = ("nleaf: preview in %s layout"):format(layout) })
end
