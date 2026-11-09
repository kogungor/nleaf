---Images under the cursor. Leaf renders images as their alt text only, so nleaf hands them to
---an image viewer: viewim (kogungor/viewim), snacks.image, or the system viewer (vim.ui.open).

local api = vim.api
local config = require("nleaf.config")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.WARN, { title = "nleaf" })
end

---@class nleaf.ImageRef
---@field src string Source as written in the document.
---@field start integer 1-based first column of the reference.
---@field finish integer 1-based last column of the reference.

---Markdown inline images: ![alt](src), ![alt](<src with spaces>), ![alt](src "title").
local function inline_images(line, out)
  local from = 1
  while true do
    local s = line:find("![", from, true)
    if not s then
      return
    end
    local close = line:find("](", s + 2, true)
    if not close then
      return
    end
    local i = close + 2
    local src, finish
    if line:sub(i, i) == "<" then
      local gt = line:find(">", i + 1, true)
      if gt then
        src = line:sub(i + 1, gt - 1)
        finish = line:find(")", gt + 1, true)
      end
    else
      local depth, j = 0, i
      while j <= #line do
        local c = line:sub(j, j)
        if c == "(" then
          depth = depth + 1
        elseif c == ")" then
          if depth == 0 then
            break
          end
          depth = depth - 1
        end
        j = j + 1
      end
      if j <= #line then
        src = vim.trim(line:sub(i, j - 1)):match("^(%S+)")
        finish = j
      end
    end
    if src and src ~= "" and finish then
      out[#out + 1] = { src = src, start = s, finish = finish }
      from = finish + 1
    else
      from = s + 2
    end
  end
end

---Reference images: ![alt][id], ![alt][] and ![id], resolved through [id]: src definitions.
local function reference_images(line, lines, out)
  local function lookup(id)
    id = vim.trim(id):lower()
    for _, l in ipairs(lines) do
      local key, rest = l:match("^%s*%[([^%]]+)%]:%s*(.+)$")
      if key and vim.trim(key):lower() == id then
        return rest:match("^<([^>]+)>") or rest:match("^(%S+)")
      end
    end
  end
  for s, alt, id, finish in line:gmatch("()!%[([^%]]*)%]%[([^%]]*)%]()") do
    local src = lookup(id ~= "" and id or alt)
    if src then
      out[#out + 1] = { src = src, start = s, finish = finish - 1 }
    end
  end
end

---HTML: <img ... src="..." ...>
local function html_images(line, out)
  for s, tag, finish in line:gmatch("()(<[Ii][Mm][Gg]%s[^>]*>)()") do
    local src = tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]+)"') or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']+)'")
    if src then
      out[#out + 1] = { src = src, start = s, finish = finish - 1 }
    end
  end
end

---Every image reference on `line`.
---@param line string
---@param lines? string[] Whole document, for reference definitions.
---@return nleaf.ImageRef[]
function M.parse_line(line, lines)
  local out = {}
  inline_images(line, out)
  reference_images(line, lines or { line }, out)
  html_images(line, out)
  table.sort(out, function(a, b)
    return a.start < b.start
  end)
  return out
end

---The image under (or nearest to) column `col` (1-based) of `line`.
---@return nleaf.ImageRef?
function M.pick(refs, col)
  local best, best_distance
  for _, ref in ipairs(refs) do
    if col >= ref.start and col <= ref.finish then
      return ref
    end
    local distance = col < ref.start and ref.start - col or col - ref.finish
    if not best_distance or distance < best_distance then
      best, best_distance = ref, distance
    end
  end
  return best
end

---Turn a document source into something a viewer can open.
---@param src string
---@param buf integer Buffer the reference came from (relative paths are relative to its file).
---@return { target: string, url: boolean }? resolved
---@return string? err
function M.resolve(src, buf)
  if src:match("^https?://") then
    return { target = src, url = true }
  end
  if src:match("^file://") then
    src = vim.uri_to_fname(src)
  elseif src:match("^%a[%w+.-]*:") and not src:match("^%a:[/\\]") then
    return nil, "unsupported image source: " .. src
  end
  src = src:gsub("[?#].*$", "")
  local path = vim.fn.expand(src)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    local name = api.nvim_buf_get_name(buf)
    local base = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
    path = base .. "/" .. path
  end
  path = vim.fs.normalize(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "image not found: " .. path
  end
  return { target = path, url = false }
end

---@class nleaf.ImageBackend
---@field available fun(): boolean, string?
---@field open fun(target: string)

---@type table<string, nleaf.ImageBackend>
M.backends = {
  viewim = {
    available = function()
      local ok, detect = pcall(require, "viewim.detect")
      if not ok then
        return false, "viewim is not installed"
      end
      if not detect.get_terminal() then
        return false, "viewim does not support this terminal"
      end
      return true
    end,
    open = function(target)
      require("viewim").view(target)
    end,
  },
  snacks = {
    available = function()
      local snacks = rawget(_G, "Snacks")
      if type(snacks) ~= "table" or type(snacks.image) ~= "table" then
        return false, "snacks.nvim is not loaded"
      end
      if not snacks.image.supports_terminal() then
        return false, "this terminal does not support the kitty graphics protocol"
      end
      local lang = vim.treesitter.language.get_lang(vim.bo.filetype) or vim.bo.filetype
      if not vim.tbl_contains(snacks.image.langs(), lang) then
        return false, "snacks.image has no image query for " .. lang
      end
      return true
    end,
    open = function()
      -- snacks finds the image under the cursor itself (treesitter) and shows it in a float.
      rawget(_G, "Snacks").image.hover()
    end,
  },
  system = {
    available = function()
      if not vim.ui.open then
        return false, "vim.ui.open needs Neovim 0.10"
      end
      return true
    end,
    open = function(target)
      local cmd, err = vim.ui.open(target)
      if not cmd then
        error(err or "vim.ui.open failed", 0)
      end
    end,
  },
}

---Which backend would handle the next image, in configured order.
---@return string? name
---@return table<string, string> reasons Why the others were skipped.
function M.backend()
  local reasons = {}
  for _, name in ipairs(config.get().image.backends) do
    local ok, available, reason = pcall(M.backends[name].available)
    if ok and available then
      return name, reasons
    end
    reasons[name] = ok and (reason or "unavailable") or tostring(available)
  end
  return nil, reasons
end

---Show the image under the cursor.
---@param opts? { backend?: string }
function M.show(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "nleaf" then
    notify("run this in the Markdown buffer: Leaf does not report its cursor")
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local ref = M.pick(M.parse_line(line, api.nvim_buf_get_lines(buf, 0, -1, false)), cursor[2] + 1)
  if not ref then
    notify("no image on this line")
    return
  end
  local resolved, err = M.resolve(ref.src, buf)
  if not resolved then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local order = opts.backend and { opts.backend } or config.get().image.backends
  local skipped = {}
  for _, name in ipairs(order) do
    local backend = M.backends[name]
    if not backend then
      notify("unknown image backend: " .. tostring(name), vim.log.levels.ERROR)
      return
    end
    local ok, available, reason = pcall(backend.available)
    if ok and available then
      if name == "snacks" then
        -- snacks reads the reference under the cursor; make sure it is the one we picked.
        api.nvim_win_set_cursor(0, { cursor[1], ref.start - 1 })
      end
      local opened, open_err = pcall(backend.open, resolved.target)
      if opened then
        return name
      end
      skipped[#skipped + 1] = ("%s: %s"):format(name, tostring(open_err))
    else
      skipped[#skipped + 1] = ("%s: %s"):format(name, ok and (reason or "unavailable") or tostring(available))
    end
  end
  notify("no image viewer could open " .. resolved.target .. "\n" .. table.concat(skipped, "\n"), vim.log.levels.ERROR)
end

return M
