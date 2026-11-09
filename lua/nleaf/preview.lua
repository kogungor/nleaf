---The single Leaf preview session: start, hide/show, move, retarget, close.

local api = vim.api
local uv = vim.uv or vim.loop
local config = require("nleaf.config")
local layout = require("nleaf.layout")
local sync = require("nleaf.sync")

local M = {}

---@class nleaf.Session
---@field buf integer Terminal buffer running Leaf.
---@field win? integer Window showing `buf` (nil while hidden).
---@field job integer
---@field layout string
---@field kind "buffer"|"picker"|"diff"
---@field src_buf? integer Previewed buffer (kind == "buffer").
---@field path? string File Leaf watches (shadow file in live sync).
---@field sync? nleaf.SyncHandle
---@field title string
---@field argv string[]
---@field group integer
---@field dead? boolean Leaf exited with an error; its output is still in `buf`.
---@field closing? boolean

---@type nleaf.Session?
local S = nil

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.ERROR, { title = "nleaf" })
end

local function realpath(path)
  return uv.fs_realpath(path) or path
end

---@return boolean
local function is_visible()
  return S ~= nil and S.win ~= nil and api.nvim_win_is_valid(S.win) and api.nvim_win_get_buf(S.win) == S.buf
end
M.is_visible = is_visible

---Buffers that :NLeaf toggle and `follow` preview.
---@param buf integer
function M.is_previewable(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  return vim.tbl_contains(config.get().filetypes, vim.bo[buf].filetype)
end

---Build the Leaf argv (and live-sync handle) for a target. Nothing is torn down on failure.
---@return table? spec
---@return string? err
local function prepare(target, cfg)
  local argv = { cfg.cmd }
  vim.list_extend(argv, cfg.args)
  local spec = { kind = target.kind, argv = argv }

  if target.kind == "buffer" then
    local buf = target.src_buf
    if not (buf and api.nvim_buf_is_valid(buf)) or vim.bo[buf].buftype ~= "" then
      return nil, "this buffer cannot be previewed"
    end
    local name = api.nvim_buf_get_name(buf)
    if cfg.sync == "save" then
      if name == "" or vim.fn.filereadable(name) ~= 1 then
        return nil, "sync = 'save' needs a file on disk: write the buffer or run :NLeaf sync live"
      end
      spec.path = realpath(name)
    else
      spec.sync = sync.attach(buf, cfg.debounce)
      spec.path = spec.sync.path
    end
    spec.src_buf = buf
    vim.list_extend(argv, { "--watch", "--", spec.path })
    local label = name ~= "" and vim.fn.fnamemodify(name, ":t") or "untitled"
    spec.title = ("Leaf · %s%s"):format(label, cfg.sync == "live" and " · live" or "")
  elseif target.kind == "picker" then
    argv[#argv + 1] = "--watch"
    spec.title = "Leaf · picker"
  elseif target.kind == "diff" then
    argv[#argv + 1] = "--diff"
    vim.list_extend(argv, target.args or {})
    spec.title = "Leaf · diff"
  else
    return nil, "unknown preview kind: " .. tostring(target.kind)
  end
  return spec
end

---Start Leaf as a terminal job inside `win` (which already shows a fresh buffer).
local function spawn(argv, win)
  local cfg = config.get()
  local opts = {
    on_exit = function(job, code)
      vim.schedule(function()
        M._on_exit(job, code)
      end)
    end,
  }
  if cfg.editor_bridge then
    opts.env = require("nleaf.bridge").env()
    opts.clear_env = true
  end
  local job
  api.nvim_win_call(win, function()
    if vim.fn.has("nvim-0.11") == 1 then
      opts.term = true
      job = vim.fn.jobstart(argv, opts)
    else
      job = vim.fn.termopen(argv, opts)
    end
  end)
  return job
end

-- Mouse wheel ----------------------------------------------------------------
--
-- Neovim forwards mouse events to a terminal job only while that terminal is focused and in
-- Terminal mode. Over a side preview you usually scroll from the source buffer (or with the
-- preview in Normal mode), and nothing reaches Leaf. These mappings send the wheel to Leaf
-- as an SGR mouse event when the pointer is over the preview, and keep the default behaviour
-- everywhere else. They are only installed where the user has no wheel mapping of their own.

local WHEEL = { ["<ScrollWheelUp>"] = 64, ["<ScrollWheelDown>"] = 65 }
local WHEEL_MODES = { "n", "i", "x" }
local WHEEL_DESC = "nleaf: scroll the Leaf preview under the mouse"
local wheel_installed = false

---Expr-mapping body: forward the wheel to Leaf when the pointer is over the preview.
---@param lhs string
---@return string keys
function M._wheel(lhs)
  local sess = S
  if sess and not sess.dead and is_visible() then
    local pos = vim.fn.getmousepos()
    if pos.winid == sess.win then
      local seq = ("\27[<%d;%d;%dM"):format(WHEEL[lhs], math.max(1, pos.wincol), math.max(1, pos.winrow))
      pcall(vim.fn.chansend, sess.job, seq)
      return ""
    end
  end
  return lhs
end

local function install_wheel()
  if wheel_installed or not config.get().mouse_scroll then
    return
  end
  wheel_installed = true
  for lhs in pairs(WHEEL) do
    for _, mode in ipairs(WHEEL_MODES) do
      if vim.fn.maparg(lhs, mode) == "" then
        vim.keymap.set(mode, lhs, function()
          return M._wheel(lhs)
        end, { expr = true, replace_keycodes = true, desc = WHEEL_DESC })
      end
    end
  end
end

local function uninstall_wheel()
  if not wheel_installed then
    return
  end
  wheel_installed = false
  for lhs in pairs(WHEEL) do
    for _, mode in ipairs(WHEEL_MODES) do
      local map = vim.fn.maparg(lhs, mode, false, true)
      if map.desc == WHEEL_DESC and map.buffer == 0 then
        pcall(vim.keymap.del, mode, lhs)
      end
    end
  end
end

local function attach_autocmds(sess)
  local cfg = config.get()
  sess.group = api.nvim_create_augroup("nleaf.session", { clear = true })

  api.nvim_create_autocmd("BufWipeout", {
    group = sess.group,
    buffer = sess.buf,
    callback = function()
      vim.schedule(function()
        if S == sess then
          M.close()
        end
      end)
    end,
  })
  if sess.src_buf then
    api.nvim_create_autocmd("BufWipeout", {
      group = sess.group,
      buffer = sess.src_buf,
      callback = function()
        vim.schedule(function()
          if S == sess then
            M.close()
          end
        end)
      end,
    })
  end
  if cfg.auto_insert then
    api.nvim_create_autocmd("BufEnter", {
      group = sess.group,
      buffer = sess.buf,
      callback = function()
        if S == sess and not sess.dead then
          vim.cmd.startinsert()
        end
      end,
    })
  end
  if cfg.keys.hide then
    vim.keymap.set("n", cfg.keys.hide, M.hide, { buffer = sess.buf, nowait = true, desc = "nleaf: hide preview" })
  end
end

---Stop Leaf and release everything a session owns.
local function teardown(sess, keep_win)
  sess.closing = true
  pcall(api.nvim_del_augroup_by_id, sess.group)
  if sess.sync then
    sync.detach(sess.sync)
  end
  pcall(vim.fn.jobstop, sess.job)
  if not keep_win and sess.win then
    layout.close(sess.win, sess.src_buf)
  end
  if api.nvim_buf_is_valid(sess.buf) then
    pcall(api.nvim_buf_delete, sess.buf, { force = true })
  end
end

---Start (or replace) the preview. A visible preview in the same layout keeps its window.
---@param target { kind: "buffer"|"picker"|"diff", src_buf?: integer, args?: string[] }
---@param want_layout? string
---@return nleaf.Session?
local function start(target, want_layout)
  local cfg = config.get()
  if vim.fn.executable(cfg.cmd) ~= 1 then
    notify(("Leaf executable not found: %s (see :checkhealth nleaf)"):format(cfg.cmd))
    return nil
  end
  local spec, err = prepare(target, cfg)
  if not spec then
    notify(err)
    return nil
  end

  local lay = want_layout or (S and S.layout) or cfg.layout
  local reuse = is_visible() and S.layout == lay and S.win or nil
  local old = S
  S = nil

  local buf = api.nvim_create_buf(false, true)
  local win = reuse
  if win then
    api.nvim_win_set_buf(win, buf)
    if lay == "float" then
      pcall(api.nvim_win_set_config, win, layout.float_config(cfg, spec.title))
    end
  end
  if old then
    teardown(old, reuse ~= nil)
  end
  if not win then
    local enter = lay == "float" or lay == "tab" or cfg.focus
    win = layout.open(buf, lay, cfg, { enter = enter, title = spec.title })
  end

  local job = spawn(spec.argv, win)
  if not job or job <= 0 then
    if spec.sync then
      sync.detach(spec.sync)
    end
    layout.close(win, spec.src_buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    notify(("failed to start %s"):format(cfg.cmd))
    return nil
  end
  vim.bo[buf].filetype = "nleaf"

  ---@type nleaf.Session
  local sess = {
    buf = buf,
    win = win,
    job = job,
    layout = lay,
    kind = spec.kind,
    src_buf = spec.src_buf,
    path = spec.path,
    sync = spec.sync,
    title = spec.title,
    argv = spec.argv,
    group = 0,
  }
  S = sess
  attach_autocmds(sess)
  install_wheel()
  if cfg.auto_insert and api.nvim_get_current_win() == win then
    vim.cmd.startinsert()
  end
  return sess
end

function M._on_exit(job, code)
  local sess = S
  if not sess or sess.job ~= job or sess.closing then
    return
  end
  if code == 0 then
    -- Leaf was quit from inside (q): the preview is done.
    return M.close()
  end
  sess.dead = true
  if is_visible() and api.nvim_get_current_win() == sess.win then
    vim.cmd.stopinsert()
  end
  local key = config.get().keys.hide
  notify(
    ("Leaf exited with code %d. Its output stays in the preview; close it with %s."):format(
      code,
      key and ("`" .. key .. "`") or ":NLeaf close"
    )
  )
end

---Stop Leaf and close the preview.
function M.close()
  local sess = S
  S = nil
  if sess then
    teardown(sess, false)
  end
  uninstall_wheel()
end

---Hide the preview window; Leaf keeps running and keeps its scroll position.
function M.hide()
  local sess = S
  if not sess then
    return
  end
  if sess.dead then
    return M.close()
  end
  if is_visible() then
    if api.nvim_get_current_win() == sess.win then
      vim.cmd.stopinsert()
    end
    layout.close(sess.win, sess.src_buf)
  end
  sess.win = nil
end

---Show a hidden preview, optionally in another layout.
---@param want_layout? string
function M.show(want_layout)
  local sess = S
  if not sess then
    return
  end
  if is_visible() then
    if want_layout and want_layout ~= sess.layout then
      M.move(want_layout)
    end
    return
  end
  local cfg = config.get()
  sess.layout = want_layout or sess.layout
  local enter = sess.layout == "float" or sess.layout == "tab" or cfg.focus
  sess.win = layout.open(sess.buf, sess.layout, cfg, { enter = enter, title = sess.title })
  if enter and cfg.auto_insert and not sess.dead then
    vim.cmd.startinsert()
  end
end

---Move the running preview to another layout without restarting Leaf.
---@param want_layout string
function M.move(want_layout)
  local sess = S
  if not sess then
    return
  end
  if is_visible() then
    if sess.layout == want_layout then
      return
    end
    layout.close(sess.win, sess.src_buf)
    sess.win = nil
  end
  M.show(want_layout)
end

---Preview a specific buffer (any normal buffer, regardless of filetype).
---@param opts? { buf?: integer, layout?: string }
function M.open(opts)
  opts = opts or {}
  local buf = opts.buf or api.nvim_get_current_buf()
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  return start({ kind = "buffer", src_buf = buf }, opts.layout)
end

---@param opts? { layout?: string }
function M.picker(opts)
  return start({ kind = "picker" }, (opts or {}).layout)
end

---@param args? string[] Arguments for `leaf --diff` (refs, `cached`, `-- path`, ...).
---@param opts? { layout?: string }
function M.diff(args, opts)
  return start({ kind = "diff", args = args or {} }, (opts or {}).layout)
end

---Toggle the preview for the current buffer.
---
--- * Inside the preview: hide it (or move it when another layout is requested).
--- * Preview of this buffer (or of a picker/diff while on a non-previewable buffer):
---   hide it when visible, show it when hidden. A different `layout` moves it instead.
--- * Another previewable buffer: retarget the preview to it.
--- * Nothing to preview: open Leaf's fuzzy picker.
---@param opts? { layout?: string }
function M.toggle(opts)
  opts = opts or {}
  local cur = api.nvim_get_current_buf()
  local sess = S

  if sess and sess.dead then
    local inside = cur == sess.buf
    M.close()
    if inside then
      return
    end
    sess = nil
  end

  if sess and cur == sess.buf then
    if opts.layout and opts.layout ~= sess.layout then
      return M.move(opts.layout)
    end
    return M.hide()
  end

  local wanted = M.is_previewable(cur) and cur or nil
  if sess then
    local same
    if sess.kind == "buffer" then
      same = wanted == nil or wanted == sess.src_buf
    else
      same = wanted == nil
    end
    if same then
      if is_visible() then
        if opts.layout and opts.layout ~= sess.layout then
          return M.move(opts.layout)
        end
        return M.hide()
      end
      return M.show(opts.layout)
    end
  end

  if wanted then
    return start({ kind = "buffer", src_buf = wanted }, opts.layout)
  end
  return start({ kind = "picker" }, opts.layout)
end

---Restart a buffer preview with the current configuration (e.g. after changing `sync`).
function M.restart()
  local sess = S
  if sess and sess.kind == "buffer" and sess.src_buf and api.nvim_buf_is_valid(sess.src_buf) then
    start({ kind = "buffer", src_buf = sess.src_buf })
  end
end

local function find_window(buf, exclude)
  local candidates = {}
  vim.list_extend(candidates, vim.fn.win_findbuf(buf))
  local prevnr = vim.fn.winnr("#")
  if prevnr > 0 then -- win_getid(0) would mean the current window
    candidates[#candidates + 1] = vim.fn.win_getid(prevnr)
  end
  vim.list_extend(candidates, api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(candidates) do
    if win ~= exclude and api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative == "" then
      local wbuf = api.nvim_win_get_buf(win)
      if wbuf == buf or vim.bo[wbuf].buftype == "" then
        return win
      end
    end
  end
end

---Jump to `line` of `path` in this Neovim. Called through the editor bridge (Leaf's Ctrl+E).
---@param path string
---@param line integer
function M.jump(path, line)
  local sess = S
  local target = realpath(path)
  local buf
  if sess and sess.src_buf and sess.path and realpath(sess.path) == target and api.nvim_buf_is_valid(sess.src_buf) then
    buf = sess.src_buf -- live sync: the shadow file stands for this buffer
  else
    buf = vim.fn.bufadd(target)
    vim.bo[buf].buflisted = true
  end

  local preview_win = is_visible() and sess.win or nil
  if api.nvim_get_current_win() == preview_win then
    vim.cmd.stopinsert()
  end
  if sess and preview_win and sess.layout == "float" then
    M.hide()
    preview_win = nil
  end

  local win = find_window(buf, preview_win)
  if not win then
    vim.cmd("botright vsplit")
    win = api.nvim_get_current_win()
  end
  api.nvim_set_current_win(win)
  if api.nvim_win_get_buf(win) ~= buf then
    api.nvim_win_set_buf(win, buf)
  end
  local last = api.nvim_buf_line_count(buf)
  api.nvim_win_set_cursor(win, { math.max(1, math.min(line or 1, last)), 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

---@return table
function M.state()
  local sess = S
  if not sess then
    return { active = false, visible = false }
  end
  return {
    active = true,
    visible = is_visible(),
    layout = sess.layout,
    kind = sess.kind,
    source = sess.src_buf,
    path = sess.path,
    sync = sess.kind == "buffer" and (sess.sync and "live" or "save") or nil,
    buf = sess.buf,
    win = is_visible() and sess.win or nil,
    job = sess.job,
    argv = vim.deepcopy(sess.argv),
    dead = sess.dead == true,
  }
end

local group = api.nvim_create_augroup("nleaf", { clear = true })

api.nvim_create_autocmd("BufEnter", {
  group = group,
  desc = "nleaf: follow the buffer you are editing",
  callback = function(ev)
    local sess = S
    if not sess or sess.kind ~= "buffer" or sess.dead or not config.get().follow then
      return
    end
    if ev.buf == sess.buf or ev.buf == sess.src_buf or not is_visible() or not M.is_previewable(ev.buf) then
      return
    end
    vim.schedule(function()
      if S == sess and is_visible() and api.nvim_get_current_buf() == ev.buf then
        start({ kind = "buffer", src_buf = ev.buf })
      end
    end)
  end,
})

api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    if S and is_visible() and S.layout == "float" then
      pcall(api.nvim_win_set_config, S.win, layout.float_config(config.get(), S.title))
    end
  end,
})

api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    M.close()
  end,
})

return M
