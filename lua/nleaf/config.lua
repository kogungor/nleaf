---nleaf.nvim configuration: defaults, validation and merging.

local M = {}

M.LAYOUTS = { "float", "right", "left", "bottom", "top", "tab" }
M.SYNC_MODES = { "live", "save" }
M.IMAGE_BACKENDS = { "viewim", "snacks", "system" }

---@class nleaf.FloatConfig
---@field width number Fraction of the editor (<= 1) or absolute columns.
---@field height number Fraction of the editor (<= 1) or absolute lines.
---@field border string|string[] Any 'winborder' / nvim_open_win() border value.
---@field title boolean Show "Leaf · <file>" in the border.

---@class nleaf.Config
---@field cmd string Leaf executable.
---@field args string[] Extra arguments for every Leaf invocation (e.g. { "--theme", "forest" }).
---@field layout "float"|"right"|"left"|"bottom"|"top"|"tab"
---@field size number Split size: fraction (<= 1) or absolute columns/lines.
---@field float nleaf.FloatConfig
---@field sync "live"|"save" live: unsaved edits are mirrored; save: Leaf watches the file on disk.
---@field debounce integer Milliseconds to wait after the last edit before mirroring (live sync).
---@field follow boolean Retarget a visible preview when you enter another previewable buffer.
---@field focus boolean Move the cursor into split previews when they open.
---@field auto_insert boolean Enter Terminal-mode when the cursor enters the preview.
---@field filetypes string[] Filetypes :NLeaf previews (others open Leaf's picker).
---@field editor_bridge boolean Leaf's "open in editor" (Ctrl+E) jumps to the line in this Neovim.
---@field keys { hide: string|false } Normal-mode keys inside the preview buffer.
---@field image { backends: string[] } Viewers for :NLeaf image, tried in order.
---@field mouse_scroll boolean The mouse wheel over the preview scrolls Leaf, whatever the focus or mode.
local defaults = {
  cmd = "leaf",
  args = {},
  layout = "right",
  size = 0.45,
  float = { width = 0.85, height = 0.85, border = "rounded", title = true },
  sync = "live",
  debounce = 150,
  follow = true,
  focus = false,
  auto_insert = true,
  filetypes = { "markdown" },
  editor_bridge = true,
  mouse_scroll = true,
  keys = { hide = "q" },
  image = { backends = { "viewim", "snacks", "system" } },
}

-- List-valued options are replaced, never merged index by index.
local LIST_KEYS = { "args", "filetypes" }

local current = vim.deepcopy(defaults)

local function fail(msg)
  error("nleaf: " .. msg, 0)
end

local function is_string_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _, item in pairs(value) do
    if type(item) ~= "string" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function positive(value)
  return type(value) == "number" and value > 0
end

local function validate(cfg)
  if type(cfg.cmd) ~= "string" or cfg.cmd == "" then
    fail("cmd must be a non-empty string")
  end
  if not is_string_list(cfg.args) then
    fail("args must be a list of strings")
  end
  if not vim.tbl_contains(M.LAYOUTS, cfg.layout) then
    fail("layout must be one of: " .. table.concat(M.LAYOUTS, ", "))
  end
  if not positive(cfg.size) then
    fail("size must be a positive number")
  end
  if type(cfg.float) ~= "table" or not positive(cfg.float.width) or not positive(cfg.float.height) then
    fail("float.width and float.height must be positive numbers")
  end
  if not vim.tbl_contains(M.SYNC_MODES, cfg.sync) then
    fail("sync must be one of: " .. table.concat(M.SYNC_MODES, ", "))
  end
  if type(cfg.debounce) ~= "number" or cfg.debounce < 0 then
    fail("debounce must be a number >= 0")
  end
  if not is_string_list(cfg.filetypes) then
    fail("filetypes must be a list of strings")
  end
  for _, key in ipairs({ "follow", "focus", "auto_insert", "editor_bridge", "mouse_scroll" }) do
    if type(cfg[key]) ~= "boolean" then
      fail(key .. " must be a boolean")
    end
  end
  if type(cfg.keys) ~= "table" then
    fail("keys must be a table")
  end
  if cfg.keys.hide ~= false and (type(cfg.keys.hide) ~= "string" or cfg.keys.hide == "") then
    fail("keys.hide must be a key string or false")
  end
  if type(cfg.image) ~= "table" or not is_string_list(cfg.image.backends) or #cfg.image.backends == 0 then
    fail("image.backends must be a non-empty list of: " .. table.concat(M.IMAGE_BACKENDS, ", "))
  end
  for _, name in ipairs(cfg.image.backends) do
    if not vim.tbl_contains(M.IMAGE_BACKENDS, name) then
      fail(("unknown image backend '%s' (use %s)"):format(name, table.concat(M.IMAGE_BACKENDS, ", ")))
    end
  end
end

local function merge(base, opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    fail("options must be a table")
  end
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(base), vim.deepcopy(opts))
  for _, key in ipairs(LIST_KEYS) do
    if opts[key] ~= nil then
      merged[key] = vim.deepcopy(opts[key])
    end
  end
  if type(opts.image) == "table" and opts.image.backends ~= nil then
    merged.image.backends = vim.deepcopy(opts.image.backends)
  end
  validate(merged)
  return merged
end

---Replace the configuration with defaults + `opts`.
---@param opts? table
function M.setup(opts)
  current = merge(defaults, opts)
end

---Change some options on top of the current configuration.
---@param opts table
function M.update(opts)
  current = merge(current, opts)
end

---@return nleaf.Config
function M.get()
  return current
end

---@return nleaf.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

function M.reset()
  current = vim.deepcopy(defaults)
end

return M
