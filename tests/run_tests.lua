-- Test suite for inline-review.nvim. Run from the repo root with:
--   nvim -l tests/run_tests.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

local storage = require("inline_review.storage")
local util    = require("inline_review.util")

local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(string.format("%s\n     want: %s\n     got:  %s",
      msg or "not equal", vim.inspect(want), vim.inspect(got)), 2)
  end
end

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local AT = "2026-01-01T00:00:00.000Z"

---------------------------------------------------------------------------
-- Endmatter separator detection
---------------------------------------------------------------------------

test("find_endmatter_sep: valid block", function()
  eq(util.find_endmatter_sep({ "a", "", "---", "comments:" }), 3)
  eq(util.find_endmatter_sep({ "a", "", "---", "suggestions:" }), 3)
end)

test("find_endmatter_sep: rejects non-metadata blocks", function()
  eq(util.find_endmatter_sep({ "a", "", "---", "notmeta: x" }), nil)
  eq(util.find_endmatter_sep({ "a", "", "---", "", "text after rule" }), nil)
  eq(util.find_endmatter_sep({ "a", "---", "comments:" }), nil)
end)

test("has_annotations", function()
  eq(storage.has_annotations({ "plain text" }), false)
  eq(storage.has_annotations({ "x {==a==}{>>b<<}{#c1} y" }), true)
  eq(storage.has_annotations({ "a", "", "---", "comments:" }), true)
end)

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

test("parse: all annotation types with metadata", function()
  local buf = make_buf({
    "a {==anchor==}{>>note<<}{#c1} b",
    "c {++added++}{#s1} d",
    "e {--removed--}{#s2} f",
    "g {~~old~>new~~}{#s3} h",
    "",
    "---",
    "comments:",
    "  c1:",
    "    by: alice",
    "    at: " .. AT,
    "suggestions:",
    "  s1:",
    "    by: alice",
    "    at: " .. AT,
    "  s2:",
    "    by: alice",
    "    at: " .. AT,
    "  s3:",
    "    by: alice",
    "    at: " .. AT,
  })
  local items = storage.parse(buf)
  eq(#items, 4)
  eq(items[1].type, "comment")
  eq(items[1].anchor, "anchor")
  eq(items[1].body, "note")
  eq(items[1].by, "alice")
  eq(items[2].type, "addition")
  eq(items[2].text, "added")
  eq(items[3].type, "deletion")
  eq(items[4].type, "replacement")
  eq(items[4].old_text, "old")
  eq(items[4].new_text, "new")
end)

---------------------------------------------------------------------------
-- YAML round-trips
---------------------------------------------------------------------------

test("yaml: quoted values with quotes and backslashes round-trip", function()
  local buf = make_buf({
    "x {==a==}{>>note<<}{#c1} y",
    "",
    "---",
    "comments:",
    "  c1:",
    "    by: t",
    "    at: " .. AT,
  })
  local body = [[say "hi" and \ done]]
  storage.add_reply(buf, "c1", body, "t")
  local items = storage.parse(buf)
  eq(#items[1].replies, 1)
  eq(items[1].replies[1].body, body)

  -- A second rewrite must not double the escapes. Both replies share a
  -- timestamp so their order is unspecified; compare the sorted bodies.
  storage.add_reply(buf, "c1", "another", "t")
  items = storage.parse(buf)
  local bodies = {}
  for _, r in ipairs(items[1].replies) do table.insert(bodies, r.body) end
  table.sort(bodies)
  eq(bodies, { "another", body })
end)

test("yaml: multi-line reply body round-trips via block scalar", function()
  local buf = make_buf({
    "x {==a==}{>>note<<}{#c1} y",
    "",
    "---",
    "comments:",
    "  c1:",
    "    by: t",
    "    at: " .. AT,
  })
  storage.add_reply(buf, "c1", "line one\nline two", "t")
  local items = storage.parse(buf)
  eq(items[1].replies[1].body, "line one\nline two")
end)

---------------------------------------------------------------------------
-- Comment insertion and editing
---------------------------------------------------------------------------

test("insert_comment: single-line body stays inline", function()
  local buf = make_buf({ "alpha beta gamma" })
  local sel = { start_line = 1, end_line = 1, start_col = 1, end_col = 5 }
  storage.insert_comment(buf, sel, "t", "a note")
  eq(buf_lines(buf)[1], "{==alpha==}{>>a note<<}{#c1} beta gamma")
end)

test("insert_comment: multi-line body goes to endmatter", function()
  local buf = make_buf({ "alpha beta gamma" })
  local sel = { start_line = 1, end_line = 1, start_col = 1, end_col = 5 }
  storage.insert_comment(buf, sel, "t", "line one\nline two")
  eq(buf_lines(buf)[1], "{==alpha==}{#c1} beta gamma")
  local items = storage.parse(buf)
  eq(items[1].body, "line one\nline two")
  eq(items[1].by, "t")
end)

test("update_comment_body: multi-line edit moves body to endmatter", function()
  local buf = make_buf({ "alpha beta gamma" })
  local sel = { start_line = 1, end_line = 1, start_col = 1, end_col = 5 }
  storage.insert_comment(buf, sel, "t", "short")

  eq(storage.update_comment_body(buf, "c1", "one\ntwo"), true)
  eq(buf_lines(buf)[1], "{==alpha==}{#c1} beta gamma")
  eq(storage.parse(buf)[1].body, "one\ntwo")

  -- Editing a body that lives in the endmatter updates it there.
  eq(storage.update_comment_body(buf, "c1", "three"), true)
  eq(storage.parse(buf)[1].body, "three")

  -- No-op edit reports no change.
  eq(storage.update_comment_body(buf, "c1", "three"), false)
end)

---------------------------------------------------------------------------
-- Inline text sanitizing
---------------------------------------------------------------------------

test("insert_addition: newlines are joined with spaces", function()
  local buf = make_buf({ "hello world" })
  local sel = { start_line = 1, end_line = 1, start_col = 1, end_col = 5,
                cursor_line = 1, cursor_col = 6 }
  storage.insert_addition(buf, sel, "x\ny", "t")
  assert(buf_lines(buf)[1]:find("{++x y++}", 1, true), "sanitized addition not found")
end)

test("insert_replacement: newlines are joined with spaces", function()
  local buf = make_buf({ "hello world" })
  local sel = { start_line = 1, end_line = 1, start_col = 1, end_col = 5 }
  storage.insert_replacement(buf, sel, "x\ny", "t")
  assert(buf_lines(buf)[1]:find("{~~hello~>x y~~}", 1, true), "sanitized replacement not found")
end)

---------------------------------------------------------------------------
-- Multibyte selections
---------------------------------------------------------------------------

test("capture_visual_selection: extends end_col over multibyte characters", function()
  local line = "Here is \xe2\x80\x9cquoted\xe2\x80\x9d text."
  local buf = make_buf({ line })
  vim.api.nvim_set_current_buf(buf)

  local close_s = line:find("\xe2\x80\x9d", 1, true)
  vim.fn.setpos("'<", { 0, 1, 6, 0 })          -- on "is"
  vim.fn.setpos("'>", { 0, 1, close_s, 0 })    -- first byte of the closing quote

  local sel = util.capture_visual_selection()
  eq(sel.end_col, close_s + 2, "end_col should cover all 3 bytes of the quote")

  storage.insert_deletion(buf, sel, "t")
  eq(buf_lines(buf)[1],
    "Here {--is \xe2\x80\x9cquoted\xe2\x80\x9d--}{#s1} text.")
  eq(storage.parse(buf)[1].text, "is \xe2\x80\x9cquoted\xe2\x80\x9d")
end)

---------------------------------------------------------------------------
-- Approve / reject
---------------------------------------------------------------------------

local function deletion_fixture(content)
  local lines = vim.list_extend({}, content)
  vim.list_extend(lines, {
    "",
    "---",
    "suggestions:",
    "  s1:",
    "    by: t",
    "    at: " .. AT,
  })
  return make_buf(lines)
end

test("approve: full-line multi-line deletion removes the lines", function()
  local buf = deletion_fixture({
    "{--line one--}{#s1}",
    "{--line two--}{#s1}",
    "keep me",
  })
  eq(storage.approve(buf, "s1"), true)
  eq(buf_lines(buf), { "keep me" })
end)

test("approve: partial-line deletion keeps the line", function()
  local buf = deletion_fixture({ "foo {--bar --}{#s1}baz" })
  storage.approve(buf, "s1")
  eq(buf_lines(buf), { "foo baz" })
end)

test("reject: deletion restores the text", function()
  local buf = deletion_fixture({ "a {--gone--}{#s1} b" })
  storage.reject(buf, "s1")
  eq(buf_lines(buf), { "a gone b" })
end)

test("approve/reject: replacement", function()
  local buf = deletion_fixture({ "foo {~~old~>new~~}{#s1} bar" })
  storage.approve(buf, "s1")
  eq(buf_lines(buf), { "foo new bar" })

  local buf2 = deletion_fixture({ "foo {~~old~>new~~}{#s1} bar" })
  storage.reject(buf2, "s1")
  eq(buf_lines(buf2), { "foo old bar" })
end)

test("reject: comment removes markup and cascades replies", function()
  local buf = make_buf({
    "x {==a==}{>>note<<}{#c1} y",
    "",
    "---",
    "comments:",
    "  c1:",
    "    by: t",
    "    at: " .. AT,
    "  c2:",
    "    body: reply",
    "    by: t",
    "    at: " .. AT,
    "    re: c1",
    "  c3:",
    "    body: nested",
    "    by: t",
    "    at: " .. AT,
    "    re: c2",
  })
  storage.reject(buf, "c1")
  eq(buf_lines(buf), { "x a y" })
end)

---------------------------------------------------------------------------
-- Input float
---------------------------------------------------------------------------

test("input float: <C-j> inserts a newline instead of submitting", function()
  local window = require("inline_review.window")
  local path = vim.fn.tempname() .. ".md"
  local fh = assert(io.open(path, "w"))
  fh:write("alpha beta gamma\n")
  fh:close()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local src = vim.api.nvim_get_current_buf()

  window.add_suggestion("comment",
    { start_line = 1, end_line = 1, start_col = 1, end_col = 5 },
    { author = "t" })

  -- Type two lines separated by <C-j>, submit with <CR>. "m" applies the
  -- float's buffer-local mappings, "x" executes synchronously (headless).
  local keys = vim.api.nvim_replace_termcodes("aone<C-j>two<CR>", true, false, true)
  vim.api.nvim_feedkeys(keys, "mx", false)
  vim.cmd("stopinsert")
  vim.wait(300, function() return false end)

  local items = storage.parse(src)
  eq(#items, 1, "expected one annotation")
  eq(items[1].body, "one\ntwo")
  window.close()
end)

---------------------------------------------------------------------------

if failed > 0 then
  print(string.format("\n%d test(s) failed", failed))
  os.exit(1)
end
print("\nall tests passed")
