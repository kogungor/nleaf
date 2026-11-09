---Editor bridge: make Leaf's "open in editor" (Ctrl+E) jump to the line in this Neovim.
---
---Leaf resolves its editor from $LEAF_EDITOR, expands `{$line}` and appends the file path.
---For terminal editors it first tries to open a new tab in kitty, iTerm, Terminal.app,
---GNOME Terminal or Windows Terminal (detected from the environment) and otherwise runs
---the editor in its own terminal. nleaf removes those detection variables from Leaf's
---environment, so Leaf runs the bridge script in place; the script asks this Neovim, over
---its RPC socket, to jump to the file and line.

local M = {}

-- Variables Leaf reads to pick a "new tab" strategy (src/editor.rs: detect_terminal_emulator).
-- TERMUX_VERSION is kept: Leaf also uses it for the clipboard, and Termux runs in place anyway.
local EMULATOR_VARS = { "KITTY_PID", "GNOME_TERMINAL_SCREEN", "WT_SESSION", "TERM_PROGRAM" }

local script = (function()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h") .. "/scripts/bridge.lua"
end)()

---@return string
function M.server()
  local name = vim.v.servername
  if name == nil or name == "" then
    name = vim.fn.serverstart()
  end
  return name
end

local function quote(s)
  return '"' .. s .. '"'
end

---The $LEAF_EDITOR value. Leaf splits it shell-style, replaces {$line}, appends the path.
---@return string
function M.command()
  return table.concat({
    quote(vim.v.progpath),
    "--clean",
    "--headless",
    "-l",
    quote(script),
    quote(M.server()),
    "{$line}",
  }, " ")
end

---Environment for the Leaf job (used with clear_env, so it is the complete environment).
---@return table<string, string>
function M.env()
  local env = vim.fn.environ()
  for _, name in ipairs(EMULATOR_VARS) do
    env[name] = nil
  end
  -- Leaf runs inside Neovim's terminal, not the outer one. An explicit TERM in `env` would
  -- override the value Neovim sets for its terminal (e.g. leak "xterm-kitty").
  env.TERM = nil
  env.LEAF_EDITOR = M.command()
  return env
end

---RPC entry point used by scripts/bridge.lua. Returns immediately; the jump runs on the
---main loop so the request never blocks Leaf.
---@param path string
---@param line integer
function M.open(path, line)
  vim.schedule(function()
    require("nleaf.preview").jump(path, tonumber(line) or 1)
  end)
  return true
end

return M
