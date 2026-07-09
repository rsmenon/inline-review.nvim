local M = {}

function M.find_endmatter_sep(lines)
  for i = #lines, 1, -1 do
    if i == 1 then break end
    if lines[i]:match("^%-%-%-$") and lines[i - 1] == "" then
      for j = i + 1, #lines do
        local first = lines[j]:match("^%S.*")
        if first then
          if first == "comments:" or first == "suggestions:" then return i end
          return nil
        end
      end
      return nil
    end
  end
  return nil
end

-- Capture the last visual selection in the current buffer as 1-based byte
-- positions. getpos("'>") points at the first byte of the last character, so
-- end_col is extended to the character's last byte to avoid splitting
-- multibyte text.
function M.capture_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  local end_col = e[3]
  local line = vim.api.nvim_buf_get_lines(0, e[2] - 1, e[2], false)[1] or ""
  if end_col <= #line then
    end_col = end_col + vim.str_utf_end(line, end_col)
  end
  return { start_line = s[2], end_line = e[2], start_col = s[3], end_col = end_col }
end

return M
