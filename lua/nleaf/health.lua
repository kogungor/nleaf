---:checkhealth nleaf

local M = {}

local VERSION_TIMEOUT_MS = 3000

function M.check()
  local health = vim.health
  health.start("nleaf")

  local version = tostring(vim.version())
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. version)
  else
    health.error("Neovim " .. version .. " is not supported; nleaf needs 0.10 or newer")
  end

  local cfg = require("nleaf.config").get()
  if vim.fn.executable(cfg.cmd) ~= 1 then
    health.error(("Leaf executable not found: %s"):format(cfg.cmd), {
      "brew install leaf-markdown-viewer",
      "cargo install leaf-markdown-viewer",
      "or point nleaf at it: require('nleaf').setup({ cmd = '/path/to/leaf' })",
    })
  else
    local ok, result = pcall(function()
      return vim.system({ cfg.cmd, "--version" }, { text = true }):wait(VERSION_TIMEOUT_MS)
    end)
    if ok and result.code == 0 then
      health.ok(("Leaf: %s (%s)"):format(vim.trim(result.stdout or ""), vim.fn.exepath(cfg.cmd)))
    elseif ok then
      health.warn(
        ("`%s --version` exited with code %s: %s"):format(cfg.cmd, result.code, vim.trim(result.stderr or ""))
      )
    else
      health.warn(("could not run `%s --version`: %s"):format(cfg.cmd, tostring(result)))
    end
  end

  health.info(
    ("layout = %s, sync = %s, follow = %s, filetypes = %s"):format(
      cfg.layout,
      cfg.sync,
      tostring(cfg.follow),
      table.concat(cfg.filetypes, ", ")
    )
  )

  local image = require("nleaf.image")
  local chosen, reasons = image.backend()
  for _, name in ipairs(cfg.image.backends) do
    if name == chosen then
      health.ok(("images: %s will open images under the cursor (:NLeaf image)"):format(name))
      break
    end
    health.info(("images: %s skipped (%s)"):format(name, reasons[name] or "unavailable"))
  end
  if not chosen then
    health.warn("images: no viewer available", {
      "install kogungor/viewim, or snacks.nvim in kitty/Ghostty/WezTerm",
      "or add 'system' to image.backends",
    })
  end

  if cfg.editor_bridge then
    local server = vim.v.servername
    if server ~= nil and server ~= "" then
      health.ok("editor bridge: Ctrl+E in Leaf jumps to the line in this Neovim (" .. server .. ")")
    else
      health.info("editor bridge: an RPC server will be started with the first preview")
    end
  else
    health.info("editor bridge disabled: Ctrl+E uses Leaf's own editor setting")
  end
end

return M
