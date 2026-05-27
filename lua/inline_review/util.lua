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

return M
