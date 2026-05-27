if vim.g.loaded_inline_review then return end
vim.g.loaded_inline_review = true

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if not vim.g.inline_review_setup_done then
      require("inline_review").setup()
    end
  end,
})
