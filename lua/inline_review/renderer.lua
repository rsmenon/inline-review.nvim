local M = {}

local SEP_THIN  = string.rep("\xe2\x94\x80", 42)
local NS        = vim.api.nvim_create_namespace("inline_review_render")

M._line_map      = {}
M._card_ranges   = {}
M._block_targets = {}

local function fmt_time(at)
  if not at or at == "" then return "" end
  local y, mo, d, h, mi = at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not y then return at end
  local t = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = 0,
  })
  local ut = os.date("!*t", t)
  local lt = os.date("*t", t)
  ut.isdst = lt.isdst
  local offset = os.difftime(os.time(lt), os.time(ut))
  return os.date("%Y-%m-%d %H:%M", t + offset)
end

local TYPE_LABEL = {
  comment     = "Comment",
  addition    = "Suggested Addition",
  deletion    = "Suggested Deletion",
  replacement = "Suggested Replacement",
}

local function header_label(item)
  local loc = item.start_line == item.end_line
    and ("L" .. item.start_line)
    or  ("L" .. item.start_line .. "\xe2\x80\x93" .. item.end_line)
  return loc .. " \xc2\xb7 " .. (TYPE_LABEL[item.type] or item.type)
end

local function byline(by, at)
  local parts = {}
  if by and by ~= "" then table.insert(parts, by) end
  local t = fmt_time(at)
  if t ~= "" then table.insert(parts, t) end
  return table.concat(parts, " \xc2\xb7 ")
end

function M.render(buf, items)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = {}
  M._line_map      = {}
  M._card_ranges   = {}
  M._block_targets = {}

  local function push(line, meta)
    table.insert(lines, line)
    if meta then M._line_map[#lines] = meta end
  end

  if #items == 0 then
    push("No review annotations yet.")
    push("")
    push("Visual-select text, then:")
    push("  <leader>rc  comment")
    push("  <leader>ra  propose addition")
    push("  <leader>rd  propose deletion")
    push("  <leader>rr  propose replacement")
    push("")
    push("<leader>rp to close the review pane")
  else
    for i, item in ipairs(items) do
      local card_start = #lines + 1
      local base = { id = item.id, item_type = item.type }
      local function push_item(line, extra)
        push(line, extra and vim.tbl_extend("force", base, extra) or nil)
      end

      push_item(header_label(item),      { field = "header" })
      local bl = byline(item.by, item.at)
      if bl ~= "" then
        push_item(bl, { field = "meta" })
      end

      if item.type == "comment" then
        push_item(SEP_THIN, { field = "sep_thin" })
        if item.anchor and item.anchor ~= "" then
          local display_anchor = item.anchor
          if item.start_line ~= item.end_line then
            display_anchor = display_anchor .. " \xe2\x80\xa6"
          end
          push_item(display_anchor, { field = "anchor" })
        end
        push("", nil)
        for j, line in ipairs(vim.split(item.body or "", "\n", { plain = true })) do
          push_item(line, { field = "body", body_line = j })
        end

      elseif item.type == "addition" then
        push_item("++ " .. (item.text or ""), { field = "content", hl = "InlineReviewAddition" })

      elseif item.type == "deletion" then
        local display_del = item.text or ""
        if item.start_line ~= item.end_line then
          display_del = display_del .. " \xe2\x80\xa6"
        end
        push_item("-- " .. display_del, { field = "content", hl = "InlineReviewDeletion" })

      elseif item.type == "replacement" then
        local display_old = item.old_text or ""
        if item.start_line ~= item.end_line and item.text then
          display_old = item.text .. " \xe2\x80\xa6 " .. display_old
        end
        push_item("~~ " .. display_old, { field = "content", hl = "InlineReviewDeletion" })
        push_item("~> " .. (item.new_text or ""), { field = "content", hl = "InlineReviewAddition" })
      end

      local reply_depth = {}
      for _, reply in ipairs(item.replies or {}) do
        if reply.re == item.id then
          reply_depth[reply.id] = 1
        else
          reply_depth[reply.id] = (reply_depth[reply.re] or 1) + 1
        end
      end

      for _, reply in ipairs(item.replies or {}) do
        push("", nil)
        local d = reply_depth[reply.id] or 1
        local indent = string.rep("  ", d)
        local rb = { id = item.id, item_type = item.type, reply_id = reply.id, reply_depth = d }
        local function push_reply(line, extra)
          push(line, extra and vim.tbl_extend("force", rb, extra) or nil)
        end
        push_reply(indent .. "\xe2\x86\xb3 " .. byline(reply.by, reply.at), { field = "reply_header" })
        for j, line in ipairs(vim.split(reply.body or "", "\n", { plain = true })) do
          push_reply(indent .. line, { field = "reply_body", body_line = j })
        end
      end

      M._card_ranges[i] = { id = item.id, item_type = item.type, start_lnum = card_start, end_lnum = #lines }

      if i < #items then
        push("", nil)
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for lnum, meta in pairs(M._line_map) do
    local hl = meta.hl
    if not hl then
      if     meta.field == "header"        then hl = "InlineReviewTitle"
      elseif meta.field == "meta"          then hl = "InlineReviewMeta"
      elseif meta.field == "anchor"        then hl = "InlineReviewComment"
      elseif meta.field == "body"          then hl = "InlineReviewContents"
      elseif meta.field == "reply_header"  then hl = "InlineReviewMeta"
      elseif meta.field == "reply_body"    then hl = "InlineReviewContents"
      elseif meta.field == "sep_thin"      then hl = "InlineReviewSep"
      end
    end
    if hl and #lines[lnum] > 0 then
      vim.api.nvim_buf_set_extmark(buf, NS, lnum - 1, 0, {
        end_col  = #lines[lnum],
        hl_group = hl,
      })
    end
    if meta.field == "header" or meta.field == "reply_header" then
      M._block_targets[#M._block_targets + 1] = lnum
    end
  end
  table.sort(M._block_targets)
end

function M.context_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return M._line_map[lnum]
end

function M.comment_at_cursor()
  local meta = M.context_at_cursor()
  return meta and meta.id or nil
end

function M.card_ranges()
  return M._card_ranges
end

function M.header_line_for(id)
  for lnum, meta in pairs(M._line_map) do
    if meta.id == id and meta.field == "header" then return lnum end
  end
  return nil
end

function M.next_block_line()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for _, lnum in ipairs(M._block_targets) do
    if lnum > cur then return lnum end
  end
end

function M.prev_block_line()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for i = #M._block_targets, 1, -1 do
    if M._block_targets[i] < cur then return M._block_targets[i] end
  end
end

return M
