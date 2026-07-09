local window   = require("inline_review.window")
local renderer = require("inline_review.renderer")
local storage  = require("inline_review.storage")
local util     = require("inline_review.util")

local M = {}

M.config = {
  width   = 45,
  author  = vim.uv.os_get_passwd().username,
  animate = false,
  keymaps = {
    source = {
      toggle          = "<leader>rp",
      comment         = "<leader>rc",
      addition        = "<leader>ra",
      deletion        = "<leader>rd",
      replacement     = "<leader>rr",
      jump_to_pane    = "gd",
      next_annotation = "]r",
      prev_annotation = "[r",
    },
    pane = {
      next    = "j",
      prev    = "k",
      peek    = "gd",
      jump    = "<CR>",
      approve = "A",
      delete  = "D",
      reply   = "R",
      edit    = "E",
      undo    = "u",
      redo    = "<C-r>",
    },
  },
}

-- Set a keymap unless disabled (set to false) in the config.
local function map(mode, lhs, rhs, opts)
  if not lhs then return end
  vim.keymap.set(mode, lhs, rhs, opts)
end

local function on_visual(fn)
  return function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    local sel = util.capture_visual_selection()
    sel.cursor_line = vim.fn.line(".")
    sel.cursor_col  = vim.fn.col(".")
    fn(sel)
  end
end

local function jump_to_annotation(direction)
  local items = vim.list_extend({}, storage.parse(vim.api.nvim_get_current_buf()))
  if #items == 0 then return end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  table.sort(items, function(a, b) return a.start_line < b.start_line end)
  if direction == "next" then
    for _, item in ipairs(items) do
      if item.start_line > cursor then
        vim.api.nvim_win_set_cursor(0, { item.start_line, item.start_col or 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { items[1].start_line, items[1].start_col or 0 })
  else
    for i = #items, 1, -1 do
      if items[i].start_line < cursor then
        vim.api.nvim_win_set_cursor(0, { items[i].start_line, items[i].start_col or 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { items[#items].start_line, items[#items].start_col or 0 })
  end
end

local function attach_source_keymaps(buf)
  local km = M.config.keymaps.source or {}
  local function o(desc) return { buffer = buf, desc = desc } end

  map("n", km.toggle, function() window.toggle(M.config) end, o("Toggle inline review pane"))
  map("n", km.jump_to_pane, window.jump_to_pane, o("Jump to review item in pane"))

  map("v", km.comment, on_visual(function(sel)
    window.add_suggestion("comment", sel, M.config)
  end), o("Add review comment"))
  map("v", km.addition, on_visual(function(sel)
    window.add_suggestion("addition", sel, M.config)
  end), o("Propose addition"))
  map("v", km.deletion, on_visual(function(sel)
    window.add_suggestion("deletion", sel, M.config)
  end), o("Propose deletion"))
  map("v", km.replacement, on_visual(function(sel)
    window.add_suggestion("replacement", sel, M.config)
  end), o("Propose replacement"))

  map("n", km.next_annotation, function() jump_to_annotation("next") end,
    o("Next inline review annotation"))
  map("n", km.prev_annotation, function() jump_to_annotation("prev") end,
    o("Previous inline review annotation"))
end

local function attach_pane_keymaps(buf)
  local km = M.config.keymaps.pane or {}
  local function o(desc) return { buffer = buf, desc = desc } end

  map("n", km.peek, window.peek_source, o("Peek source location (keep focus in pane)"))
  map("n", km.jump, window.jump_to_source, o("Jump to source location"))

  map("n", km.next, function()
    local lnum = renderer.next_block_line()
    if lnum then vim.api.nvim_win_set_cursor(0, { lnum, 0 }) end
  end, o("Next review block"))
  map("n", km.prev, function()
    local lnum = renderer.prev_block_line()
    if lnum then vim.api.nvim_win_set_cursor(0, { lnum, 0 }) end
  end, o("Previous review block"))

  map("n", km.approve, window.approve_current, o("Approve suggestion"))
  map("n", km.delete, window.delete_current, o("Delete/reject item or reply"))
  map("n", km.reply, window.reply_current, o("Reply to comment"))
  map("n", km.edit, window.edit_current, o("Edit comment body"))

  local function source_undo(cmd)
    return function()
      local src = window.source_buf()
      if not src or not vim.api.nvim_buf_is_valid(src) then return end
      local src_win = vim.fn.bufwinid(src)
      if src_win == -1 then return end
      vim.api.nvim_win_call(src_win, function()
        vim.cmd("silent! " .. cmd)
      end)
    end
  end

  map("n", km.undo, source_undo("undo"), o("Undo in source buffer"))
  map("n", km.redo, source_undo("redo"), o("Redo in source buffer"))
end

local function maybe_auto_open(buf)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if window.is_open() then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not storage.has_annotations(lines) then return end
    local win = vim.fn.bufwinid(buf)
    if win == -1 then return end
    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    window.open(M.config)
    if vim.api.nvim_win_is_valid(prev) then
      vim.api.nvim_set_current_win(prev)
    end
  end)
end

local function apply_highlights()
  vim.api.nvim_set_hl(0, "InlineReviewTitle",          { bold = true,                                        default = true })
  vim.api.nvim_set_hl(0, "InlineReviewContents",       { link = "Normal",                                    default = true })
  vim.api.nvim_set_hl(0, "InlineReviewMeta",           { link = "Comment",                                   default = true })
  vim.api.nvim_set_hl(0, "InlineReviewAddition",       { fg = "#3d9a50", ctermfg = 2,                        default = true })
  vim.api.nvim_set_hl(0, "InlineReviewDeletion",       { fg = "#c94f4f", ctermfg = 1,   strikethrough = true, default = true })
  vim.api.nvim_set_hl(0, "InlineReviewAccept",         { fg = "#3d78d8", ctermfg = 12,                       default = true })
  vim.api.nvim_set_hl(0, "InlineReviewDelete",         { fg = "#3d78d8", ctermfg = 12,                       default = true })
  vim.api.nvim_set_hl(0, "InlineReviewReply",          { fg = "#3d78d8", ctermfg = 12,                       default = true })
  vim.api.nvim_set_hl(0, "InlineReviewEdit",           { fg = "#3d78d8", ctermfg = 12,                       default = true })
  vim.api.nvim_set_hl(0, "InlineReviewComment",        { fg = "#8060c8", ctermfg = 13,                       default = true })
  vim.api.nvim_set_hl(0, "InlineReviewSep",            { link = "NonText",                                   default = true })
  vim.api.nvim_set_hl(0, "InlineReviewAction",         { link = "Comment",                                   default = true })
  vim.api.nvim_set_hl(0, "InlineReviewActiveCardBg",   { link = "CursorLine",                                default = true })
  vim.api.nvim_set_hl(0, "InlineReviewActiveBorder",   { fg = "#7080a0", ctermfg = 103,                      default = true })
  vim.api.nvim_set_hl(0, "InlineReviewInactiveBorder", { link = "NonText",                                   default = true })
  vim.api.nvim_set_hl(0, "InlineReviewPaneBg",          { link = "NormalFloat",                                default = true })
end

local SUBCOMMANDS = {
  "toggle", "open", "close", "next", "prev",
  "comment", "addition", "deletion", "replacement",
}

local function run_command(cmd)
  local sub = cmd.fargs[1] or "toggle"
  if sub == "toggle" then
    window.toggle(M.config)
  elseif sub == "open" then
    window.open(M.config)
  elseif sub == "close" then
    window.close()
  elseif sub == "next" or sub == "prev" then
    jump_to_annotation(sub)
  elseif vim.tbl_contains({ "comment", "addition", "deletion", "replacement" }, sub) then
    if cmd.range == 0 then
      vim.notify("inline-review: :InlineReview " .. sub .. " needs a visual selection",
        vim.log.levels.WARN)
      return
    end
    local sel = util.capture_visual_selection()
    sel.cursor_line = sel.end_line
    sel.cursor_col  = sel.end_col + 1
    window.add_suggestion(sub, sel, M.config)
  else
    vim.notify("inline-review: unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.g.inline_review_setup_done = true

  local ag = vim.api.nvim_create_augroup("InlineReviewSetup", { clear = true })

  apply_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group    = ag,
    pattern  = "*",
    callback = apply_highlights,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group    = ag,
    pattern  = { "markdown", "text" },
    callback = function(ev)
      local win = vim.fn.bufwinid(ev.buf)
      if win ~= -1 then
        vim.wo[win].conceallevel = 2
        vim.wo[win].concealcursor = "n"
      end
      attach_source_keymaps(ev.buf)
      maybe_auto_open(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group    = ag,
    pattern  = "inline-review",
    callback = function(ev)
      attach_pane_keymaps(ev.buf)
    end,
  })

  vim.api.nvim_create_user_command("InlineReview", run_command, {
    nargs    = "?",
    range    = true,
    desc     = "Inline review: toggle|open|close|next|prev|comment|addition|deletion|replacement",
    complete = function(prefix)
      return vim.tbl_filter(function(s)
        return vim.startswith(s, prefix)
      end, SUBCOMMANDS)
    end,
  })
end

return M
