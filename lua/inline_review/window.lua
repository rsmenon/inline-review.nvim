local storage    = require("inline_review.storage")
local renderer   = require("inline_review.renderer")
local highlights = require("inline_review.highlights")
local util       = require("inline_review.util")

local M = {}

local FOCUS_NS = vim.api.nvim_create_namespace("inline_review_focus")
local FLASH_NS = vim.api.nvim_create_namespace("inline_review_flash")

local function flash_line(win, lnum)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if #line > 0 then
    vim.api.nvim_buf_set_extmark(buf, FLASH_NS, lnum - 1, 0, {
      end_col  = #line,
      hl_group = "Visual",
    })
  end
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

  -- Insert the newline as a buffer edit: feeding <CR> would be remapped to
  -- the submit mapping below.
  local function insert_newline()
    if not vim.api.nvim_win_is_valid(fwin) then return end
    local pos = vim.api.nvim_win_get_cursor(fwin)
    vim.api.nvim_buf_set_text(fbuf, pos[1] - 1, pos[2], pos[1] - 1, pos[2], { "", "" })
    vim.api.nvim_win_set_cursor(fwin, { pos[1] + 1, 0 })
    local count = vim.api.nvim_buf_line_count(fbuf)
    vim.api.nvim_win_set_config(fwin, { height = math.min(count, 10) })
  end

  vim.keymap.set("i", "<CR>",   submit,         { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<S-CR>", insert_newline, { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<C-j>",  insert_newline, { buffer = fbuf, nowait = true })
  vim.keymap.set("i", "<Esc>",  cancel,         { buffer = fbuf, nowait = true })
  vim.keymap.set("n", "<Esc>",  cancel,         { buffer = fbuf, nowait = true })
  vim.keymap.set("n", "q",      cancel,         { buffer = fbuf, nowait = true })

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
  win_id           = nil,
  buf_id           = nil,
  source_buf       = nil,
  source_win       = nil,
  source_file      = nil,
  config           = {},
  syncing          = false,
  focused_id       = nil,
  focused_reply_id = nil,
  source_augroup   = nil,
  pane_augroup     = nil,
}

local source_timer = nil

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

local function should_track(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  local ft = vim.bo[buf].filetype
  if ft ~= "markdown" and ft ~= "text" then return false end
  return vim.api.nvim_buf_get_name(buf) ~= ""
end

local function detach_source()
  if state.source_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.source_augroup)
    state.source_augroup = nil
  end
  if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
    for _, key in ipairs({ "w", "b", "e" }) do
      pcall(vim.keymap.del, "n", key, { buffer = state.source_buf })
    end
    highlights.clear(state.source_buf)
  end
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win)
      and state._prev_foldmethod then
    vim.wo[state.source_win].foldmethod = state._prev_foldmethod
  end
  state._prev_foldmethod = nil
  state.source_buf  = nil
  state.source_win  = nil
  state.source_file = nil
  state.focused_id       = nil
  state.focused_reply_id = nil
end

local function attach_source(buf, win)
  state.source_buf  = buf
  state.source_win  = win
  state.source_file = vim.api.nvim_buf_get_name(buf)
  state.focused_id       = nil
  state.focused_reply_id = nil

  state._prev_foldmethod = vim.wo[win].foldmethod
  if state._prev_foldmethod ~= "manual" then
    vim.wo[win].foldmethod = "manual"
  end

  local ag = vim.api.nvim_create_augroup("InlineReviewSource", { clear = true })
  state.source_augroup = ag

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group    = ag,
    buffer   = buf,
    callback = schedule_source_to_pane,
  })

  local snap_guard = false
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = ag,
    buffer   = buf,
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

  vim.api.nvim_create_autocmd("WinLeave", {
    group  = ag,
    buffer = buf,
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

  for _, key in ipairs({ "w", "b", "e" }) do
    vim.keymap.set("n", key, conceal_aware_motion(key), { buffer = buf })
  end

  sync_source_to_pane()
end

local function retarget(buf, win)
  detach_source()
  attach_source(buf, win)
end

function M.open(opts)
  if is_open() then M.close() end

  opts = opts or {}
  local width = opts.width or 45

  local src_buf = vim.api.nvim_get_current_buf()
  local src_win = vim.api.nvim_get_current_win()

  if vim.api.nvim_buf_get_name(src_buf) == "" then
    vim.notify("inline-review: save the buffer before reviewing", vim.log.levels.WARN)
    return
  end

  state.config = opts

  if not state.buf_id or not vim.api.nvim_buf_is_valid(state.buf_id) then
    state.buf_id = make_review_buf()
  end

  source_timer = vim.uv.new_timer()

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

  local pane_ag = vim.api.nvim_create_augroup("InlineReviewPane", { clear = true })
  state.pane_augroup = pane_ag

  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = pane_ag,
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
          local target_win = vim.fn.bufwinid(state.source_buf)
          if target_win ~= -1 then
            vim.api.nvim_win_call(target_win, function()
              vim.api.nvim_win_set_cursor(target_win, { item.start_line, item.start_col or 0 })
              vim.cmd("normal! zz")
            end)
            flash_line(target_win, item.start_line)
          end
          return
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group   = pane_ag,
    pattern = "conceallevel",
    callback = function()
      if not is_open() then return end
      if not state.source_win or not vim.api.nvim_win_is_valid(state.source_win) then return end
      if vim.wo[state.source_win].conceallevel ~= 2 then
        vim.wo[state.source_win].conceallevel = 2
      end
    end,
  })

  -- Follow the user into other annotated files: retarget the pane when a
  -- different markdown/text file buffer becomes current.
  vim.api.nvim_create_autocmd("BufEnter", {
    group    = pane_ag,
    callback = function(ev)
      if not is_open() then return end
      local win = vim.api.nvim_get_current_win()
      if win == state.win_id or ev.buf == state.buf_id then return end
      if vim.api.nvim_win_get_config(win).relative ~= "" then return end
      if ev.buf == state.source_buf and win == state.source_win then return end
      if not should_track(ev.buf) then return end
      retarget(ev.buf, win)
    end,
  })

  -- Clean up state when the pane window is closed externally (:q, :close, ...).
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = pane_ag,
    pattern  = tostring(state.win_id),
    callback = function()
      vim.schedule(M.close)
    end,
  })

  attach_source(src_buf, src_win)

  vim.api.nvim_set_current_win(src_win)
end

function M.close()
  if source_timer then source_timer:stop(); source_timer:close(); source_timer = nil end
  detach_source()
  if state.pane_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.pane_augroup)
    state.pane_augroup = nil
  end
  if is_open() then
    local win = state.win_id
    state.win_id = nil
    vim.api.nvim_win_close(win, true)
  end
  state.win_id = nil
  if state.buf_id and vim.api.nvim_buf_is_valid(state.buf_id) then
    vim.api.nvim_buf_clear_namespace(state.buf_id, FOCUS_NS, 0, -1)
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
    M.open(opts)
    if not is_open() then return end
  elseif src_buf ~= state.source_buf then
    retarget(src_buf, vim.api.nvim_get_current_win())
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
