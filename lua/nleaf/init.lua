---nleaf: Leaf Markdown preview for Neovim.

local M = {}

local function preview()
  return require("nleaf.preview")
end

local function check_layout(layout)
  if layout ~= nil and not vim.tbl_contains(require("nleaf.config").LAYOUTS, layout) then
    vim.notify(("nleaf: unknown layout '%s'"):format(tostring(layout)), vim.log.levels.ERROR, { title = "nleaf" })
    return false
  end
  return true
end

---Configure nleaf. Optional: the defaults work without calling it.
---@param opts? table See |nleaf-config|.
function M.setup(opts)
  require("nleaf.config").setup(opts)
end

---Toggle the preview of the current buffer.
---@param opts? { layout?: "float"|"right"|"left"|"bottom"|"top"|"tab" }
function M.toggle(opts)
  if opts and not check_layout(opts.layout) then
    return
  end
  return preview().toggle(opts)
end

---Preview a buffer (default: current), regardless of its filetype.
---@param opts? { buf?: integer, layout?: string }
function M.open(opts)
  if opts and not check_layout(opts.layout) then
    return
  end
  return preview().open(opts)
end

---Open Leaf's fuzzy file picker; the chosen file is watched.
---@param opts? { layout?: string }
function M.picker(opts)
  if opts and not check_layout(opts.layout) then
    return
  end
  return preview().picker(opts)
end

---Open Leaf's git diff viewer.
---@param args? string[] e.g. { "HEAD~1" }, { "cached" }, { "main..feature" }
---@param opts? { layout?: string }
function M.diff(args, opts)
  if opts and not check_layout(opts.layout) then
    return
  end
  return preview().diff(args, opts)
end

---Show the image under the cursor with the first available viewer (|nleaf-image|).
---@param opts? { backend?: "viewim"|"snacks"|"system" }
---@return string? backend Name of the viewer that opened it.
function M.image(opts)
  return require("nleaf.image").show(opts)
end

---Hide the preview window; Leaf keeps running.
function M.hide()
  return preview().hide()
end

---Show a hidden preview, optionally in another layout.
---@param layout? string
function M.show(layout)
  if not check_layout(layout) then
    return
  end
  return preview().show(layout)
end

---Stop Leaf and close the preview.
function M.close()
  return preview().close()
end

---Switch between live (unsaved edits) and save (file on disk) sync. Restarts a running preview.
---@param mode "live"|"save"
function M.set_sync(mode)
  local ok, err = pcall(require("nleaf.config").update, { sync = mode })
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = "nleaf" })
    return
  end
  preview().restart()
end

---@return { active: boolean, visible: boolean, layout?: string, kind?: string, source?: integer, path?: string, sync?: string, buf?: integer, win?: integer, job?: integer, argv?: string[], dead?: boolean }
function M.state()
  return preview().state()
end

return M
