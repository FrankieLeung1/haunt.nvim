---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.navigation", function()
	local navigation
	local store
	local bufnr, test_file

	before_each(function()
		helpers.reset_modules()
		store = require("haunt.store")
		store._reset_for_testing()
		navigation = require("haunt.navigation")
	end)

	after_each(function()
		helpers.cleanup_buffer(bufnr, test_file)
	end)

	describe("next", function()
		before_each(function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })

			-- Add bookmarks at lines 1, 3, 5
			store.add_bookmark({ file = test_file, line = 1, id = "b1" })
			store.add_bookmark({ file = test_file, line = 3, id = "b3" })
			store.add_bookmark({ file = test_file, line = 5, id = "b5" })
		end)

		it("jumps to next bookmark from line 1", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("jumps to next bookmark from line 3", function()
			vim.api.nvim_win_set_cursor(0, { 3, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(5, pos[1])
		end)

		it("wraps around from last bookmark to first", function()
			vim.api.nvim_win_set_cursor(0, { 5, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(1, pos[1])
		end)

		it("jumps to next bookmark when cursor between bookmarks", function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("jumps to next bookmark from line before first", function()
			-- Add bookmark only at line 3
			store._reset_for_testing()
			store.add_bookmark({ file = test_file, line = 3, id = "b3" })

			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("preserves column position", function()
			vim.api.nvim_win_set_cursor(0, { 1, 3 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
			assert.are.equal(3, pos[2])
		end)
	end)

	describe("prev", function()
		before_each(function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })

			-- Add bookmarks at lines 1, 3, 5
			store.add_bookmark({ file = test_file, line = 1, id = "b1" })
			store.add_bookmark({ file = test_file, line = 3, id = "b3" })
			store.add_bookmark({ file = test_file, line = 5, id = "b5" })
		end)

		it("jumps to previous bookmark from line 5", function()
			vim.api.nvim_win_set_cursor(0, { 5, 0 })

			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("jumps to previous bookmark from line 3", function()
			vim.api.nvim_win_set_cursor(0, { 3, 0 })

			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(1, pos[1])
		end)

		it("wraps around from first bookmark to last", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(5, pos[1])
		end)

		it("jumps to previous bookmark when cursor between bookmarks", function()
			vim.api.nvim_win_set_cursor(0, { 4, 0 })

			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("preserves column position", function()
			vim.api.nvim_win_set_cursor(0, { 5, 2 })

			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
			assert.are.equal(2, pos[2])
		end)
	end)

	describe("edge cases", function()
		it("returns false when no bookmarks in buffer", function()
			bufnr, test_file = helpers.create_test_buffer()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			local result = navigation.next()

			assert.is_false(result)
		end)

		it("handles single bookmark", function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3" })
			store.add_bookmark({ file = test_file, line = 2, id = "only" })

			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			local result = navigation.next()

			assert.is_true(result)
			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(2, pos[1])
		end)

		it("single bookmark wraps to itself", function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3" })
			store.add_bookmark({ file = test_file, line = 2, id = "only" })

			vim.api.nvim_win_set_cursor(0, { 2, 0 })

			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(2, pos[1])
		end)

		it("handles unnamed buffer", function()
			local unnamed_bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_set_current_buf(unnamed_bufnr)

			local result = navigation.next()

			assert.is_false(result)
			vim.api.nvim_buf_delete(unnamed_bufnr, { force = true })
		end)

		it("only navigates bookmarks in current file", function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3" })

			-- Add bookmark in current file
			store.add_bookmark({ file = test_file, line = 1, id = "current" })
			-- Add bookmark in different file
			store.add_bookmark({ file = "/other/file.lua", line = 2, id = "other" })

			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			navigation.next()

			-- Should wrap to itself since only one bookmark in current file
			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(1, pos[1])
		end)

		it("sets jump mark before navigating", function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })
			store.add_bookmark({ file = test_file, line = 1, id = "b1" })
			store.add_bookmark({ file = test_file, line = 5, id = "b5" })

			vim.api.nvim_win_set_cursor(0, { 3, 0 })

			navigation.next()

			-- Verify we can jump back with Ctrl-O
			local pos_after = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(5, pos_after[1])
		end)
	end)

	describe("bookmarks added out of order", function()
		it("navigates in sorted order regardless of add order", function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })

			-- Add bookmarks out of order
			store.add_bookmark({ file = test_file, line = 5, id = "b5" })
			store.add_bookmark({ file = test_file, line = 1, id = "b1" })
			store.add_bookmark({ file = test_file, line = 3, id = "b3" })

			vim.api.nvim_win_set_cursor(0, { 1, 0 })

			navigation.next()
			local pos1 = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos1[1])

			navigation.next()
			local pos2 = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(5, pos2[1])

			navigation.next()
			local pos3 = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(1, pos3[1])
		end)
	end)

	-- Regression: same stale-line family as #92/#99, on the navigation path.
	-- get_sorted_bookmarks_for_file returned the file index without syncing
	-- lines from extmarks, so `[h` / `]h` picked neighbours using the
	-- on-create line instead of where the bookmark had moved to.
	describe("navigation follows extmarks after edits", function()
		local api

		before_each(function()
			local modules = helpers.setup_haunt()
			api = modules.api
			store = modules.store
			navigation = modules.navigation

			bufnr, test_file = helpers.create_test_buffer({
				"line 1",
				"line 2",
				"line 3",
				"line 4",
				"line 5",
				"line 6",
			})

			-- Bookmarks at lines 2 and 5, created through the real annotate
			-- path so they carry tracking extmarks.
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			api.annotate("first")
			vim.api.nvim_win_set_cursor(0, { 5, 0 })
			api.annotate("second")
		end)

		it("jumps to the moved line, not the on-create line", function()
			-- Push both bookmarks down by 3: extmarks now at lines 5 and 8.
			vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new 1", "new 2", "new 3" })

			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(5, pos[1], "should jump to the first bookmark's current line, not its stale line 2")
		end)

		it("does not wrap early using stale lines", function()
			vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new 1", "new 2", "new 3" })

			-- Cursor sits between the two current positions (5 and 8). With
			-- stale lines (2 and 5) nothing is past the cursor, so navigation
			-- wrapped around to the first bookmark instead of advancing.
			vim.api.nvim_win_set_cursor(0, { 6, 0 })
			navigation.next()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(8, pos[1], "should advance to the second bookmark rather than wrapping")
		end)

		it("prev uses moved lines too", function()
			vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new 1", "new 2", "new 3" })

			-- Cursor above both current positions (5 and 8), so prev must wrap
			-- to the last bookmark. With stale lines (2 and 5) it instead found
			-- a "previous" bookmark at line 2 and jumped backwards.
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			navigation.prev()

			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(8, pos[1], "should wrap to the last bookmark's current line")
		end)

		it("returns bookmarks sorted by current line", function()
			vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new 1", "new 2", "new 3" })

			local filepath = require("haunt.utils").normalize_filepath(test_file)
			local sorted = store.get_sorted_bookmarks_for_file(filepath)

			assert.are.equal(2, #sorted)
			assert.are.equal(5, sorted[1].line)
			assert.are.equal(8, sorted[2].line)
		end)
	end)
end)
