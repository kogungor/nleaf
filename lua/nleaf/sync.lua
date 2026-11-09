---Live sync: mirror a buffer's (possibly unsaved) text into a private file that Leaf watches.
---
---Leaf only renders files and reloads them when their mtime or size changes. Writing the
---buffer to a "shadow" file in Neovim's temp directory gives a live preview without ever
---touching the real file.

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

-- Each handle gets its own augroup: a restart attaches the new handle before the old one is
-- detached, and a shared group name would let the old detach delete the new autocmds.
local seq = 0

---@class nleaf.SyncHandle
---@field src_buf integer
---@field dir string
---@field path string Canonical path of the shadow file.
---@field debounce integer
---@field timer uv.uv_timer_t
---@field group integer
---@field closed boolean

local function realpath(path)
  return uv.fs_realpath(path) or path
end

---Write the buffer atomically (temp file + rename) so Leaf never reads a half-written file.
---@param h nleaf.SyncHandle
function M.write(h)
  if h.closed or not api.nvim_buf_is_valid(h.src_buf) then
    return
  end
  local lines = api.nvim_buf_get_lines(h.src_buf, 0, -1, false)
  local tmp = h.path .. ".nleaf-tmp"
  if vim.fn.writefile(lines, tmp) ~= 0 then
    return
  end
  if not uv.fs_rename(tmp, h.path) then
    pcall(uv.fs_unlink, tmp)
  end
end

---@param h nleaf.SyncHandle
function M.schedule(h)
  if h.closed then
    return
  end
  if h.debounce <= 0 then
    return M.write(h)
  end
  h.timer:stop()
  h.timer:start(
    h.debounce,
    0,
    vim.schedule_wrap(function()
      M.write(h)
    end)
  )
end

---Start mirroring `src_buf`.
---@param src_buf integer
---@param debounce integer
---@return nleaf.SyncHandle
function M.attach(src_buf, debounce)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = realpath(dir)
  local name = api.nvim_buf_get_name(src_buf)
  local base = name ~= "" and vim.fn.fnamemodify(name, ":t") or "untitled.md"
  seq = seq + 1

  ---@type nleaf.SyncHandle
  local h = {
    src_buf = src_buf,
    dir = dir,
    path = dir .. "/" .. base,
    debounce = debounce,
    timer = assert(uv.new_timer()),
    group = api.nvim_create_augroup(("nleaf.sync.%d.%d"):format(src_buf, seq), { clear = true }),
    closed = false,
  }
  M.write(h)

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost", "BufReadPost" }, {
    group = h.group,
    buffer = src_buf,
    desc = "nleaf: mirror buffer for live preview",
    callback = function()
      M.schedule(h)
    end,
  })
  return h
end

---Stop mirroring and delete the shadow file.
---@param h nleaf.SyncHandle
function M.detach(h)
  if h.closed then
    return
  end
  h.closed = true
  h.timer:stop()
  if not h.timer:is_closing() then
    h.timer:close()
  end
  pcall(api.nvim_del_augroup_by_id, h.group)
  vim.fn.delete(h.dir, "rf")
end

return M
