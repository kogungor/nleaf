-- nleaf editor bridge. Leaf runs this through $LEAF_EDITOR when you press Ctrl+E:
--
--   nvim --clean --headless -l scripts/bridge.lua <server> <line> <path>
--
-- It connects to the Neovim that owns the preview and asks it to jump to <path>:<line>.

local server, line, path = arg[1], arg[2], arg[3]

local function die(msg)
  io.stderr:write("nleaf: " .. msg .. "\n")
  os.exit(1)
end

if not server or server == "" or not path or path == "" then
  die("usage: bridge.lua <server> <line> <path>")
end

-- host:port means TCP; anything else is a Unix socket or a Windows named pipe.
local mode = server:match("^[^/\\]+:%d+$") and "tcp" or "pipe"
local ok, chan = pcall(vim.fn.sockconnect, mode, server, { rpc = true })
if not ok or chan == 0 then
  die("cannot reach Neovim at " .. server)
end

local sent, err = pcall(
  vim.rpcrequest,
  chan,
  "nvim_exec_lua",
  "return require('nleaf.bridge').open(...)",
  { path, tonumber(line) or 1 }
)
pcall(vim.fn.chanclose, chan)
if not sent then
  die(tostring(err))
end
