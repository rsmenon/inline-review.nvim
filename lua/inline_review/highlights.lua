local util = require("inline_review.util")

local M = {}

local NS = vim.api.nvim_create_namespace("inline_review")

local REF = "{#([%w_%-]+)}"

local buf_pos_map = {}
local buf_conceal_map = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(ev)
    buf_pos_map[ev.buf] = nil
    buf_conceal_map[ev.buf] = nil
  end,
})

local function conceal(buf, row, cs, ce)
  if cs >= ce then return end
  vim.api.nvim_buf_set_extmark(buf, NS, row, cs, {
    end_col = ce,
    conceal = "",
  })
  local cmap = buf_conceal_map[buf]
  cmap[row] = cmap[row] or {}
  table.insert(cmap[row], { cs, ce })
end

local function hl(buf, row, cs, ce, group, id)
  if cs >= ce then return end
  vim.api.nvim_buf_set_extmark(buf, NS, row, cs, {
    end_col  = ce,
    hl_group = group,
    priority = 150,
  })
  if id then
    local pmap = buf_pos_map[buf]
    pmap[row] = pmap[row] or {}
    table.insert(pmap[row], { cs, ce, id })
  end
end

function M.apply(source_buf)
  if not vim.api.nvim_buf_is_valid(source_buf) then return end
  vim.api.nvim_buf_clear_namespace(source_buf, NS, 0, -1)
  buf_pos_map[source_buf] = {}
  buf_conceal_map[source_buf] = {}

  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local content_end = sep and (sep - 1) or #lines

  local matched_ids = {}

  for lnum = 1, content_end do
    local line = lines[lnum]
    if not line:find("{", 1, true) then goto next_line end
    local row = lnum - 1
    local pos = 1

    while true do
      local s, e, anchor, _, id = line:find("{==(.-)==}{>>(.-)<<}" .. REF, pos)
      if not s then break end
      local b = s - 1
      conceal(source_buf, row, b,               b + 3)
      hl     (source_buf, row, b + 3,           b + 3 + #anchor, "InlineReviewComment", id)
      conceal(source_buf, row, b + 3 + #anchor, e)
      matched_ids[id] = true
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, text, id = line:find("{%+%+(.-)%+%+}" .. REF, pos)
      if not s then break end
      local b = s - 1
      conceal(source_buf, row, b,             b + 3)
      hl     (source_buf, row, b + 3,         b + 3 + #text, "InlineReviewAddition", id)
      conceal(source_buf, row, b + 3 + #text, e)
      matched_ids[id] = true
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, text, id = line:find("{%-%-(.-)%-%-}" .. REF, pos)
      if not s then break end
      local b = s - 1
      conceal(source_buf, row, b,             b + 3)
      hl     (source_buf, row, b + 3,         b + 3 + #text, "InlineReviewDeletion", id)
      conceal(source_buf, row, b + 3 + #text, e)
      matched_ids[id] = true
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, old_t, new_t, id = line:find("{~~(.-)~>(.-)~~}" .. REF, pos)
      if not s then break end
      local b         = s - 1
      local old_end   = b + 3 + #old_t
      local new_start = old_end + 2
      local new_end   = new_start + #new_t
      conceal(source_buf, row, b,         b + 3)
      hl     (source_buf, row, b + 3,     old_end,   "InlineReviewDeletion", id)
      conceal(source_buf, row, old_end,   new_start)
      hl     (source_buf, row, new_start, new_end,   "InlineReviewAddition", id)
      conceal(source_buf, row, new_end,   e)
      matched_ids[id] = true
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, anchor, id = line:find("{==(.-)==}" .. REF, pos)
      if not s then break end
      local b = s - 1
      conceal(source_buf, row, b,               b + 3)
      hl     (source_buf, row, b + 3,           b + 3 + #anchor, "InlineReviewComment", id)
      conceal(source_buf, row, b + 3 + #anchor, e)
      matched_ids[id] = true
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, body, id = line:find("{>>(.-)<<}" .. REF, pos)
      if not s then break end
      if not matched_ids[id] then
        local b = s - 1
        conceal(source_buf, row, b,             b + 3)
        hl     (source_buf, row, b + 3,         b + 3 + #body, "InlineReviewComment", id)
        conceal(source_buf, row, b + 3 + #body, e)
      end
      pos = e + 1
    end
  ::next_line::
  end

  if sep then
    local start = sep
    if sep > 1 and lines[sep - 1] == "" then start = sep - 1 end
    for lnum = start, #lines do
      if #lines[lnum] > 0 then
        vim.api.nvim_buf_set_extmark(source_buf, NS, lnum - 1, 0, {
          end_col  = #lines[lnum],
          conceal  = "",
          hl_group = "InlineReviewMeta",
          priority = 100,
        })
      else
        vim.api.nvim_buf_set_extmark(source_buf, NS, lnum - 1, 0, {
          conceal = "",
        })
      end
    end
  end
end

function M.id_at(source_buf, row_0, col_0)
  local pmap = buf_pos_map[source_buf]
  if not pmap then return nil end
  local spans = pmap[row_0]
  if not spans then return nil end
  for _, span in ipairs(spans) do
    if span[1] <= col_0 and col_0 < span[2] then
      return span[3]
    end
  end
  return nil
end

function M.in_conceal(source_buf, row_0, col_0)
  local cmap = buf_conceal_map[source_buf]
  if not cmap then return nil end
  local ranges = cmap[row_0]
  if not ranges then return nil end
  for _, r in ipairs(ranges) do
    if r[1] <= col_0 and col_0 < r[2] then
      return r[2]
    end
  end
  return nil
end

function M.conceal_bounds(source_buf, row_0, col_0)
  local cmap = buf_conceal_map[source_buf]
  if not cmap then return nil end
  local ranges = cmap[row_0]
  if not ranges then return nil end
  for _, r in ipairs(ranges) do
    if r[1] <= col_0 and col_0 < r[2] then
      return r[1], r[2]
    end
  end
  return nil
end

function M.clear(source_buf)
  if vim.api.nvim_buf_is_valid(source_buf) then
    vim.api.nvim_buf_clear_namespace(source_buf, NS, 0, -1)
  end
  buf_pos_map[source_buf] = nil
  buf_conceal_map[source_buf] = nil
end

return M
