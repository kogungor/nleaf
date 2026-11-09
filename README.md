# nleaf

Real-time Markdown preview for Neovim, rendered by [Leaf](https://github.com/RivoLink/leaf) —
RivoLink's terminal Markdown viewer — in whichever layout you like.

- **Live preview** of what you type, saved or not. Your file on disk is never touched.
- **Any layout**: side split (right/left), bottom/top split, centered float or its own tab, and
  you can move a running preview between them without restarting Leaf.
- **Follows you**: switch to another Markdown buffer and the preview switches with it.
- **Ctrl+E goes back to Neovim**: Leaf's "open in editor" jumps to the line you were reading in
  *this* Neovim, instead of opening a second editor.
- **Images**: Leaf shows images as alt text only, so `:NLeaf image` opens the image under the
  cursor with [viewim](https://github.com/kogungor/viewim), snacks.image or your system viewer.
- Leaf's **file picker** and **git diff viewer** are one command away.
- No dependencies, no default keymaps, Leaf's error output stays readable when it fails.

## Requirements

- Neovim 0.10+
- Leaf on `$PATH`:

  ```sh
  brew install leaf-markdown-viewer    # or: cargo install leaf-markdown-viewer
  leaf --version
  ```

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kogungor/nleaf",
  cmd = "NLeaf",
  keys = {
    { "<leader>mp", "<cmd>NLeaf<cr>", desc = "Markdown preview (Leaf)" },
  },
  opts = {}, -- optional, see Configuration
}
```

Any other plugin manager works too: nleaf only needs to be on the runtimepath. `setup()` is
optional.

## Usage

| Command | What it does |
|---|---|
| `:NLeaf` | Toggle the preview of the current buffer (default layout: right split). |
| `:NLeaf float` / `right` / `left` / `bottom` / `top` / `tab` | Open the preview in that layout, or move the running one there. Running it again in the same layout hides it. |
| `:NLeaf close` | Stop Leaf and close the preview. |
| `:NLeaf picker [layout]` | Leaf's fuzzy file picker; the chosen file is watched. |
| `:NLeaf diff [args]` | Leaf's git diff viewer, e.g. `:NLeaf diff`, `:NLeaf diff cached`, `:NLeaf diff HEAD~2`. |
| `:NLeaf image [viewim\|snacks\|system]` | Open the image under the cursor (see [Images](#images)). |
| `:NLeaf sync live` / `save` | Switch sync mode (restarts a running preview). |
| `:checkhealth nleaf` | Check Neovim, Leaf and the editor bridge. |

Toggling behaves the way you would expect:

- On the previewed buffer, or inside the preview: hide it (Leaf keeps running and keeps its
  scroll position) or show it again.
- On another Markdown buffer: switch the preview to it.
- On a non-Markdown buffer with no preview: open Leaf's picker.

Inside the preview, keys go to Leaf (`q` quits Leaf and closes the preview). In the preview's
Normal mode, `q` hides it. Leave Terminal mode with `<C-\><C-n>`.

### Mappings

nleaf installs no keymaps. Map what you need, either with commands or `<Plug>` mappings that
also work in Terminal mode (so the same key hides the preview from inside it):

```lua
vim.keymap.set({ "n", "t" }, "<leader>mp", "<Plug>(NLeafToggle)")
vim.keymap.set("n", "<leader>mf", "<Plug>(NLeafFloat)")
vim.keymap.set("n", "<leader>mr", "<Plug>(NLeafRight)")
vim.keymap.set("n", "<leader>mi", "<Plug>(NLeafImage)")
```

Available: `<Plug>(NLeafToggle)`, `<Plug>(NLeafClose)`, `<Plug>(NLeafImage)`, `<Plug>(NLeafFloat)`,
`<Plug>(NLeafRight)`, `<Plug>(NLeafLeft)`, `<Plug>(NLeafBottom)`, `<Plug>(NLeafTop)`,
`<Plug>(NLeafTab)`.

## Sync modes

**`live`** (default): every edit is mirrored, after `debounce` ms, into a private copy of the
buffer in Neovim's temp directory, and Leaf watches that copy. You see unsaved changes, unnamed
buffers can be previewed, and your real file is never written. Because Leaf reads the copy,
*relative* links to other files cannot be followed from inside Leaf in this mode.

**`save`**: Leaf watches the real file, so the preview updates when you `:w`. Relative links
work. The buffer must exist on disk.

Leaf reloads by checking the file's modification time and size, then shows a short "reloaded"
notice. If that flickers too much while typing, raise `debounce` (e.g. `400`).

## Configuration

Defaults:

```lua
require("nleaf").setup({
  cmd = "leaf",            -- Leaf executable
  args = {},               -- extra Leaf args, e.g. { "--theme", "forest", "--width", "100" }
  layout = "right",        -- "float" | "right" | "left" | "bottom" | "top" | "tab"
  size = 0.45,             -- split size: fraction (<= 1) or columns/lines
  float = {
    width = 0.85,          -- fraction (<= 1) or columns
    height = 0.85,         -- fraction (<= 1) or lines
    border = "rounded",
    title = true,          -- "Leaf · README.md · live" in the border
  },
  sync = "live",           -- "live" | "save"
  debounce = 150,          -- ms after the last edit before the live copy is written
  follow = true,           -- retarget a visible preview when you enter another previewable buffer
  focus = false,           -- move the cursor into split previews when they open (floats and tabs always get focus)
  auto_insert = true,      -- enter Terminal mode when the cursor enters the preview
  filetypes = { "markdown" }, -- what :NLeaf previews; add e.g. "quarto", "rmd"
  editor_bridge = true,    -- Leaf's Ctrl+E jumps to the line in this Neovim
  keys = { hide = "q" },   -- Normal-mode key in the preview that hides it (false to disable)
  image = {
    backends = { "viewim", "snacks", "system" }, -- tried in order by :NLeaf image
  },
})
```

Leaf's own settings (`leaf --config`, `LEAF_THEME`, …) keep working; `args` is only for
things you want to force from Neovim.

## Images

Leaf renders `![alt](src)` as its alt text only, and Neovim's built-in terminal cannot show
terminal graphics anyway. So nleaf opens images *next to* the preview instead: put the cursor
on an image reference in your Markdown buffer and run `:NLeaf image` (or map
`<Plug>(NLeafImage)`).

It understands `![alt](path)`, `![alt](<path with spaces> "title")`, linked badges
`[![alt](src)](link)`, reference images `![alt][id]` with `[id]: src`, and HTML
`<img src="...">`. On a line with several images it takes the one under the cursor, otherwise
the nearest. Relative paths are resolved against the Markdown file; `http(s)://` URLs are passed
through.

Viewers are tried in the order of `image.backends`; the first one that is available opens the
image, and a viewer that fails hands over to the next:

| Backend | Used when | Shows the image |
|---|---|---|
| `viewim` | [kogungor/viewim](https://github.com/kogungor/viewim) is installed and supports your terminal (kitty, WezTerm, Ghostty, iTerm2) | in a terminal pane/window or the OS viewer; also SVG and remote URLs |
| `snacks` | [snacks.nvim](https://github.com/folke/snacks.nvim) is loaded, the terminal speaks the kitty graphics protocol (kitty, Ghostty, WezTerm) and a Markdown treesitter parser is installed | in a float next to the cursor (`Snacks.image.hover()`) |
| `system` | always (Neovim 0.10+) | in your default app via `vim.ui.open()` (`open`, `xdg-open`, …) |

Force one with `:NLeaf image snacks`. `:checkhealth nleaf` shows which viewer will be used and
why the others are skipped.

## Editor bridge

In Leaf, Ctrl+E opens the current file in an editor at the line you are reading. Normally that
starts a separate editor, either in a new terminal tab or nested inside the preview. With
`editor_bridge = true` nleaf sets `$LEAF_EDITOR` for its Leaf process to a tiny script that
asks this Neovim, over its RPC socket, to jump to that file and line. A float preview hides
itself so you land in the code. In `live` mode the jump goes to your buffer, not the private
copy.

Set `editor_bridge = false` to keep Leaf's own editor behaviour.

## Lua API

```lua
local nleaf = require("nleaf")
nleaf.toggle({ layout = "float" })     -- layout is optional
nleaf.open({ buf = 0, layout = "right" }) -- preview any normal buffer, whatever its filetype
nleaf.picker({ layout = "float" })
nleaf.diff({ "HEAD~1" })
nleaf.image({ backend = "viewim" })   -- backend is optional; returns the viewer used
nleaf.hide()
nleaf.show("bottom")
nleaf.close()
nleaf.set_sync("save")
nleaf.state() -- { active, visible, layout, kind, source, path, sync, buf, win, job, argv, dead }
```

## Development

```sh
nvim --clean -l tests/run.lua                               # whole suite, uses tests/bin/leaf (a fake Leaf)
NLEAF_TEST_FILTER="bridge;float" nvim --clean -l tests/run.lua  # only matching tests
stylua --check .
```

## Credits

All the rendering is [Leaf](https://github.com/RivoLink/leaf) by RivoLink. nleaf is an
independent integration and is not affiliated with the Leaf project.

## License

MIT
