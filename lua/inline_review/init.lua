local window     = require("inline_review.window")
local renderer   = require("inline_review.renderer")
local storage    = require("inline_review.storage")
local highlights = require("inline_review.highlights")

local M = {}

M.config = {
  width  = 45,
  author = vim.uv.os_get_passwd().username,
}

local function capture_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  return { start_line = s[2], end_line = e[2], start_col = s[3], end_col = e[3] }
end

local function on_visual(fn)
  return function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    local sel = capture_visual_selection()
    sel.cursor_line = vim.fn.line(".")
    sel.cursor_col  = vim.fn.col(".")
    fn(sel)
  end
end

local function attach_source_keymaps(buf)
  local o = { buffer = buf }

  vim.keymap.set("n", "<leader>rp", function()
    window.toggle(M.config)
  end, vim.tbl_extend("force", o, { desc = "Toggle inline review pane" }))

  vim.keymap.set("n", "gd", function()
    window.jump_to_pane()
  end, vim.tbl_extend("force", o, { desc = "Jump to review item in pane" }))

  vim.keymap.set("v", "<leader>rc", on_visual(function(sel)
    window.add_suggestion("comment", sel, M.config)
  end), vim.tbl_extend("force", o, { desc = "Add review comment" }))

  vim.keymap.set("v", "<leader>ra", on_visual(function(sel)
    window.add_suggestion("addition", sel, M.config)
  end), vim.tbl_extend("force", o, { desc = "Propose addition" }))

  vim.keymap.set("v", "<leader>rd", on_visual(function(sel)
    window.add_suggestion("deletion", sel, M.config)
  end), vim.tbl_extend("force", o, { desc = "Propose deletion" }))

  vim.keymap.set("v", "<leader>rr", on_visual(function(sel)
    window.add_suggestion("replacement", sel, M.config)
  end), vim.tbl_extend("force", o, { desc = "Propose replacement" }))

  local function jump_to_annotation(direction)
    return function()
      local items = storage.parse(vim.api.nvim_get_current_buf())
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
  end

  vim.keymap.set("n", "]r", jump_to_annotation("next"),
    vim.tbl_extend("force", o, { desc = "Next inline review annotation" }))
  vim.keymap.set("n", "[r", jump_to_annotation("prev"),
    vim.tbl_extend("force", o, { desc = "Previous inline review annotation" }))
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

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.g.inline_review_setup_done = true

  apply_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { pattern = "*", callback = apply_highlights })

  vim.api.nvim_create_autocmd("FileType", {
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
    pattern  = "inline-review",
    callback = function()
      vim.keymap.set("n", "gd", window.peek_source,
        { buffer = true, desc = "Peek source location (keep focus in pane)" })
      vim.keymap.set("n", "<CR>", window.jump_to_source,
        { buffer = true, desc = "Jump to source location" })

      vim.keymap.set("n", "j", function()
        local lnum = renderer.next_block_line()
        if lnum then vim.api.nvim_win_set_cursor(0, { lnum, 0 }) end
      end, { buffer = true, desc = "Next review block" })

      vim.keymap.set("n", "k", function()
        local lnum = renderer.prev_block_line()
        if lnum then vim.api.nvim_win_set_cursor(0, { lnum, 0 }) end
      end, { buffer = true, desc = "Previous review block" })

      vim.keymap.set("n", "A", window.approve_current,
        { buffer = true, desc = "Approve suggestion" })
      vim.keymap.set("n", "D", window.delete_current,
        { buffer = true, desc = "Delete/reject item or reply" })
      vim.keymap.set("n", "R", window.reply_current,
        { buffer = true, desc = "Reply to comment" })
      vim.keymap.set("n", "E", window.edit_current,
        { buffer = true, desc = "Edit comment body" })

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

      vim.keymap.set("n", "u", source_undo("undo"),
        { buffer = true, desc = "Undo in source buffer" })
      vim.keymap.set("n", "<C-r>", source_undo("redo"),
        { buffer = true, desc = "Redo in source buffer" })
    end,
  })
end

return M
