---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.adaptation", function()
	local adaptation
	local store
	local display
	local restoration
	local bufnr, test_file

	before_each(function()
		helpers.reset_modules()

		local config = require("haunt.config")
		config.setup()

		store = require("haunt.store")
		store._reset_for_testing()

		display = require("haunt.display")
		restoration = require("haunt.restoration")
		adaptation = require("haunt.adaptation")
	end)

	after_each(function()
		helpers.cleanup_buffer(bufnr, test_file)
	end)

	describe("levenshtein and similarity", function()
		it("calculates exact match distance and similarity", function()
			assert.are.equal(0, adaptation.levenshtein("hello", "hello"))
			assert.are.equal(1.0, adaptation.similarity("hello", "hello"))
		end)

		it("handles empty strings", function()
			assert.are.equal(5, adaptation.levenshtein("", "hello"))
			assert.are.equal(5, adaptation.levenshtein("hello", ""))
			assert.are.equal(0, adaptation.levenshtein("", ""))
			assert.are.equal(1.0, adaptation.similarity("", ""))
			assert.are.equal(0.0, adaptation.similarity("hello", ""))
		end)

		it("calculates single-character insertions, deletions, substitutions", function()
			-- Substitution
			assert.are.equal(1, adaptation.levenshtein("cat", "hat"))
			-- Insertion
			assert.are.equal(1, adaptation.levenshtein("cat", "cats"))
			-- Deletion
			assert.are.equal(1, adaptation.levenshtein("cats", "cat"))
		end)

		it("recognizes trimmed whitespace / indentation changes as high similarity", function()
			local sim = adaptation.similarity("  local x = 1", "      local x = 1")
			assert.are.equal(0.98, sim)
		end)

		it("calculates similarity ratio for partially changed lines", function()
			local s1 = "function calculate_total(items, tax_rate)"
			local s2 = "function calculate_total(items, tax_rate, discount)"
			local sim = adaptation.similarity(s1, s2)
			-- Added 10 characters out of ~51 max_len -> similarity around ~0.80
			assert.is_true(sim > 0.75)
			assert.is_true(sim < 1.0)
		end)
	end)

	describe("find_relocated_line", function()
		it("returns same line when content matches exactly at bookmark.line", function()
			local lines = {
				"line 1",
				"function test()",
				"line 3",
			}
			local bm = { file = "/test.lua", line = 2, id = "bm1", content = "function test()" }
			local new_line, matched_content, score = adaptation.find_relocated_line(lines, bm)

			assert.are.equal(2, new_line)
			assert.are.equal("function test()", matched_content)
			assert.are.equal(1.0, score)
		end)

		it("finds new line when lines were added above outside Neovim", function()
			-- Originally line 2, but 3 lines added above outside Neovim
			local lines = {
				"-- new header line 1",
				"-- new header line 2",
				"-- new header line 3",
				"line 1",
				"function test()", -- now at line 5
				"line 3",
			}
			local bm = { file = "/test.lua", line = 2, id = "bm1", content = "function test()" }
			local new_line, matched_content, score = adaptation.find_relocated_line(lines, bm)

			assert.are.equal(5, new_line)
			assert.are.equal("function test()", matched_content)
			assert.are.equal(1.0, score)
		end)

		it("finds new line when lines were removed above outside Neovim", function()
			-- Originally line 5, but lines above were removed so it is now at line 2
			local lines = {
				"header",
				"function test()", -- now at line 2
				"footer",
			}
			local bm = { file = "/test.lua", line = 5, id = "bm1", content = "function test()" }
			local new_line, matched_content, score = adaptation.find_relocated_line(lines, bm)

			assert.are.equal(2, new_line)
			assert.are.equal("function test()", matched_content)
			assert.are.equal(1.0, score)
		end)

		it("finds line when content has percentage of contents changed (fuzzy match)", function()
			-- Signature changed slightly outside Neovim at same line
			local lines = {
				"local a = 1",
				"function greet(name, greeting, punct)", -- changed from "function greet(name, greeting)"
				"local b = 2",
			}
			local bm = {
				file = "/test.lua",
				line = 2,
				id = "bm1",
				content = "function greet(name, greeting)",
			}
			local new_line, matched_content, score = adaptation.find_relocated_line(lines, bm, { threshold = 0.6 })

			assert.are.equal(2, new_line)
			assert.are.equal("function greet(name, greeting, punct)", matched_content)
			assert.is_true(score >= 0.6)
		end)

		it("finds line when lines were added above AND content was partially changed", function()
			-- Lines added above, and signature modified
			local lines = {
				"-- comment A",
				"-- comment B",
				"-- comment C",
				"local a = 1",
				"function greet(name, greeting, punct)", -- relocated to line 5 with edits
				"local b = 2",
			}
			local bm = {
				file = "/test.lua",
				line = 2,
				id = "bm1",
				content = "function greet(name, greeting)",
			}
			local new_line, matched_content, score = adaptation.find_relocated_line(lines, bm, { threshold = 0.6 })

			assert.are.equal(5, new_line)
			assert.are.equal("function greet(name, greeting, punct)", matched_content)
			assert.is_true(score >= 0.6)
		end)

		it("finds line with indentation changes", function()
			local lines = {
				"function wrapper()",
				"        return calculate_sum(a, b)", -- indented with 8 spaces instead of 4
				"end",
			}
			local bm = {
				file = "/test.lua",
				line = 2,
				id = "bm1",
				content = "    return calculate_sum(a, b)",
			}
			local new_line, matched_content = adaptation.find_relocated_line(lines, bm)

			assert.are.equal(2, new_line)
			assert.are.equal("        return calculate_sum(a, b)", matched_content)
		end)

		it("returns nil when line content has changed too drastically beyond threshold", function()
			local lines = {
				"function completely_unrelated_code()",
				"    local totally_different = 999",
				"end",
			}
			local bm = {
				file = "/test.lua",
				line = 2,
				id = "bm1",
				content = "function greet(name, greeting)",
			}
			local new_line = adaptation.find_relocated_line(lines, bm, { threshold = 0.7 })

			assert.is_nil(new_line)
		end)

		it("does not select lines that are already claimed by another bookmark", function()
			local lines = {
				"return true", -- line 1
				"other code",  -- line 2
				"return true", -- line 3
			}
			local bm = { file = "/test.lua", line = 1, id = "bm2", content = "return true" }
			-- If line 1 is already claimed by bm1, bm should pick line 3
			local new_line = adaptation.find_relocated_line(lines, bm, { claimed_lines = { [1] = true } })

			assert.are.equal(3, new_line)
		end)
	end)

	describe("adapt_bookmarks_for_lines", function()
		it("adapts multiple bookmarks shifted by inserted lines", function()
			local lines = {
				"-- inserted 1",
				"-- inserted 2",
				"first bookmark target",  -- now line 3 (was 1)
				"second bookmark target", -- now line 4 (was 2)
				"third bookmark target",  -- now line 5 (was 3)
			}
			local bookmarks = {
				{ file = "/test.lua", line = 1, id = "b1", content = "first bookmark target" },
				{ file = "/test.lua", line = 2, id = "b2", content = "second bookmark target" },
				{ file = "/test.lua", line = 3, id = "b3", content = "third bookmark target" },
			}

			local count, changes = adaptation.adapt_bookmarks_for_lines(lines, bookmarks)

			assert.are.equal(3, count)
			assert.are.equal(3, #changes)
			assert.are.equal(3, bookmarks[1].line)
			assert.are.equal(4, bookmarks[2].line)
			assert.are.equal(5, bookmarks[3].line)
		end)
	end)

	describe("buffer restoration integration", function()
		it("automatically relocates bookmarks when buffer is restored after external edit", function()
			bufnr, test_file = helpers.create_test_buffer({
				"-- inserted comment outside neovim 1",
				"-- inserted comment outside neovim 2",
				"target function()", -- was line 1, now line 3
				"end",
			})

			-- Bookmark stored with old line 1
			store.add_bookmark({
				file = test_file,
				line = 1,
				id = "adapted_bm",
				content = "target function()",
				note = "Important note",
			})

			local success = restoration.restore_buffer_bookmarks(bufnr, true)
			assert.is_true(success)

			local bm = store.find_by_id("adapted_bm")
			assert.is_not_nil(bm)
			assert.are.equal(3, bm.line)
			assert.are.equal("target function()", bm.content)

			-- Verify extmark and sign are placed on line 3
			local cur_line = display.get_extmark_line(bufnr, bm.extmark_id)
			assert.are.equal(3, cur_line)
		end)

		it("relocates bookmark when lines were removed and content partially changed", function()
			bufnr, test_file = helpers.create_test_buffer({
				"target_function(arg1, arg2, new_arg)", -- was line 4 with (arg1, arg2), now line 1
				"end",
			})

			store.add_bookmark({
				file = test_file,
				line = 4,
				id = "fuzzy_adapted_bm",
				content = "target_function(arg1, arg2)",
				note = "Fuzzy note",
			})

			local success = restoration.restore_buffer_bookmarks(bufnr, true)
			assert.is_true(success)

			local bm = store.find_by_id("fuzzy_adapted_bm")
			assert.is_not_nil(bm)
			assert.are.equal(1, bm.line)
			assert.are.equal("target_function(arg1, arg2, new_arg)", bm.content)

			local cur_line = display.get_extmark_line(bufnr, bm.extmark_id)
			assert.are.equal(1, cur_line)
		end)

		it("skips adaptation when config.adapt_to_file_changes is false", function()
			local config = require("haunt.config")
			config.setup({ adapt_to_file_changes = false })

			bufnr, test_file = helpers.create_test_buffer({
				"-- inserted comment 1",
				"-- inserted comment 2",
				"target function()",
			})

			store.add_bookmark({
				file = test_file,
				line = 1,
				id = "disabled_adapt_bm",
				content = "target function()",
			})

			restoration.restore_buffer_bookmarks(bufnr, true)

			local bm = store.find_by_id("disabled_adapt_bm")
			assert.is_not_nil(bm)
			-- Still line 1 because adaptation was disabled
			assert.are.equal(1, bm.line)
		end)

		it("api.adapt explicitly adapts current buffer and returns change count", function()
			local api = require("haunt.api")
			bufnr, test_file = helpers.create_test_buffer({
				"-- new header line",
				"my target code()", -- now line 2
			})

			store.add_bookmark({
				file = test_file,
				line = 1,
				id = "api_adapt_bm",
				content = "my target code()",
			})

			local count, changes = api.adapt(bufnr)
			assert.are.equal(1, count)
			assert.are.equal(1, #changes)
			assert.are.equal(1, changes[1].old_line)
			assert.are.equal(2, changes[1].new_line)

			local bm = store.find_by_id("api_adapt_bm")
			assert.are.equal(2, bm.line)
		end)

		it("automatically re-adapts when an already restored buffer reloads new file content", function()
			bufnr, test_file = helpers.create_test_buffer({
				"target function()", -- line 1
				"end",
			})

			store.add_bookmark({
				file = test_file,
				line = 1,
				id = "reload_adapt_bm",
				content = "target function()",
			})

			-- First restoration
			restoration.restore_buffer_bookmarks(bufnr, true)
			assert.are.equal(1, store.find_by_id("reload_adapt_bm").line)

			-- Simulate external edit modifying lines in buffer (e.g. reload from disk)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
				"-- inserted line 1",
				"-- inserted line 2",
				"target function()", -- now line 3
				"end",
			})

			-- Restoration called automatically on buffer reload / enter
			restoration.restore_buffer_bookmarks(bufnr, true)

			local bm = store.find_by_id("reload_adapt_bm")
			assert.are.equal(3, bm.line)
			assert.are.equal(3, display.get_extmark_line(bufnr, bm.extmark_id))
		end)

		it("registers haunt_restore augroup and autocmds when haunt.setup() is called", function()
			local haunt = require("haunt")
			haunt.setup()

			local autocmds = vim.api.nvim_get_autocmds({ group = "haunt_restore" })
			assert.is_true(#autocmds > 0)

			local events = {}
			for _, ac in ipairs(autocmds) do
				events[ac.event] = true
			end
			assert.is_true(events["BufReadPost"])
			assert.is_true(events["BufEnter"])
			assert.is_true(events["FileChangedShellPost"])
		end)
	end)
end)
