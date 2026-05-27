local storage   = require("inline_review.storage")
local renderer  = require("inline_review.renderer")
local highlights = require("inline_review.highlights")

local M = {}

local FOCUS_NS = vim.api.nvim_create_namespace("inline_review_focus")
local FLASH_NS = vim.api.nvim_create_namespace("inline_review_flash")

local function flash_line(win, lnum)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_add_highlight(buf, FLASH_NS, "Visual", lnum - 1, 0, -1)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, FLASH_NS, 0, -1)
    end
  end, 300)
end

local function open_input_float(opts)
  local width       = opts.width or 50
  local init_lines  = opts.init_lines or {}
  local init_height = math.max(1, math.min(#init_lines, 10))
  local return_win  = opts.return_win or vim.api.nvim_get_current_win()

  local winline   = vim.fn.winline()
  local winheight = vim.fn.winheight(0)
  local row
  if winheight - winline >= init_height + 1 then
    row = 1
  else
    row = -(init_height + 2)
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype  = "nofile"
  vim.bo[fbuf].swapfile = false

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative  = "cursor",
    row       = row,
    col       = 0,
    width     = width,
    height    = init_height,
    style     = "minimal",
    border    = "rounded",
    title     = opts.title or " Input ",
    title_pos = "left",
    zindex    = 60,
    focusable = true,
  })
  vim.wo[fwin].wrap = true

  if #init_lines > 0 then
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, init_lines)
  end

  local closed = false
  local function close_float()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(fwin) then
      vim.api.nvim_win_close(fwin, true)
    end
    if vim.api.nvim_buf_is_valid(fbuf) then
      vim.api.nvim_buf_delete(fbuf, { force = true })
    end
    if vim.api.nvim_win_is_valid(return_win) then
      vim.api.nvim_set_current_win(return_win)
    end
    vim.cmd("stopinsert")
  end

  local function submit()
    if closed then return end
    local lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    local text = table.concat(lines, "\n")
    close_float()
    if opts.on_submit then opts.on_submit(text) end
  end

  local function cancel()
    if closed then return end
    close_float()
    if opts.on_cancel then opts.on_cancel() end
  end

  local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  vim.keymap.set("i", "<CR>",  submit,  { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<S-CR>", function()
    vim.api.nvim_feedkeys(cr, "i", false)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(fwin) then return end
      local count = vim.api.nvim_buf_line_count(fbuf)
      vim.api.nvim_win_set_config(fwin, { height = math.min(count, 10) })
    end)
  end, { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<C-j>", function()
    vim.api.nvim_feedkeys(cr, "i", false)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(fwin) then return end
      local count = vim.api.nvim_buf_line_count(fbuf)
      vim.api.nvim_win_set_config(fwin, { height = math.min(count, 10) })
    end)
  end, { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = fbuf, nowait = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = fbuf, nowait = true })
  vim.keymap.set("n", "q",     cancel, { buffer = fbuf, nowait = true })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer   = fbuf,
    once     = true,
    callback = function()
      vim.schedule(cancel)
    end,
  })

  vim.api.nvim_set_current_win(fwin)
  vim.cmd("startinsert")
end

local state = {
  win_id      = nil,
  buf_id      = nil,
  source_buf  = nil,
  source_win  = nil,
  source_file = nil,
  config      = {},
  syncing     = false,
  focused_id       = nil,
  focused_reply_id = nil,
  augroup          = nil,
}

local source_timer = nil
local pane_timer   = nil

local function is_open()
  return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

function M.is_open() return is_open() end

function M.source_buf() return state.source_buf end

local function with_sync(fn)
  state.syncing = true
  local ok, err = pcall(fn)
  state.syncing = false
  if not ok then
    vim.notify("inline-review: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local COMMENT_ACTION = {
  { "[E]", "InlineReviewEdit" },     { " Edit  ", "InlineReviewAction" },
  { "[D]", "InlineReviewDelete" },   { " Delete  ", "InlineReviewAction" },
  { "[R]", "InlineReviewReply" },    { " Reply", "InlineReviewAction" },
}
local SUGGEST_ACTION = {
  { "[A]", "InlineReviewAccept" },   { " Approve  ", "InlineReviewAction" },
  { "[D]", "InlineReviewDelete" },   { " Delete  ", "InlineReviewAction" },
  { "[R]", "InlineReviewReply" },    { " Reply", "InlineReviewAction" },
}

local function find_block_end(card, focused_reply_id)
  local lmap = renderer._line_map
  if focused_reply_id then
    local last = nil
    for lnum = card.start_lnum, card.end_lnum do
      local meta = lmap[lnum]
      if meta and meta.reply_id == focused_reply_id then last = lnum end
    end
    return last
  else
    local last = card.start_lnum
    for lnum = card.start_lnum, card.end_lnum do
      local meta = lmap[lnum]
      if meta and meta.reply_id then break end
      if meta then last = lnum end
    end
    return last
  end
end

local function apply_card_focus(focused_id, focused_reply_id)
  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then return end
  vim.api.nvim_buf_clear_namespace(state.buf_id, FOCUS_NS, 0, -1)

  for _, card in ipairs(renderer.card_ranges()) do
    local active    = card.id == focused_id
    local border_hl = active and "InlineReviewActiveBorder" or "InlineReviewInactiveBorder"

    local action_lnum = nil
    local action_line = nil
    if active then
      action_lnum = find_block_end(card, focused_reply_id)
      if focused_reply_id or card.item_type == "comment" then
        action_line = COMMENT_ACTION
      else
        action_line = SUGGEST_ACTION
      end
    end

    for lnum = card.start_lnum, card.end_lnum do
      local opts = {
        sign_text     = "\xe2\x96\x8e",
        sign_hl_group = border_hl,
        priority      = 180,
      }
      if active then
        opts.line_hl_group = "InlineReviewActiveCardBg"
        if lnum == action_lnum then
          opts.virt_lines = { action_line }
        end
      end
      vim.api.nvim_buf_set_extmark(state.buf_id, FOCUS_NS, lnum - 1, 0, opts)
    end
  end
end

local function fold_endmatter()
  if not state.source_buf or not state.source_win then return end
  if not vim.api.nvim_buf_is_valid(state.source_buf) then return end
  if not vim.api.nvim_win_is_valid(state.source_win) then return end

  local util = require("inline_review.util")
  local lines = vim.api.nvim_buf_get_lines(state.source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  if not sep then return end

  local fold_start = sep
  if sep > 1 and lines[sep - 1] == "" then fold_start = sep - 1 end

  vim.api.nvim_win_call(state.source_win, function()
    pcall(vim.cmd, fold_start .. "," .. #lines .. "foldopen!")
    pcall(vim.cmd, fold_start .. "," .. #lines .. "fold")
  end)
end

local function sync_source_to_pane()
  if state.syncing then return end
  if not state.source_buf or not state.buf_id then return end
  if not vim.api.nvim_buf_is_valid(state.source_buf) then return end
  if not vim.api.nvim_buf_is_valid(state.buf_id) then return end

  state.syncing = true
  if pane_timer then pane_timer:stop() end

  local ok, err = pcall(function()
    local items = storage.parse(state.source_buf)
    renderer.render(state.buf_id, items)
    highlights.apply(state.source_buf)
    fold_endmatter()
    apply_card_focus(state.focused_id, state.focused_reply_id)
  end)

  state.syncing = false
  if not ok then vim.notify("inline-review: " .. tostring(err), vim.log.levels.ERROR) end
end

local function sync_pane_to_source()
  if state.syncing then return end
  if not state.source_buf or not state.buf_id then return end
  if not vim.api.nvim_buf_is_valid(state.source_buf) then return end
  if not vim.api.nvim_buf_is_valid(state.buf_id) then return end

  state.syncing = true

  local ok, err = pcall(function()
    local pane_lines = vim.api.nvim_buf_get_lines(state.buf_id, 0, -1, false)
    local lmap       = renderer._line_map

    local bodies      = {}
    local reply_bodies = {}

    for lnum, meta in pairs(lmap) do
      if meta.field == "body" and meta.body_line then
        bodies[meta.id] = bodies[meta.id] or {}
        bodies[meta.id][meta.body_line] = pane_lines[lnum] or ""
      elseif meta.field == "reply_body" and meta.reply_id and meta.body_line then
        reply_bodies[meta.reply_id] = reply_bodies[meta.reply_id] or {}
        local strip = (meta.reply_depth or 1) * 2
        reply_bodies[meta.reply_id][meta.body_line] = (pane_lines[lnum] or ""):sub(strip + 1)
      end
    end

    local function parts_to_text(parts)
      local max = 0
      for k in pairs(parts) do if k > max then max = k end end
      local t = {}
      for k = 1, max do t[k] = parts[k] or "" end
      return table.concat(t, "\n")
    end

    for id, parts in pairs(bodies) do
      storage.update_comment_body(state.source_buf, id, parts_to_text(parts))
    end
    for rid, parts in pairs(reply_bodies) do
      storage.update_reply_body(state.source_buf, rid, parts_to_text(parts))
    end
  end)

  state.syncing = false
  if not ok then vim.notify("inline-review: " .. tostring(err), vim.log.levels.ERROR) end
end

local function sync_cursor_to_pane()
  if state.syncing or not is_open() or not state.source_buf then return end
  if not vim.api.nvim_buf_is_valid(state.source_buf) then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row_0  = cursor[1] - 1
  local col_0  = cursor[2]

  local id = highlights.id_at(state.source_buf, row_0, col_0)
  if id == state.focused_id and state.focused_reply_id == nil then return end
  state.focused_id = id
  state.focused_reply_id = nil

  apply_card_focus(id, nil)

  if not id then return end

  local header_lnum = renderer.header_line_for(id)
  if not header_lnum then return end

  if vim.api.nvim_win_is_valid(state.win_id) then
    vim.api.nvim_win_set_cursor(state.win_id, { header_lnum, 0 })
  end
end

local function schedule_source_to_pane()
  if state.syncing or not source_timer then return end
  source_timer:stop()
  source_timer:start(150, 0, vim.schedule_wrap(sync_source_to_pane))
end

local function schedule_pane_to_source()
  if state.syncing or not pane_timer then return end
  pane_timer:stop()
  pane_timer:start(150, 0, vim.schedule_wrap(sync_pane_to_source))
end

local function make_review_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "inline-review://review")
  vim.bo[buf].buftype  = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "inline-review"
  return buf
end

local function conceal_aware_motion(key)
  return function()
    local buf = state.source_buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local count = vim.v.count1
    for _ = 1, count do
      vim.cmd("normal! " .. key)
      local max_iter = 20
      while max_iter > 0 do
        local pos = vim.api.nvim_win_get_cursor(0)
        local row_0, col_0 = pos[1] - 1, pos[2]
        local cs, ce = highlights.conceal_bounds(buf, row_0, col_0)
        if not cs then break end
        if key == "b" then
          if cs == 0 then
            if row_0 == 0 then break end
            local prev = vim.api.nvim_buf_get_lines(buf, row_0 - 1, row_0, false)[1] or ""
            vim.api.nvim_win_set_cursor(0, { row_0, math.max(0, #prev - 1) })
          else
            vim.api.nvim_win_set_cursor(0, { pos[1], cs - 1 })
          end
        else
          local line = vim.api.nvim_buf_get_lines(buf, row_0, row_0 + 1, false)[1] or ""
          if ce >= #line then
            local total = vim.api.nvim_buf_line_count(buf)
            if pos[1] >= total then break end
            vim.api.nvim_win_set_cursor(0, { pos[1] + 1, 0 })
          else
            vim.api.nvim_win_set_cursor(0, { pos[1], ce })
          end
        end
        max_iter = max_iter - 1
      end
    end
  end
end

local function setup_autocmds()
  local ag = vim.api.nvim_create_augroup("InlineReview", { clear = true })
  state.augroup = ag

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group    = ag,
    buffer   = state.source_buf,
    callback = schedule_source_to_pane,
  })

  local snap_guard = false
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = ag,
    buffer   = state.source_buf,
    callback = function()
      if snap_guard then
        snap_guard = false
        sync_cursor_to_pane()
        return
      end
      local pos = vim.api.nvim_win_get_cursor(0)
      local snap_col = highlights.in_conceal(state.source_buf, pos[1] - 1, pos[2])
      if snap_col then
        snap_guard = true
        vim.api.nvim_win_set_cursor(0, { pos[1], snap_col })
        return
      end
      sync_cursor_to_pane()
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group    = ag,
    buffer   = state.buf_id,
    callback = schedule_pane_to_source,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = ag,
    buffer   = state.buf_id,
    callback = function()
      if state.syncing then return end
      local meta = renderer.context_at_cursor()
      local id       = meta and meta.id or nil
      local reply_id = meta and meta.reply_id or nil
      if id == state.focused_id and reply_id == state.focused_reply_id then return end
      state.focused_id = id
      state.focused_reply_id = reply_id
      apply_card_focus(id, reply_id)
      if not id or not state.source_buf then return end
      local items = storage.parse(state.source_buf)
      for _, item in ipairs(items) do
        if item.id == id then
          local src_win = vim.fn.bufwinid(state.source_buf)
          if src_win ~= -1 then
            vim.api.nvim_win_call(src_win, function()
              vim.api.nvim_win_set_cursor(src_win, { item.start_line, item.start_col or 0 })
              vim.cmd("normal! zz")
            end)
            flash_line(src_win, item.start_line)
          end
          return
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group   = ag,
    pattern = "conceallevel",
    callback = function()
      if not is_open() then return end
      if not state.source_win or not vim.api.nvim_win_is_valid(state.source_win) then return end
      if vim.wo[state.source_win].conceallevel ~= 2 then
        vim.wo[state.source_win].conceallevel = 2
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group  = ag,
    buffer = state.source_buf,
    callback = function()
      vim.schedule(function()
        if not is_open() then return end
        if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
          highlights.apply(state.source_buf)
        end
        if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
          vim.wo[state.source_win].conceallevel = 2
          vim.wo[state.source_win].concealcursor = "n"
        end
      end)
    end,
  })

  for _, key in ipairs({"w", "b", "e"}) do
    vim.keymap.set("n", key, conceal_aware_motion(key), { buffer = state.source_buf })
  end
end

function M.open(opts)
  if is_open() then M.close() end

  opts = opts or {}
  local width = opts.width or 45

  state.source_buf  = vim.api.nvim_get_current_buf()
  state.source_win  = vim.api.nvim_get_current_win()
  state.source_file = vim.api.nvim_buf_get_name(state.source_buf)
  state.config      = opts

  if state.source_file == "" then
    vim.notify("inline-review: save the buffer before reviewing", vim.log.levels.WARN)
    return
  end

  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then
    state.buf_id = make_review_buf()
  end

  source_timer = vim.uv.new_timer()
  pane_timer = vim.uv.new_timer()

  local source_win = vim.api.nvim_get_current_win()

  vim.cmd("botright vsplit")
  state.win_id = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win_id, state.buf_id)
  vim.api.nvim_win_set_width(state.win_id, width)

  vim.wo[state.win_id].winfixwidth    = true
  vim.wo[state.win_id].wrap           = true
  vim.wo[state.win_id].number         = false
  vim.wo[state.win_id].relativenumber = false
  vim.wo[state.win_id].signcolumn     = "yes:1"
  vim.wo[state.win_id].cursorline     = false
  vim.wo[state.win_id].scrolloff      = 3
  vim.wo[state.win_id].winhighlight   =
    "Normal:InlineReviewPaneBg,EndOfBuffer:InlineReviewPaneBg,SignColumn:InlineReviewPaneBg"
  pcall(function() vim.wo[state.win_id].winbar = " Inline Review" end)

  if opts.animate then
    local target  = width
    local step    = math.ceil(target / 8)
    local current = 1
    vim.api.nvim_win_set_width(state.win_id, 1)
    local anim_timer = vim.uv.new_timer()
    anim_timer:start(0, 16, vim.schedule_wrap(function()
      if not is_open() then anim_timer:stop(); anim_timer:close(); return end
      current = math.min(current + step, target)
      vim.api.nvim_win_set_width(state.win_id, current)
      if current >= target then anim_timer:stop(); anim_timer:close() end
    end))
  end

  state._prev_foldmethod = vim.wo[state.source_win].foldmethod
  if state._prev_foldmethod ~= "manual" then
    vim.wo[state.source_win].foldmethod = "manual"
  end

  sync_source_to_pane()
  setup_autocmds()

  vim.api.nvim_set_current_win(source_win)
end

function M.close()
  if source_timer then source_timer:stop(); source_timer:close(); source_timer = nil end
  if pane_timer then pane_timer:stop(); pane_timer:close(); pane_timer = nil end
  state.focused_id = nil
  state.focused_reply_id = nil
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    if state._prev_foldmethod then
      vim.wo[state.source_win].foldmethod = state._prev_foldmethod
      state._prev_foldmethod = nil
    end
  end
  state.source_win = nil
  if is_open() then
    vim.api.nvim_win_close(state.win_id, true)
    state.win_id = nil
  end
  if state.buf_id and vim.api.nvim_buf_is_valid(state.buf_id) then
    vim.api.nvim_buf_clear_namespace(state.buf_id, FOCUS_NS, 0, -1)
  end
  if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
    for _, key in ipairs({"w", "b", "e"}) do
      pcall(vim.keymap.del, "n", key, { buffer = state.source_buf })
    end
    highlights.clear(state.source_buf)
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

function M.toggle(opts)
  if is_open() then M.close() else M.open(opts) end
end

function M.add_suggestion(stype, sel, opts)
  local src_buf  = vim.api.nvim_get_current_buf()
  local src_name = vim.api.nvim_buf_get_name(src_buf)

  if src_name == "" then
    vim.notify("inline-review: save the buffer before reviewing", vim.log.levels.WARN)
    return
  end

  if not is_open() then
    state.source_buf  = src_buf
    state.source_file = src_name
    M.open(opts)
    state.source_buf  = src_buf
    state.source_file = src_name
  end

  local author      = opts and opts.author or ""
  local return_win  = vim.api.nvim_get_current_win()

  if stype == "comment" then
    open_input_float({
      title      = " Comment ",
      return_win = return_win,
      on_submit  = function(text)
        with_sync(function()
          storage.insert_comment(state.source_buf, sel, author, text)
        end)
        sync_source_to_pane()
      end,
    })

  elseif stype == "addition" then
    open_input_float({
      title      = " Add text ",
      return_win = return_win,
      on_submit  = function(text)
        if text == "" then return end
        with_sync(function()
          storage.insert_addition(state.source_buf, sel, text, author)
        end)
        sync_source_to_pane()
      end,
    })

  elseif stype == "deletion" then
    with_sync(function()
      storage.insert_deletion(state.source_buf, sel, author)
    end)
    sync_source_to_pane()

  elseif stype == "replacement" then
    open_input_float({
      title      = " Replace with ",
      return_win = return_win,
      on_submit  = function(text)
        if text == "" then return end
        with_sync(function()
          storage.insert_replacement(state.source_buf, sel, text, author)
        end)
        sync_source_to_pane()
      end,
    })
  end
end

function M.approve_current()
  local ctx = renderer.context_at_cursor()
  if not ctx or not state.source_buf then return end
  if ctx.reply_id then return end
  if ctx.item_type == "comment" then
    vim.notify("inline-review: use D to remove a comment", vim.log.levels.INFO)
    return
  end
  with_sync(function()
    storage.approve(state.source_buf, ctx.id)
  end)
  sync_source_to_pane()
end

function M.delete_current()
  local ctx = renderer.context_at_cursor()
  if not ctx or not state.source_buf then return end
  with_sync(function()
    if ctx.reply_id then
      storage.delete_reply(state.source_buf, ctx.reply_id)
    else
      storage.reject(state.source_buf, ctx.id)
    end
  end)
  sync_source_to_pane()
end

function M.reply_current()
  local ctx = renderer.context_at_cursor()
  if not ctx or not state.source_buf then return end
  local parent_id = ctx.reply_id or ctx.id
  local pane_width = state.config and state.config.width or 45
  open_input_float({
    title      = " Reply ",
    width      = pane_width - 4,
    return_win = state.win_id,
    on_submit  = function(text)
      if text == "" then return end
      with_sync(function()
        storage.add_reply(state.source_buf, parent_id, text, state.config.author or "")
      end)
      sync_source_to_pane()
    end,
  })
end

function M.edit_current()
  local ctx = renderer.context_at_cursor()
  if not ctx or not state.source_buf then return end

  local items = storage.parse(state.source_buf)
  local body, title, on_save

  if ctx.reply_id then
    for _, item in ipairs(items) do
      if item.id == ctx.id then
        for _, r in ipairs(item.replies) do
          if r.id == ctx.reply_id then body = r.body; break end
        end
        break
      end
    end
    title = " Edit reply "
    on_save = function(text)
      storage.update_reply_body(state.source_buf, ctx.reply_id, text)
    end
  elseif ctx.item_type == "comment" then
    for _, it in ipairs(items) do
      if it.id == ctx.id then body = it.body; break end
    end
    title = " Edit comment "
    on_save = function(text)
      storage.update_comment_body(state.source_buf, ctx.id, text)
    end
  else
    return
  end

  local pane_width = state.config and state.config.width or 45
  open_input_float({
    title      = title,
    width      = pane_width - 4,
    return_win = state.win_id,
    init_lines = vim.split(body or "", "\n", { plain = true }),
    on_submit  = function(text)
      with_sync(function()
        on_save(text)
      end)
      sync_source_to_pane()
    end,
  })
end

function M.peek_source()
  local id = renderer.comment_at_cursor()
  if not id or not state.source_buf then return end
  local items = storage.parse(state.source_buf)
  for _, item in ipairs(items) do
    if item.id == id then
      local src_win = vim.fn.bufwinid(state.source_buf)
      if src_win ~= -1 then
        vim.api.nvim_win_call(src_win, function()
          vim.api.nvim_win_set_cursor(src_win, { item.start_line, item.start_col or 0 })
          vim.cmd("normal! zz")
        end)
      end
      return
    end
  end
end

function M.jump_to_source()
  local id = renderer.comment_at_cursor()
  if not id or not state.source_buf then return end
  local items = storage.parse(state.source_buf)
  for _, item in ipairs(items) do
    if item.id == id then
      local src_win = vim.fn.bufwinid(state.source_buf)
      if src_win ~= -1 then
        vim.api.nvim_set_current_win(src_win)
        vim.api.nvim_win_set_cursor(src_win, { item.start_line, item.start_col or 0 })
        flash_line(src_win, item.start_line)
      end
      return
    end
  end
end

function M.jump_to_pane()
  if not is_open() or not state.source_buf then return end
  local pos   = vim.api.nvim_win_get_cursor(0)
  local row_0 = pos[1] - 1
  local col_0 = pos[2]

  local id = highlights.id_at(state.source_buf, row_0, col_0)
  if not id then return end

  local header_lnum = renderer.header_line_for(id)
  if not header_lnum then return end

  vim.api.nvim_set_current_win(state.win_id)
  vim.api.nvim_win_set_cursor(state.win_id, { header_lnum, 0 })
end

return M
