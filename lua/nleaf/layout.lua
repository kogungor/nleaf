---Window placement for the preview: float, edge splits or a tab.

local api = vim.api

local M = {}

local SPLIT_DIRECTION = { right = "right", left = "left", bottom = "below", top = "above" }

---Fraction (<= 1) of `total`, or an absolute size clamped to `total`.
local function resolve(size, total)
  if size <= 1 then
    return math.max(1, math.floor(total * size + 0.5))
  end
  return math.max(1, math.min(math.floor(size), total))
end

local function has_border(border)
  return border ~= nil and border ~= "" and border ~= "none"
end

local function style(win, layout)
  local opts = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    spell = false,
    list = false,
    cursorline = false,
    colorcolumn = "",
    scrolloff = 0,
    sidescrolloff = 0,
  }
  if layout == "left" or layout == "right" then
    opts.winfixwidth = true
  elseif layout == "top" or layout == "bottom" then
    opts.winfixheight = true
  end
  for name, value in pairs(opts) do
    vim.wo[win][0][name] = value
  end
end

---@param cfg nleaf.Config
---@param title? string
---@return table nvim_open_win() config
function M.float_config(cfg, title)
  local f = cfg.float
  local bordered = has_border(f.border)
  local pad = bordered and 2 or 0
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = resolve(f.width, columns - pad)
  local height = resolve(f.height, lines - pad)
  local conf = {
    relative = "editor",
    style = "minimal",
    border = f.border,
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height - pad) / 2)),
    col = math.max(0, math.floor((columns - width - pad) / 2)),
    zindex = 50,
  }
  if f.title and bordered and title then
    conf.title = " " .. title .. " "
    conf.title_pos = "center"
  end
  return conf
end

---Show `buf` in a new window for `layout`.
---@param buf integer
---@param layout string
---@param cfg nleaf.Config
---@param opts { enter: boolean, title?: string }
---@return integer win
function M.open(buf, layout, cfg, opts)
  local win
  if layout == "float" then
    win = api.nvim_open_win(buf, opts.enter, M.float_config(cfg, opts.title))
  elseif layout == "tab" then
    vim.cmd("tabnew")
    win = api.nvim_get_current_win()
    local placeholder = api.nvim_get_current_buf()
    api.nvim_win_set_buf(win, buf)
    if placeholder ~= buf and api.nvim_buf_is_valid(placeholder) then
      pcall(api.nvim_buf_delete, placeholder, { force = true })
    end
  else
    local vertical = layout == "left" or layout == "right"
    local conf = { split = SPLIT_DIRECTION[layout], win = -1 }
    if vertical then
      conf.width = resolve(cfg.size, vim.o.columns)
    else
      conf.height = resolve(cfg.size, vim.o.lines - vim.o.cmdheight)
    end
    win = api.nvim_open_win(buf, opts.enter, conf)
  end
  style(win, layout)
  return win
end

---Close `win`. When it is the last window, show `fallback_buf` (or an empty buffer) instead.
---@param win? integer
---@param fallback_buf? integer
function M.close(win, fallback_buf)
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  if pcall(api.nvim_win_close, win, true) then
    return
  end
  local buf = fallback_buf
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(true, false)
  end
  pcall(api.nvim_win_set_buf, win, buf)
end

return M
