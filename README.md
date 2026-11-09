# nleaf

I like [Leaf](https://github.com/RivoLink/leaf) for reading Markdown in the terminal and
wanted it next to the file I'm editing in Neovim. nleaf runs Leaf in a Neovim terminal
window and keeps it in sync with your buffer, including changes you haven't saved yet.

What it does:

- Shows the preview in a split (right by default), a float or a tab.
- Updates as you type. Unsaved changes go to a temporary copy, your file is not written.
- Switches the preview when you move to another Markdown buffer.
- Ctrl+E in Leaf jumps to that line in your Neovim instead of opening another editor.
- `:NLeaf image` opens the image under the cursor, since Leaf only shows alt text.
- Gives you Leaf's file picker and git diff viewer as commands.

It has no dependencies and sets no keymaps. The one exception: while a preview is open, the
mouse wheel over it scrolls Leaf, even when your cursor is in another window. Neovim only
forwards the wheel to a terminal you're typing in, so without this you'd have to click into
the preview first. Turn it off with `mouse_scroll = false`; if you already map the wheel,
nleaf leaves your mapping alone.

Tested with Leaf 1.29 and Neovim 0.10 to nightly on macOS and Linux. Not tested on Windows.

## Install

Install Leaf first (the package is called `leaf-markdown-viewer`; `brew install leaf` is an
unrelated tool):

```sh
brew install leaf-markdown-viewer   # or: cargo install leaf-markdown-viewer
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kogungor/nleaf",
  lazy = false,
  keys = {
    { "<leader>mp", "<cmd>NLeaf<cr>", desc = "Markdown preview" },
    { "<leader>mi", "<Plug>(NLeafImage)", desc = "Image under cursor" },
  },
  opts = {},
}
```

There's no need to lazy-load it: at startup nleaf only defines its commands, and the rest
loads the first time you use it. If you do lazy-load it (with `cmd` or `keys`),
`:checkhealth nleaf` won't find it until it has been loaded once.

Other plugin managers work too. Calling `setup()` is optional. Run `:checkhealth nleaf` if
something doesn't work.

## Commands

| Command | |
|---|---|
| `:NLeaf` | Toggle the preview for the current buffer |
| `:NLeaf float` (or `right`, `left`, `bottom`, `top`, `tab`) | Open the preview there, or move it there |
| `:NLeaf close` | Stop Leaf and close the preview |
| `:NLeaf image [viewim\|snacks\|system]` | Open the image under the cursor |
| `:NLeaf picker [layout]` | Leaf's file picker |
| `:NLeaf diff [args]` | Leaf's git diff viewer, e.g. `:NLeaf diff cached` |
| `:NLeaf sync live` / `save` | Switch between live preview and update-on-save |

Toggling hides the preview without stopping Leaf, so it keeps its scroll position. Running
`:NLeaf` on a different Markdown buffer switches the preview to it. On a non-Markdown buffer
with nothing open, it opens Leaf's picker.

Inside the preview, keys go to Leaf, and `q` quits it. From Normal mode in the preview
(`<C-\><C-n>`), `q` only hides it.

For mappings that also work inside the preview, use the `<Plug>` versions:

```lua
vim.keymap.set({ "n", "t" }, "<leader>mp", "<Plug>(NLeafToggle)")
```

Available: `<Plug>(NLeafToggle)`, `<Plug>(NLeafClose)`, `<Plug>(NLeafImage)`,
`<Plug>(NLeafFloat)`, `<Plug>(NLeafRight)`, `<Plug>(NLeafLeft)`, `<Plug>(NLeafBottom)`,
`<Plug>(NLeafTop)`, `<Plug>(NLeafTab)`.

## Live and save sync

With `sync = "live"` (the default), the buffer is written to a temporary file 150 ms after
you stop typing and Leaf watches that file. One downside: Leaf can't follow relative links to
other files from the copy.

With `sync = "save"`, Leaf watches the real file and updates when you `:w`. Relative links
work, but the buffer has to be saved to disk first.

Leaf shows a short "reloaded" message on each update. If that bothers you while typing,
raise `debounce`.

## Images

Leaf prints images as their alt text, and Neovim's terminal can't display images anyway. So
`:NLeaf image` hands the image under the cursor to the first viewer that works:

1. [viewim](https://github.com/kogungor/viewim), if installed (kitty, WezTerm, Ghostty, iTerm2)
2. snacks.image, if snacks.nvim is loaded and the terminal supports the kitty graphics
   protocol (kitty, Ghostty, WezTerm)
3. your system viewer through `vim.ui.open()`

It finds `![alt](src)`, `![alt](<src with spaces>)`, `[![alt](src)](link)`, `![alt][id]`
references and `<img src="...">`. Relative paths are resolved from the Markdown file. Change
the order with `image.backends`, or pick one with `:NLeaf image snacks`.

## Ctrl+E

Leaf's Ctrl+E normally opens a second editor. nleaf points Leaf's `$LEAF_EDITOR` at a small
script that tells your Neovim to jump to the file and line instead. A float preview hides
itself so you land in the code. Set `editor_bridge = false` to turn this off.

## Configuration

These are the defaults:

```lua
require("nleaf").setup({
  cmd = "leaf",
  args = {},                -- extra Leaf args, e.g. { "--theme", "forest" }
  layout = "right",         -- float, right, left, bottom, top, tab
  size = 0.45,              -- split size, as a fraction or in columns/lines
  float = { width = 0.85, height = 0.85, border = "rounded", title = true },
  sync = "live",            -- live or save
  debounce = 150,           -- ms
  follow = true,            -- switch the preview when you enter another Markdown buffer
  focus = false,            -- put the cursor in split previews when they open
  auto_insert = true,       -- enter Terminal mode when you go into the preview
  filetypes = { "markdown" },
  editor_bridge = true,     -- Ctrl+E in Leaf jumps to the line in Neovim
  mouse_scroll = true,      -- mouse wheel over the preview scrolls Leaf
  keys = { hide = "q" },    -- set to false to disable
  image = { backends = { "viewim", "snacks", "system" } },
})
```

Leaf's own config (`leaf --config`) still applies. Use `args` only for things you want to
set from Neovim.

There is also a Lua API (`toggle`, `open`, `close`, `hide`, `show`, `picker`, `diff`,
`image`, `set_sync`, `state`); see `:h nleaf-api`.

## Development

```sh
nvim --clean -l tests/run.lua
NLEAF_TEST_FILTER="bridge;float" nvim --clean -l tests/run.lua
stylua --check .
```

The tests use a fake `leaf` in `tests/bin`, so you don't need Leaf installed to run them.

## Credits

The rendering is all [Leaf](https://github.com/RivoLink/leaf) by RivoLink. This plugin is not
affiliated with the Leaf project.

## License

MIT
