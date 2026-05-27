local util = require("inline_review.util")

local M = {}

local REF = "{#([%w_%-]+)}"

local PAT_COMMENT     = "{==(.-)==}{>>(.-)<<}" .. REF
local PAT_ADDITION    = "{%+%+(.-)%+%+}" .. REF
local PAT_DELETION    = "{%-%-(.-)%-%-}" .. REF
local PAT_REPLACEMENT = "{~~(.-)~>(.-)~~}" .. REF

---------------------------------------------------------------------------
-- Parse cache
---------------------------------------------------------------------------

local parse_cache = {}

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(ev)
    parse_cache[ev.buf] = nil
  end,
})

---------------------------------------------------------------------------
-- YAML endmatter
---------------------------------------------------------------------------

local function parse_endmatter(lines, sep)
  local meta = { comments = {}, suggestions = {} }
  if not sep then return meta end

  local section, entry
  local block_key, block_lines

  for i = sep + 1, #lines do
    local line = lines[i]

    if block_key then
      if line:match("^      ") and line:match("%S") then
        table.insert(block_lines, line:sub(7))
        goto continue
      else
        entry[block_key] = table.concat(block_lines, "\n")
        block_key = nil
      end
    end

    local sec = line:match("^(%w+):$")
    if sec and (sec == "comments" or sec == "suggestions") then
      section = sec
      entry = nil
      goto continue
    end

    local eid = line:match("^  ([%w_%-]+):$")
    if eid and section then
      entry = {}
      meta[section][eid] = entry
      goto continue
    end

    if entry then
      local k, v = line:match("^    (%w+):%s+(.*)")
      if k then
        if v == "|" then
          block_key = k
          block_lines = {}
        else
          entry[k] = v:match('^"(.*)"$') or v
        end
      end
    end

    ::continue::
  end

  if block_key and entry then
    entry[block_key] = table.concat(block_lines or {}, "\n")
  end

  return meta
end

local function yaml_value(v)
  if not v or v == "" then return '""' end
  if v:match('[:%s#{}%[%],&*!|>\'"]') or v:match("^[%-%?]") then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  end
  return v
end

local function serialize_endmatter(meta)
  local out = { "---" }
  for _, section in ipairs({ "comments", "suggestions" }) do
    local entries = meta[section]
    if entries and next(entries) then
      table.insert(out, section .. ":")
      local ids = {}
      for id in pairs(entries) do table.insert(ids, id) end
      table.sort(ids, function(a, b)
        local pa, na = a:match("^(%a+)(%d+)$")
        local pb, nb = b:match("^(%a+)(%d+)$")
        if pa and pb and pa == pb then return tonumber(na) < tonumber(nb) end
        return a < b
      end)
      for _, id in ipairs(ids) do
        table.insert(out, "  " .. id .. ":")
        local e = entries[id]
        for _, k in ipairs({ "body", "by", "at", "re", "status", "resolved" }) do
          if e[k] then
            if e[k]:find("\n") then
              table.insert(out, "    " .. k .. ": |")
              for _, bl in ipairs(vim.split(e[k], "\n", { plain = true })) do
                table.insert(out, "      " .. bl)
              end
            else
              table.insert(out, "    " .. k .. ": " .. yaml_value(e[k]))
            end
          end
        end
      end
    end
  end
  return out
end

local function read_endmatter(source_buf)
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  return parse_endmatter(lines, util.find_endmatter_sep(lines))
end

local function write_endmatter(source_buf, meta)
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local has_content = (next(meta.comments) ~= nil) or (next(meta.suggestions) ~= nil)

  if sep then
    if has_content then
      vim.api.nvim_buf_set_lines(source_buf, sep - 1, #lines, false, serialize_endmatter(meta))
    else
      local start = sep - 1
      if sep > 1 and lines[sep - 1] == "" then start = start - 1 end
      vim.api.nvim_buf_set_lines(source_buf, start, #lines, false, {})
    end
  elseif has_content then
    local new = serialize_endmatter(meta)
    if lines[#lines] ~= "" then table.insert(new, 1, "") end
    vim.api.nvim_buf_set_lines(source_buf, #lines, #lines, false, new)
  end
end

---------------------------------------------------------------------------
-- ID generation
---------------------------------------------------------------------------

local function max_id(tbl, prefix)
  local m = 0
  for id in pairs(tbl) do
    local n = tonumber(id:match("^" .. prefix .. "(%d+)$"))
    if n and n > m then m = n end
  end
  return m
end

local function next_comment_id(meta)
  return "c" .. (max_id(meta.comments or {}, "c") + 1)
end

local function next_suggestion_id(meta)
  return "s" .. (max_id(meta.suggestions or {}, "s") + 1)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local MARKERS = { "**", "__", "~~", "*", "_", "`" }

local function trim_formatting(anchor, sc, ec)
  local changed = true
  while changed do
    changed = false
    for _, m in ipairs(MARKERS) do
      local len = #m
      if anchor:sub(1, len) == m and anchor:sub(-len) ~= m then
        anchor = anchor:sub(len + 1); sc = sc + len; changed = true
      elseif anchor:sub(-len) == m and anchor:sub(1, len) ~= m then
        anchor = anchor:sub(1, -len - 1); ec = ec - len; changed = true
      end
    end
  end
  return anchor, sc, ec
end

local function line_range(source_buf, sel)
  local lnum = sel.start_line - 1
  local line = vim.api.nvim_buf_get_lines(source_buf, lnum, lnum + 1, false)[1] or ""
  local sc = math.min(sel.start_col, sel.end_col) - 1
  local ec = math.max(sel.start_col, sel.end_col)
  if sel.start_line ~= sel.end_line then ec = #line end
  ec = math.min(ec, #line)
  return lnum, line, sc, ec
end

local function multi_line_ranges(source_buf, sel)
  local ranges = {}
  local start_line = math.min(sel.start_line, sel.end_line)
  local end_line = math.max(sel.start_line, sel.end_line)
  local first_col = sel.start_col - 1
  local last_col = sel.end_col
  if sel.start_line > sel.end_line then
    first_col = sel.end_col - 1
    last_col = sel.start_col
  end

  for lnum_1 = start_line, end_line do
    local lnum_0 = lnum_1 - 1
    local line = vim.api.nvim_buf_get_lines(source_buf, lnum_0, lnum_0 + 1, false)[1] or ""
    local line_sc, line_ec
    if lnum_1 == start_line and lnum_1 == end_line then
      line_sc = first_col
      line_ec = math.min(last_col, #line)
    elseif lnum_1 == start_line then
      line_sc = first_col
      line_ec = #line
    elseif lnum_1 == end_line then
      line_sc = 0
      line_ec = math.min(last_col, #line)
    else
      line_sc = 0
      line_ec = #line
    end
    if line_ec > line_sc then
      table.insert(ranges, { lnum_0 = lnum_0, line = line, sc = line_sc, ec = line_ec })
    end
  end
  return ranges
end

local function transform_annotation(line, id, mode)
  local ref = "{#" .. id .. "}"
  local ref_s, ref_e = line:find(ref, 1, true)
  if not ref_s then return line end

  local prefix = line:sub(1, ref_s - 1)
  local suffix = line:sub(ref_e + 1)

  local pre, anchor = prefix:match("^(.*){==(.-)==}{>>.-<<}$")
  if pre then return pre .. anchor .. suffix end

  local pre2 = prefix:match("^(.*){>>.-<<}$")
  if pre2 then return pre2 .. suffix end

  local pre3, text = prefix:match("^(.*){%+%+(.-)%+%+}$")
  if pre3 then
    return pre3 .. (mode == "approve" and text or "") .. suffix
  end

  local pre4, text2 = prefix:match("^(.*){%-%-(.-)%-%-}$")
  if pre4 then
    return pre4 .. (mode == "approve" and "" or text2) .. suffix
  end

  local pre5, old_t, new_t = prefix:match("^(.*){~~(.-)~>(.-)~~}$")
  if pre5 then
    return pre5 .. (mode == "approve" and new_t or old_t) .. suffix
  end

  local pre6, anchor2 = prefix:match("^(.*){==(.-)==}$")
  if pre6 then return pre6 .. anchor2 .. suffix end

  return line
end

local function cascade_remove_meta(meta, id)
  local to_remove = { [id] = true }
  local queue = { id }
  while #queue > 0 do
    local pid = table.remove(queue, 1)
    for cid, entry in pairs(meta.comments) do
      if entry.re == pid and not to_remove[cid] then
        to_remove[cid] = true
        table.insert(queue, cid)
      end
    end
  end
  for rid in pairs(to_remove) do meta.comments[rid] = nil end
  meta.suggestions[id] = nil
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.has_annotations(lines)
  for _, line in ipairs(lines) do
    if line:match("{#[cs]%d+}") then return true end
  end
  return util.find_endmatter_sep(lines) ~= nil
end

function M.parse(source_buf)
  if not vim.api.nvim_buf_is_valid(source_buf) then return {} end

  local tick = vim.api.nvim_buf_get_changedtick(source_buf)
  local cached = parse_cache[source_buf]
  if cached and cached.tick == tick then return cached.items end

  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local content_end = sep and (sep - 1) or #lines
  local meta = parse_endmatter(lines, sep)

  local items = {}
  local id_to_item = {}

  for lnum = 1, content_end do
    local line = lines[lnum]
    local pos = 1

    while true do
      local s, e, anchor, body, id = line:find(PAT_COMMENT, pos)
      if not s then break end
      if id_to_item[id] then
        local existing = id_to_item[id]
        if lnum > existing.end_line then existing.end_line = lnum end
      else
        local entry = (meta.comments or {})[id] or {}
        local item = {
          id = id, type = "comment", anchor = anchor, body = body,
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, text, id = line:find(PAT_ADDITION, pos)
      if not s then break end
      if id_to_item[id] then
        local existing = id_to_item[id]
        if lnum > existing.end_line then existing.end_line = lnum end
      else
        local entry = (meta.suggestions or {})[id] or {}
        local item = {
          id = id, type = "addition", text = text,
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, text, id = line:find(PAT_DELETION, pos)
      if not s then break end
      if id_to_item[id] then
        local existing = id_to_item[id]
        if lnum > existing.end_line then existing.end_line = lnum end
      else
        local entry = (meta.suggestions or {})[id] or {}
        local item = {
          id = id, type = "deletion", text = text,
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, old_text, new_text, id = line:find(PAT_REPLACEMENT, pos)
      if not s then break end
      if id_to_item[id] then
        local existing = id_to_item[id]
        if lnum > existing.end_line then existing.end_line = lnum end
        existing.type = "replacement"
        existing.old_text = old_text
        existing.new_text = new_text
      else
        local entry = (meta.suggestions or {})[id] or {}
        local item = {
          id = id, type = "replacement", old_text = old_text, new_text = new_text,
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, anchor, id = line:find("{==(.-)==}" .. REF, pos)
      if not s then break end
      if id_to_item[id] then
        local existing = id_to_item[id]
        if lnum > existing.end_line then existing.end_line = lnum end
      else
        local entry = (meta.comments or {})[id] or {}
        local item = {
          id = id, type = "comment", anchor = anchor, body = "",
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end

    pos = 1
    while true do
      local s, e, body, id = line:find("{>>(.-)<<}" .. REF, pos)
      if not s then break end
      if not id_to_item[id] then
        local entry = (meta.comments or {})[id] or {}
        local item = {
          id = id, type = "comment", anchor = nil, body = body,
          by = entry.by, at = entry.at, replies = {},
          start_line = lnum, end_line = lnum, start_col = (s - 1) + 3,
        }
        table.insert(items, item)
        id_to_item[id] = item
      end
      pos = e + 1
    end
  end

  local reply_map = {}
  for id, entry in pairs(meta.comments or {}) do
    if entry.re and entry.body then
      reply_map[entry.re] = reply_map[entry.re] or {}
      table.insert(reply_map[entry.re], {
        id = id, body = entry.body, by = entry.by, at = entry.at, re = entry.re,
      })
    end
  end

  for _, item in ipairs(items) do
    local seen = {}
    local queue = { item.id }
    while #queue > 0 do
      local pid = table.remove(queue, 1)
      for _, r in ipairs(reply_map[pid] or {}) do
        if not seen[r.id] then
          seen[r.id] = true
          table.insert(item.replies, r)
          table.insert(queue, r.id)
        end
      end
    end
    table.sort(item.replies, function(a, b) return (a.at or "") < (b.at or "") end)
  end

  parse_cache[source_buf] = { tick = tick, items = items }
  return items
end

function M.insert_comment(source_buf, sel, author, body)
  local meta = read_endmatter(source_buf)
  local id = next_comment_id(meta)

  if sel.start_line == sel.end_line then
    local lnum, line, sc, ec = line_range(source_buf, sel)
    local anchor = line:sub(sc + 1, ec)
    anchor, sc, ec = trim_formatting(anchor, sc, ec)
    local new_line = line:sub(1, sc)
      .. "{==" .. anchor .. "==}{>>" .. (body or "") .. "<<}{#" .. id .. "}"
      .. line:sub(ec + 1)
    vim.api.nvim_buf_set_lines(source_buf, lnum, lnum + 1, false, { new_line })
  else
    local ranges = multi_line_ranges(source_buf, sel)
    for i = #ranges, 1, -1 do
      local r = ranges[i]
      local anchor = r.line:sub(r.sc + 1, r.ec)
      local new_line
      if i == 1 then
        local _, adj_sc, adj_ec = trim_formatting(anchor, r.sc, r.ec)
        r.sc = adj_sc
        r.ec = adj_ec
        anchor = r.line:sub(r.sc + 1, r.ec)
        new_line = r.line:sub(1, r.sc)
          .. "{==" .. anchor .. "==}{>>" .. (body or "") .. "<<}{#" .. id .. "}"
          .. r.line:sub(r.ec + 1)
      else
        new_line = r.line:sub(1, r.sc)
          .. "{==" .. anchor .. "==}{#" .. id .. "}"
          .. r.line:sub(r.ec + 1)
      end
      vim.api.nvim_buf_set_lines(source_buf, r.lnum_0, r.lnum_0 + 1, false, { new_line })
    end
  end

  meta.comments[id] = { by = author or "", at = os.date("!%Y-%m-%dT%H:%M:%S.000Z") }
  write_endmatter(source_buf, meta)
  return id
end

function M.insert_addition(source_buf, sel, text, author)
  local meta = read_endmatter(source_buf)
  local id = next_suggestion_id(meta)
  local lnum = (sel.cursor_line or sel.end_line) - 1
  local line = vim.api.nvim_buf_get_lines(source_buf, lnum, lnum + 1, false)[1] or ""
  local sc = (sel.cursor_col or sel.end_col) - 1
  local new_line = line:sub(1, sc) .. "{++" .. text .. "++}{#" .. id .. "}" .. line:sub(sc + 1)
  vim.api.nvim_buf_set_lines(source_buf, lnum, lnum + 1, false, { new_line })
  meta.suggestions[id] = { by = author or "", at = os.date("!%Y-%m-%dT%H:%M:%S.000Z") }
  write_endmatter(source_buf, meta)
  return id
end

function M.insert_deletion(source_buf, sel, author)
  local meta = read_endmatter(source_buf)
  local id = next_suggestion_id(meta)

  if sel.start_line == sel.end_line then
    local lnum, line, sc, ec = line_range(source_buf, sel)
    local text = line:sub(sc + 1, ec)
    local new_line = line:sub(1, sc)
      .. "{--" .. text .. "--}{#" .. id .. "}" .. line:sub(ec + 1)
    vim.api.nvim_buf_set_lines(source_buf, lnum, lnum + 1, false, { new_line })
  else
    local ranges = multi_line_ranges(source_buf, sel)
    for i = #ranges, 1, -1 do
      local r = ranges[i]
      local text = r.line:sub(r.sc + 1, r.ec)
      local new_line = r.line:sub(1, r.sc)
        .. "{--" .. text .. "--}{#" .. id .. "}" .. r.line:sub(r.ec + 1)
      vim.api.nvim_buf_set_lines(source_buf, r.lnum_0, r.lnum_0 + 1, false, { new_line })
    end
  end

  meta.suggestions[id] = { by = author or "", at = os.date("!%Y-%m-%dT%H:%M:%S.000Z") }
  write_endmatter(source_buf, meta)
  return id
end

function M.insert_replacement(source_buf, sel, new_text, author)
  local meta = read_endmatter(source_buf)
  local id = next_suggestion_id(meta)

  if sel.start_line == sel.end_line then
    local lnum, line, sc, ec = line_range(source_buf, sel)
    local old_text = line:sub(sc + 1, ec)
    local new_line = line:sub(1, sc)
      .. "{~~" .. old_text .. "~>" .. new_text .. "~~}{#" .. id .. "}" .. line:sub(ec + 1)
    vim.api.nvim_buf_set_lines(source_buf, lnum, lnum + 1, false, { new_line })
  else
    local ranges = multi_line_ranges(source_buf, sel)
    for i = #ranges, 1, -1 do
      local r = ranges[i]
      local old_text = r.line:sub(r.sc + 1, r.ec)
      local new_line
      if i == #ranges then
        new_line = r.line:sub(1, r.sc)
          .. "{~~" .. old_text .. "~>" .. new_text .. "~~}{#" .. id .. "}"
          .. r.line:sub(r.ec + 1)
      else
        new_line = r.line:sub(1, r.sc)
          .. "{--" .. old_text .. "--}{#" .. id .. "}"
          .. r.line:sub(r.ec + 1)
      end
      vim.api.nvim_buf_set_lines(source_buf, r.lnum_0, r.lnum_0 + 1, false, { new_line })
    end
  end

  meta.suggestions[id] = { by = author or "", at = os.date("!%Y-%m-%dT%H:%M:%S.000Z") }
  write_endmatter(source_buf, meta)
  return id
end

function M.update_comment_body(source_buf, id, new_body)
  if not vim.api.nvim_buf_is_valid(source_buf) then return false end
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local content_end = sep and (sep - 1) or #lines
  local ref = "{#" .. id .. "}"

  for lnum = 1, content_end do
    local line = lines[lnum]
    local ref_s, ref_e = line:find(ref, 1, true)
    if ref_s then
      local prefix = line:sub(1, ref_s - 1)
      local suffix = line:sub(ref_e + 1)
      local pre, old_body = prefix:match("^(.-){>>(.-)<<}$")
      if pre then
        if old_body ~= new_body then
          local new_line = pre .. "{>>" .. new_body .. "<<}" .. ref .. suffix
          vim.api.nvim_buf_set_lines(source_buf, lnum - 1, lnum, false, { new_line })
          return true
        end
        return false
      end
    end
  end
  return false
end

function M.update_reply_body(source_buf, id, new_body)
  if not vim.api.nvim_buf_is_valid(source_buf) then return false end
  local meta = read_endmatter(source_buf)
  local entry = (meta.comments or {})[id]
  if not entry or not entry.re then return false end
  if entry.body == new_body then return false end
  entry.body = new_body
  write_endmatter(source_buf, meta)
  return true
end

function M.add_reply(source_buf, parent_id, body, author)
  local meta = read_endmatter(source_buf)
  local id = next_comment_id(meta)
  meta.comments[id] = {
    body = body,
    by = author or "",
    at = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
    re = parent_id,
  }
  write_endmatter(source_buf, meta)
  return id
end

function M.approve(source_buf, id)
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local content_end = sep and (sep - 1) or #lines
  local meta = parse_endmatter(lines, sep)
  local ref = "{#" .. id .. "}"

  local changed = false
  for lnum = content_end, 1, -1 do
    if lines[lnum]:find(ref, 1, true) then
      local new_line = transform_annotation(lines[lnum], id, "approve")
      if new_line ~= lines[lnum] then
        vim.api.nvim_buf_set_lines(source_buf, lnum - 1, lnum, false, { new_line })
        changed = true
      end
    end
  end
  if changed then
    cascade_remove_meta(meta, id)
    write_endmatter(source_buf, meta)
  end
  return changed
end

function M.reject(source_buf, id)
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local sep = util.find_endmatter_sep(lines)
  local content_end = sep and (sep - 1) or #lines
  local meta = parse_endmatter(lines, sep)
  local ref = "{#" .. id .. "}"

  local changed = false
  for lnum = content_end, 1, -1 do
    if lines[lnum]:find(ref, 1, true) then
      local new_line = transform_annotation(lines[lnum], id, "reject")
      if new_line ~= lines[lnum] then
        vim.api.nvim_buf_set_lines(source_buf, lnum - 1, lnum, false, { new_line })
        changed = true
      end
    end
  end
  if changed then
    cascade_remove_meta(meta, id)
    write_endmatter(source_buf, meta)
  end
  return changed
end

function M.delete_reply(source_buf, reply_id)
  if not vim.api.nvim_buf_is_valid(source_buf) then return false end
  local meta = read_endmatter(source_buf)
  if not (meta.comments or {})[reply_id] then return false end
  cascade_remove_meta(meta, reply_id)
  write_endmatter(source_buf, meta)
  return true
end

return M
