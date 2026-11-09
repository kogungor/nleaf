-- nleaf test suite. Run from the repository root:
--
--   nvim --clean -l tests/run.lua
--
-- Uses tests/bin/leaf, a fake Leaf that logs its argv/env and idles, so no real Leaf is needed.

local api = vim.api
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.env.PATH = root .. "/tests/bin" .. (vim.fn.has("win32") == 1 and ";" or ":") .. vim.env.PATH
vim.o.columns = 160
vim.o.lines = 50
vim.cmd("filetype on")
vim.cmd("runtime plugin/nleaf.lua")

local nleaf = require("nleaf")
local config = require("nleaf.config")

local log = vim.fn.tempname()
vim.env.NLEAF_TEST_LOG = log

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level }
end

local function wait(cond, ms)
  return vim.wait(ms or 3000, cond, 10)
end

local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      ("%s\n  expected: %s\n    actual: %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

local function ok(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
end

---Wait for `cond` (default 3 s) and fail with `msg` if it never holds.
local function eventually(cond, msg, ms)
  if not wait(cond, ms) then
    error(msg or "condition not met in time", 2)
  end
end

---Leaf launches recorded by the fake binary (ignores `--version` probes).
local function launches()
  local out, cur = {}, nil
  if vim.fn.filereadable(log) == 0 then
    return out
  end
  for _, line in ipairs(vim.fn.readfile(log)) do
    if line == "BEGIN" then
      cur = { argv = {} }
    elseif line == "END" then
      if cur and cur.argv[1] ~= "--version" then
        out[#out + 1] = cur
      end
      cur = nil
    elseif cur then
      local parts = vim.split(line, "\t", { plain = true })
      local key = table.remove(parts, 1)
      if key == "ARGV" then
        cur.argv = parts
      else
        cur[key] = parts[1] or ""
      end
    end
  end
  return out
end

---Port of Leaf's split_editor_cmd()/tokenize_args() (src/editor.rs).
local function leaf_split(cmd)
  cmd = vim.trim(cmd)
  local bin, rest
  local first = cmd:sub(1, 1)
  if first == '"' or first == "'" then
    local close = cmd:find(first, 2, true)
    bin, rest = cmd:sub(2, close - 1), cmd:sub(close + 1)
  else
    bin, rest = cmd:match("^(%S+)(.*)$")
  end
  local out, cur, single, double = { bin }, "", false, false
  for c in rest:gmatch(".") do
    if c == "'" and not double then
      single = not single
    elseif c == '"' and not single then
      double = not double
    elseif c:match("%s") and not single and not double then
      if cur ~= "" then
        out[#out + 1] = cur
        cur = ""
      end
    else
      cur = cur .. c
    end
  end
  if cur ~= "" then
    out[#out + 1] = cur
  end
  return out
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = uv.fs_realpath(dir)

local function file(name, lines)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines or { "# " .. name }, path)
  return path
end

local function edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "" and path:match("%.md$") then
    vim.bo[buf].filetype = "markdown"
  end
  return buf
end

local function shadow_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

local function reset()
  nleaf.close()
  vim.env.FAKE_LEAF_EXIT = nil
  vim.env.KITTY_PID = nil
  config.reset()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.fn.writefile({}, log)
  notes = {}
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

test("config validates options and replaces lists", function()
  ok(not pcall(config.setup, { layout = "diagonal" }), "bad layout rejected")
  ok(not pcall(config.setup, { sync = "sometimes" }), "bad sync rejected")
  ok(not pcall(config.setup, { args = "--theme forest" }), "args must be a list")
  config.setup({ filetypes = { "quarto" }, args = { "--theme", "forest" } })
  eq(config.get().filetypes, { "quarto" })
  eq(config.get().args, { "--theme", "forest" })
  eq(config.get().layout, "right", "other defaults are kept")
end)

test("toggle opens a live preview in a right split and keeps focus", function()
  local path = file("a.md", { "# A", "", "hello" })
  local src = edit(path)
  local srcwin = api.nvim_get_current_win()
  nleaf.toggle()
  local st = nleaf.state()
  ok(st.visible, "preview visible")
  eq(st.layout, "right")
  eq(st.sync, "live")
  eq(st.source, src)
  eq(api.nvim_get_current_win(), srcwin, "focus stays in the source window")
  ok(api.nvim_win_get_position(st.win)[2] > 0, "preview is right of the source")
  local width = api.nvim_win_get_width(st.win)
  ok(math.abs(width - 72) <= 1, "45% of 160 columns, got " .. width)
  ok(st.path ~= path and vim.fn.fnamemodify(st.path, ":t") == "a.md", "Leaf watches a shadow copy")
  eq(vim.fn.readfile(st.path), { "# A", "", "hello" })
  eventually(function()
    return #launches() == 1
  end, "Leaf started")
  eq(launches()[1].argv, { "--watch", "--", st.path })
end)

test("live sync mirrors unsaved edits without writing the file", function()
  local path = file("a.md", { "# A" })
  local src = edit(path)
  nleaf.toggle()
  local shadow = nleaf.state().path
  api.nvim_buf_set_lines(src, -1, -1, false, { "typed but not saved" })
  api.nvim_exec_autocmds("TextChangedI", { buffer = src })
  eventually(function()
    return vim.fn.readfile(shadow)[2] == "typed but not saved"
  end, "shadow file updated", 2000)
  eq(vim.fn.readfile(path), { "# A" }, "real file untouched")
  ok(vim.bo[src].modified, "buffer still modified")
end)

test("restarting a live preview of the same buffer keeps live sync working", function()
  local src = edit(file("a.md", { "# A" }))
  nleaf.toggle()
  local first = nleaf.state()
  nleaf.open() -- same buffer: new Leaf process, new shadow file
  local second = nleaf.state()
  ok(second.job ~= first.job and second.path ~= first.path, "restarted with a new shadow file")
  api.nvim_buf_set_lines(src, -1, -1, false, { "after restart" })
  api.nvim_exec_autocmds("TextChanged", { buffer = src })
  eventually(function()
    return vim.fn.readfile(second.path)[2] == "after restart"
  end, "new shadow file still follows the buffer")
end)

test("toggle hides and shows the same Leaf process", function()
  edit(file("a.md"))
  nleaf.toggle()
  local st = nleaf.state()
  nleaf.toggle()
  ok(not nleaf.state().visible and nleaf.state().active, "hidden but running")
  eq(vim.fn.jobwait({ st.job }, 0)[1], -1, "Leaf still running")
  nleaf.toggle()
  local again = nleaf.state()
  ok(again.visible, "visible again")
  eq(again.job, st.job)
  eq(again.buf, st.buf)
  eventually(function()
    return #launches() == 1
  end, "Leaf started once")
  vim.wait(100)
  eq(#launches(), 1, "no restart")
end)

test("toggling from inside the preview hides it instead of restarting", function()
  edit(file("a.md"))
  nleaf.toggle()
  local st = nleaf.state()
  api.nvim_set_current_win(st.win)
  nleaf.toggle()
  local after = nleaf.state()
  ok(not after.visible, "hidden")
  eq(after.job, st.job)
  eq(after.kind, "buffer")
end)

test("q in the preview's normal mode hides it", function()
  config.setup({ auto_insert = false })
  edit(file("a.md"))
  nleaf.toggle()
  api.nvim_set_current_win(nleaf.state().win)
  api.nvim_feedkeys("q", "x", false)
  ok(not nleaf.state().visible, "hidden")
  ok(nleaf.state().active, "still running")
end)

test("follow retargets the visible preview to the buffer you enter", function()
  edit(file("a.md"))
  nleaf.toggle()
  local first = nleaf.state()
  local b = edit(file("b.md"))
  eventually(function()
    return nleaf.state().source == b
  end, "retargeted to b.md")
  local second = nleaf.state()
  eq(second.win, first.win, "same window reused")
  ok(second.job ~= first.job, "new Leaf process")
  eventually(function()
    return vim.fn.jobwait({ first.job }, 0)[1] ~= -1
  end, "old Leaf stopped")
  eq(vim.fn.isdirectory(shadow_dir(first.path)), 0, "old shadow removed")
  edit(file("notes.txt"))
  vim.wait(100)
  eq(nleaf.state().source, b, "non-markdown buffers do not steal the preview")
end)

test("follow = false keeps the preview on its buffer", function()
  config.setup({ follow = false })
  local a = edit(file("a.md"))
  nleaf.toggle()
  edit(file("b.md"))
  vim.wait(100)
  eq(nleaf.state().source, a)
end)

test("float layout takes focus, has a title and moves without restarting", function()
  config.setup({ auto_insert = false })
  edit(file("a.md"))
  vim.cmd("NLeaf float")
  local st = nleaf.state()
  eq(st.layout, "float")
  local conf = api.nvim_win_get_config(st.win)
  eq(conf.relative, "editor")
  ok(vim.inspect(conf.title):find("a.md · live", 1, true), "title shows the file: " .. vim.inspect(conf.title))
  eq(api.nvim_get_current_win(), st.win, "float is focused")
  vim.cmd("NLeaf bottom")
  local moved = nleaf.state()
  eq(moved.layout, "bottom")
  eq(moved.job, st.job, "same Leaf process")
  eq(api.nvim_win_get_config(moved.win).relative, "")
  ok(api.nvim_win_get_position(moved.win)[1] > 0, "bottom split is below the editor")
  eventually(function()
    return #launches() == 1
  end, "Leaf started once")
  vim.wait(100)
  eq(#launches(), 1, "moving did not restart Leaf")
end)

test("tab layout opens the preview in its own tab", function()
  config.setup({ auto_insert = false })
  edit(file("a.md"))
  nleaf.toggle({ layout = "tab" })
  eq(#api.nvim_list_tabpages(), 2)
  eq(api.nvim_get_current_buf(), nleaf.state().buf)
  nleaf.hide()
  eq(#api.nvim_list_tabpages(), 1)
  ok(nleaf.state().active, "Leaf keeps running while hidden")
end)

test("save sync watches the real file and needs one on disk", function()
  config.setup({ sync = "save" })
  local path = file("c.md")
  edit(path)
  nleaf.toggle()
  eq(nleaf.state().path, path)
  eq(nleaf.state().sync, "save")
  eventually(function()
    return #launches() == 1
  end)
  eq(launches()[1].argv, { "--watch", "--", path })
  nleaf.close()
  vim.cmd.enew()
  vim.bo.filetype = "markdown"
  nleaf.toggle()
  ok(not nleaf.state().active, "nothing started")
  ok(notes[#notes] and notes[#notes].msg:find("needs a file on disk", 1, true), vim.inspect(notes))
end)

test("live sync previews an unnamed buffer", function()
  vim.cmd.enew()
  vim.bo.filetype = "markdown"
  api.nvim_buf_set_lines(0, 0, -1, false, { "# scratch" })
  nleaf.toggle()
  local st = nleaf.state()
  ok(st.active)
  eq(vim.fn.fnamemodify(st.path, ":t"), "untitled.md")
  eq(vim.fn.readfile(st.path), { "# scratch" })
end)

test(":NLeaf sync restarts the preview in place", function()
  local path = file("a.md")
  edit(path)
  nleaf.toggle()
  local live = nleaf.state()
  vim.cmd("NLeaf sync save")
  local saved = nleaf.state()
  eq(saved.sync, "save")
  eq(saved.path, path)
  eq(saved.win, live.win, "window reused")
  ok(saved.job ~= live.job, "Leaf restarted")
end)

test("extra args are passed before the watch target", function()
  config.setup({ args = { "--theme", "forest" } })
  edit(file("a.md"))
  nleaf.toggle()
  eventually(function()
    return #launches() == 1
  end)
  eq(launches()[1].argv, { "--theme", "forest", "--watch", "--", nleaf.state().path })
end)

test("a failing Leaf keeps its output visible and reports the exit code", function()
  vim.env.FAKE_LEAF_EXIT = "3"
  edit(file("a.md"))
  nleaf.toggle()
  eventually(function()
    return nleaf.state().dead
  end, "marked dead")
  local st = nleaf.state()
  ok(st.visible, "preview stays open")
  ok(notes[#notes] and notes[#notes].msg:find("code 3", 1, true), vim.inspect(notes))
  eventually(function()
    local text = table.concat(api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    return text:find("fake failure", 1, true) ~= nil
  end, "Leaf's error text is readable")
  vim.env.FAKE_LEAF_EXIT = nil
  nleaf.toggle()
  local fresh = nleaf.state()
  ok(fresh.active and not fresh.dead and fresh.job ~= st.job, "toggle restarts a dead preview")
end)

test("quitting Leaf closes the preview and cleans up", function()
  vim.env.FAKE_LEAF_EXIT = "0"
  edit(file("a.md"))
  nleaf.toggle()
  local st = nleaf.state()
  eventually(function()
    return not nleaf.state().active
  end, "session ended")
  ok(not api.nvim_win_is_valid(st.win), "window closed")
  eq(vim.fn.isdirectory(shadow_dir(st.path)), 0, "shadow removed")
  local errors = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 0, "no error reported")
end)

test("close stops Leaf, closes the window and removes the shadow file", function()
  edit(file("a.md"))
  nleaf.toggle()
  local st = nleaf.state()
  nleaf.close()
  ok(not nleaf.state().active)
  ok(not api.nvim_win_is_valid(st.win), "window closed")
  ok(not api.nvim_buf_is_valid(st.buf), "terminal buffer deleted")
  eq(vim.fn.isdirectory(shadow_dir(st.path)), 0, "shadow removed")
  eventually(function()
    return vim.fn.jobwait({ st.job }, 0)[1] ~= -1
  end, "Leaf stopped")
end)

test("wiping the previewed buffer closes the preview", function()
  local src = edit(file("a.md"))
  nleaf.toggle()
  vim.cmd("bwipeout! " .. src)
  eventually(function()
    return not nleaf.state().active
  end)
end)

test("non-markdown buffers open Leaf's picker; :NLeaf diff passes git arguments", function()
  edit(file("notes.txt"))
  nleaf.toggle()
  eq(nleaf.state().kind, "picker")
  eventually(function()
    return #launches() == 1
  end)
  eq(launches()[1].argv, { "--watch" })
  vim.cmd("NLeaf diff HEAD~1")
  eq(nleaf.state().kind, "diff")
  eventually(function()
    return #launches() == 2
  end)
  eq(launches()[2].argv, { "--diff", "HEAD~1" })
end)

test("editor bridge: Leaf's Ctrl+E jumps to the line in this Neovim", function()
  vim.env.KITTY_PID = "4242"
  local outer_term = vim.env.TERM
  vim.env.TERM = "xterm-kitty"
  local lines = {}
  for i = 1, 40 do
    lines[i] = "line " .. i
  end
  local src = edit(file("long.md", lines))
  nleaf.toggle({ layout = "float" })
  vim.env.TERM = outer_term
  local st = nleaf.state()
  eventually(function()
    return #launches() == 1
  end)
  local launch = launches()[1]
  eq(launch.KITTY_PID, "<unset>", "terminal emulator detection is disabled for Leaf")
  eq(launch.TERM, "xterm-256color", "Leaf sees Neovim's terminal, not the outer one")
  ok(launch.LEAF_EDITOR:find("bridge.lua", 1, true), "LEAF_EDITOR points at the bridge")
  -- Do what Leaf does: expand {$line}, split the command, append the file path, run it.
  local argv = leaf_split((launch.LEAF_EDITOR:gsub("{%$line}", "25")))
  argv[#argv + 1] = st.path
  -- Async on purpose: :wait() would block this Neovim's main loop, so it could not answer
  -- the bridge's RPC request (in real use Neovim is idle while Leaf runs the bridge).
  local result
  vim.system(argv, { text = true }, function(r)
    result = r
  end)
  eventually(function()
    return result ~= nil
  end, "bridge finished", 10000)
  eq(result.code, 0, "bridge exit code (stderr: " .. tostring(result.stderr) .. ")")
  eventually(function()
    return api.nvim_get_current_buf() == src
  end, "back in the source buffer")
  eq(api.nvim_win_get_cursor(0)[1], 25)
  ok(not nleaf.state().visible, "float preview hidden after the jump")
end)

test("health check reports Leaf and no errors", function()
  -- Call the module directly: the :checkhealth UI itself is flaky in headless `nvim -l`.
  local report = {}
  local real = vim.health
  local function record(kind)
    return function(msg)
      report[#report + 1] = kind .. ": " .. msg
    end
  end
  vim.health = {
    start = record("start"),
    ok = record("ok"),
    info = record("info"),
    warn = record("warn"),
    error = record("error"),
  }
  local passed, err = pcall(require("nleaf.health").check)
  vim.health = real
  ok(passed, tostring(err))
  local text = table.concat(report, "\n")
  ok(text:find("Leaf: leaf 0.0.0-fake", 1, true), text)
  ok(not text:find("error:", 1, true) and not text:find("warn:", 1, true), text)
end)

test(":NLeaf completes layouts and subcommands", function()
  eq(vim.fn.getcompletion("NLeaf s", "cmdline"), { "sync" })
  eq(vim.fn.getcompletion("NLeaf sync ", "cmdline"), { "live", "save" })
  ok(vim.tbl_contains(vim.fn.getcompletion("NLeaf ", "cmdline"), "float"))
end)

test("no default mappings are installed", function()
  for _, mode in ipairs({ "n", "t" }) do
    for _, map in ipairs(api.nvim_get_keymap(mode)) do
      if (map.desc or ""):find("^nleaf") then
        ok(map.lhs:find("<Plug>", 1, true), "unexpected mapping: " .. map.lhs)
      end
    end
  end
end)

-- Mouse wheel ----------------------------------------------------------------

local preview = require("nleaf.preview")

local function wheel_map(mode)
  return vim.fn.maparg("<ScrollWheelDown>", mode, false, true)
end

test("mouse wheel over the preview is sent to Leaf, elsewhere it scrolls normally", function()
  edit(file("a.md"))
  nleaf.toggle()
  local st = nleaf.state()
  for _, mode in ipairs({ "n", "i", "x" }) do
    ok((wheel_map(mode).desc or ""):find("^nleaf"), "wheel mapped in mode " .. mode)
  end

  local sent = {}
  local real_pos, real_send = vim.fn.getmousepos, vim.fn.chansend
  vim.fn.chansend = function(job, data)
    sent[#sent + 1] = { job, data }
    return #data
  end
  vim.fn.getmousepos = function()
    return { winid = st.win, winrow = 6, wincol = 11 }
  end
  local over_preview = preview._wheel("<ScrollWheelDown>")
  local up = preview._wheel("<ScrollWheelUp>")
  vim.fn.getmousepos = function()
    return { winid = api.nvim_get_current_win(), winrow = 2, wincol = 3 }
  end
  local over_source = preview._wheel("<ScrollWheelDown>")
  vim.fn.getmousepos, vim.fn.chansend = real_pos, real_send

  eq(over_preview, "", "no Neovim scrolling over the preview")
  eq(up, "")
  eq(sent, { { st.job, "\27[<65;11;6M" }, { st.job, "\27[<64;11;6M" } }, "SGR wheel events at the pointer")
  eq(over_source, "<ScrollWheelDown>", "default wheel behaviour elsewhere")

  nleaf.close()
  eq(wheel_map("n"), {}, "mappings removed when the preview closes")
end)

test("mouse wheel keeps user mappings and can be disabled", function()
  vim.keymap.set("n", "<ScrollWheelDown>", "<C-e>", { desc = "user wheel" })
  edit(file("a.md"))
  nleaf.toggle()
  eq(wheel_map("n").desc, "user wheel", "user mapping untouched")
  ok((wheel_map("i").desc or ""):find("^nleaf"), "other modes still mapped")
  nleaf.close()
  eq(wheel_map("n").desc, "user wheel", "user mapping survives close")
  vim.keymap.del("n", "<ScrollWheelDown>")

  config.setup({ mouse_scroll = false })
  edit(file("a.md"))
  nleaf.toggle()
  eq(wheel_map("n"), {}, "mouse_scroll = false installs nothing")
end)

-- Images ---------------------------------------------------------------------

local image = require("nleaf.image")

local function srcs(line, lines)
  return vim.tbl_map(function(ref)
    return ref.src
  end, image.parse_line(line, lines))
end

---Install fake viewers; returns the call log and a restore function.
local function stub_viewers(opts)
  local calls = {}
  local saved = {
    viewim = package.loaded["viewim"],
    detect = package.loaded["viewim.detect"],
    snacks = rawget(_G, "Snacks"),
    open = vim.ui.open,
  }
  if opts.viewim then
    package.loaded["viewim.detect"] = {
      get_terminal = function()
        if opts.viewim_terminal == nil then
          return "kitty"
        end
        return opts.viewim_terminal or nil
      end,
    }
    package.loaded["viewim"] = {
      view = function(target)
        if opts.viewim_fails then
          error("viewim exploded")
        end
        calls[#calls + 1] = { "viewim", target }
      end,
    }
  else
    package.loaded["viewim"] = nil
    package.loaded["viewim.detect"] = nil
  end
  rawset(_G, "Snacks", opts.snacks and {
    image = {
      supports_terminal = function()
        return true
      end,
      langs = function()
        return { "markdown" }
      end,
      hover = function()
        calls[#calls + 1] = { "snacks", api.nvim_win_get_cursor(0)[2] }
      end,
    },
  } or nil)
  vim.ui.open = function(target)
    calls[#calls + 1] = { "system", target }
    return {}
  end
  return calls,
    function()
      package.loaded["viewim"] = saved.viewim
      package.loaded["viewim.detect"] = saved.detect
      rawset(_G, "Snacks", saved.snacks)
      vim.ui.open = saved.open
    end
end

test("image parser finds markdown, reference and HTML images", function()
  eq(srcs('See ![a](img/a.png) and ![b](<my pic.png> "title") end'), { "img/a.png", "my pic.png" })
  eq(srcs("[![badge](https://x.io/b.svg)](https://x.io)"), { "https://x.io/b.svg" })
  eq(srcs("![paren](foo(1).png)"), { "foo(1).png" })
  eq(srcs([[<p><img alt="x" src='c.png' width=10></p>]]), { "c.png" })
  local doc = { "![logo][lg] and ![lg][]", "", '[LG]: <./logo one.png> "Logo"' }
  eq(srcs(doc[1], doc), { "./logo one.png", "./logo one.png" })
  eq(srcs("no images, just [a link](x.md)"), {})
end)

test("image picker prefers the reference under the cursor, else the nearest", function()
  local refs = image.parse_line("![a](a.png) text text ![b](b.png)")
  eq(image.pick(refs, 3).src, "a.png")
  eq(image.pick(refs, 25).src, "b.png")
  eq(image.pick(refs, 14).src, "a.png")
  eq(image.pick({}, 1), nil)
end)

test("image sources resolve relative to the document", function()
  vim.fn.mkdir(dir .. "/img", "p")
  vim.fn.writefile({ "fake" }, dir .. "/img/a.png")
  local buf = edit(file("doc.md"))
  eq(image.resolve("img/a.png", buf), { target = dir .. "/img/a.png", url = false })
  eq(image.resolve("./img/a.png?raw=1", buf), { target = dir .. "/img/a.png", url = false })
  eq(image.resolve("file://" .. dir .. "/img/a.png", buf), { target = dir .. "/img/a.png", url = false })
  eq(image.resolve("https://x.io/a.png", buf), { target = "https://x.io/a.png", url = true })
  local missing, err = image.resolve("img/missing.png", buf)
  eq(missing, nil)
  ok(err:find("image not found", 1, true), err)
end)

test(":NLeaf image uses viewim, then snacks, then the system viewer", function()
  vim.fn.mkdir(dir .. "/img", "p")
  vim.fn.writefile({ "fake" }, dir .. "/img/a.png")
  edit(file("doc.md", { "intro ![a](img/a.png)" }))
  api.nvim_win_set_cursor(0, { 1, 0 })

  local calls, restore = stub_viewers({ viewim = true, snacks = true })
  vim.cmd("NLeaf image")
  restore()
  eq(calls, { { "viewim", dir .. "/img/a.png" } }, "viewim first, with the resolved path")

  calls, restore = stub_viewers({ viewim = false, snacks = true })
  vim.cmd("NLeaf image")
  restore()
  eq(calls, { { "snacks", 6 } }, "snacks next, cursor moved onto the image")

  calls, restore = stub_viewers({ viewim = true, viewim_terminal = false, snacks = false })
  vim.cmd("NLeaf image")
  restore()
  eq(calls, { { "system", dir .. "/img/a.png" } }, "system viewer last")

  calls, restore = stub_viewers({ viewim = true, viewim_fails = true })
  vim.cmd("NLeaf image")
  restore()
  eq(calls, { { "system", dir .. "/img/a.png" } }, "a failing viewer falls through to the next")

  calls, restore = stub_viewers({ viewim = true, snacks = true })
  vim.cmd("NLeaf image system")
  restore()
  eq(calls, { { "system", dir .. "/img/a.png" } }, "a backend can be forced")
end)

test("image backends follow the configured order and report problems", function()
  config.setup({ image = { backends = { "system" } } })
  eq(config.get().image.backends, { "system" }, "list replaced, not merged")
  ok(not pcall(config.setup, { image = { backends = { "imgcat" } } }), "unknown backend rejected")
  config.setup({ image = { backends = { "viewim" } } })
  vim.fn.mkdir(dir .. "/img", "p")
  vim.fn.writefile({ "fake" }, dir .. "/img/a.png")
  edit(file("doc.md", { "![a](img/a.png)", "plain line" }))
  local calls, restore = stub_viewers({ viewim = false })
  vim.cmd("NLeaf image")
  api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("NLeaf image")
  restore()
  eq(calls, {})
  ok(notes[#notes - 1].msg:find("viewim is not installed", 1, true), vim.inspect(notes))
  ok(notes[#notes].msg:find("no image on this line", 1, true), vim.inspect(notes))
end)

-- NLEAF_TEST_FILTER="pattern1;pattern2" runs only tests whose name matches one of the Lua patterns.
local filter = vim.env.NLEAF_TEST_FILTER
if filter and filter ~= "" then
  local patterns = vim.split(filter, ";", { plain = true, trimempty = true })
  tests = vim.tbl_filter(function(t)
    for _, pattern in ipairs(patterns) do
      if t.name:find(pattern) then
        return true
      end
    end
    return false
  end, tests)
end

local failed = 0
for _, t in ipairs(tests) do
  reset()
  local passed, err = xpcall(t.fn, debug.traceback)
  if passed then
    io.stdout:write("ok   " .. t.name .. "\n")
  else
    failed = failed + 1
    io.stdout:write("FAIL " .. t.name .. "\n" .. tostring(err) .. "\n")
  end
end
reset()
io.stdout:write(("\n%d passed, %d failed\n"):format(#tests - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
