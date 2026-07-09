local M = {}

function M.check()
  local health = vim.health

  health.start("inline-review.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end

  if vim.g.inline_review_setup_done then
    health.ok("setup() has run")
  else
    health.warn("setup() has not run yet",
      { "It runs automatically on VimEnter, or call require('inline_review').setup()" })
  end

  local cfg = require("inline_review").config
  health.info(("width: %d, author: %s, animate: %s")
    :format(cfg.width, cfg.author, tostring(cfg.animate)))
end

return M
