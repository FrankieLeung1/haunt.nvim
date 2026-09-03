---@toc_entry Bookmark Adaptation
---@tag haunt-adaptation
---@text
--- # Bookmark Adaptation ~
---
--- Adapts bookmarks to file changes that occurred outside Neovim (e.g. git
--- pull, rebase, code formatting, or external editor modifications).
---
--- Uses saved bookmark line contents to relocate bookmarks when lines have
--- been added or removed above, and uses similarity scoring (Levenshtein
--- distance) to relocate lines whose contents have partially changed.

---@class AdaptationChange
---@field bookmark Bookmark The adapted bookmark
---@field old_line number Previous line number
---@field new_line number New line number
---@field old_content string|nil Previous line content
---@field new_content string|nil New line content
---@field similarity number Similarity score between old and new content

---@class AdaptationModule
---@field levenshtein fun(str1: string, str2: string): number
---@field similarity fun(str1: string, str2: string): number
---@field find_relocated_line fun(lines: string[], bookmark: Bookmark, opts?: { threshold?: number, claimed_lines?: table<number, boolean> }): number|nil, string|nil, number|nil
---@field adapt_bookmarks_for_lines fun(lines: string[], bookmarks: Bookmark[], opts?: { threshold?: number }): number, AdaptationChange[]
---@field adapt_buffer_bookmarks fun(bufnr: number, opts?: { threshold?: number }): number, AdaptationChange[]
---@field adapt_file_bookmarks fun(filepath: string, opts?: { threshold?: number }): number, AdaptationChange[]

---@type AdaptationModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Compute the Levenshtein edit distance between two strings.
--- Uses a space-optimized O(min(N, M)) dynamic programming approach with byte arrays.
---@param str1 string
---@param str2 string
---@return number distance
function M.levenshtein(str1, str2)
	if str1 == str2 then
		return 0
	end
	local len1, len2 = #str1, #str2
	if len1 == 0 then
		return len2
	end
	if len2 == 0 then
		return len1
	end

	-- Ensure str1 is the shorter string to optimize memory
	if len1 > len2 then
		str1, str2 = str2, str1
		len1, len2 = len2, len1
	end

	local b1 = { str1:byte(1, len1) }
	local b2 = { str2:byte(1, len2) }

	local prev = {}
	local curr = {}
	for j = 0, len2 do
		prev[j] = j
	end

	for i = 1, len1 do
		curr[0] = i
		local char1 = b1[i]
		for j = 1, len2 do
			local cost = (char1 == b2[j]) and 0 or 1
			local del_cost = prev[j] + 1
			local ins_cost = curr[j - 1] + 1
			local sub_cost = prev[j - 1] + cost

			local min = del_cost
			if ins_cost < min then
				min = ins_cost
			end
			if sub_cost < min then
				min = sub_cost
			end
			curr[j] = min
		end
		prev, curr = curr, prev
	end

	return prev[len2]
end

--- Calculate normalized similarity between two strings in the range [0.0, 1.0].
--- 1.0 = identical, 0.0 = completely different.
--- Recognizes trimmed equality (e.g. indentation changes) with high score (0.98).
---@param str1 string
---@param str2 string
---@return number similarity
function M.similarity(str1, str2)
	if str1 == str2 then
		return 1.0
	end
	local len1, len2 = #str1, #str2
	if len1 == 0 and len2 == 0 then
		return 1.0
	end
	local max_len = math.max(len1, len2)
	if max_len == 0 then
		return 1.0
	end

	-- Check trimmed equality (e.g. indentation change)
	local trim1 = vim.trim(str1)
	local trim2 = vim.trim(str2)
	if trim1 == trim2 and trim1 ~= "" then
		return 0.98
	end

	local dist = M.levenshtein(str1, str2)
	return math.max(0.0, 1.0 - (dist / max_len))
end

--- Find the relocated line for a bookmark in an array of lines.
---
--- 1. Returns current line if lines[bookmark.line] matches bookmark.content exactly.
--- 2. Searches outward from bookmark.line for the closest exact or trimmed match.
--- 3. If no exact match, searches for the best fuzzy similarity match meeting threshold.
---
---@param lines string[] The lines of the file/buffer (1-based array)
---@param bookmark Bookmark The bookmark to relocate
---@param opts? { threshold?: number, claimed_lines?: table<number, boolean> }
---@return number|nil new_line The relocated 1-based line number (or nil if no match)
---@return string|nil matched_content The content of the matched line
---@return number|nil score The similarity score (1.0 for exact match)
function M.find_relocated_line(lines, bookmark, opts)
	opts = opts or {}
	local threshold = opts.threshold or 0.6
	local claimed = opts.claimed_lines or {}
	local total_lines = #lines

	if total_lines == 0 then
		return nil, nil, nil
	end

	local target_line = bookmark.line
	local content = bookmark.content

	-- If no content stored or content is only whitespace, we cannot reliably match
	if not content or not content:match("%S") then
		local clamped = math.max(1, math.min(target_line, total_lines))
		return clamped, lines[clamped], 1.0
	end

	-- Step 1: Check if the line at target_line still matches exactly
	if target_line >= 1 and target_line <= total_lines and not claimed[target_line] then
		if lines[target_line] == content then
			return target_line, lines[target_line], 1.0
		end
	end

	-- Step 2: Search outward from target_line for closest exact match or trimmed match
	local max_offset = math.max(target_line - 1, total_lines - target_line)
	local best_trimmed_line = nil
	local best_trimmed_dist = math.huge
	local trimmed_target = vim.trim(content)

	for offset = 1, max_offset do
		local candidates = { target_line + offset, target_line - offset }
		for _, line_idx in ipairs(candidates) do
			if line_idx >= 1 and line_idx <= total_lines and not claimed[line_idx] then
				local line_str = lines[line_idx]
				if line_str == content then
					return line_idx, line_str, 1.0
				end
				if not best_trimmed_line and trimmed_target ~= "" and vim.trim(line_str) == trimmed_target then
					best_trimmed_line = line_idx
					best_trimmed_dist = offset
				end
			end
		end
	end

	-- High-confidence match: trimmed match within reasonable distance
	if best_trimmed_line and best_trimmed_dist <= 200 then
		return best_trimmed_line, lines[best_trimmed_line], 0.98
	end

	-- Step 3: Fuzzy similarity search
	-- Search for lines that have some percentage of contents changed (similarity >= threshold).
	local best_line = nil
	local best_score = -1
	local best_sim = 0
	local target_len = #content
	local max_allowed_len_diff = math.ceil(target_len * (1 - threshold)) + 2

	for i = 1, total_lines do
		if not claimed[i] then
			local line_str = lines[i]
			local len_diff = math.abs(#line_str - target_len)
			-- Quick filter: skip lines whose length difference alone guarantees similarity < threshold
			if len_diff <= max_allowed_len_diff then
				local sim = M.similarity(content, line_str)
				if sim >= threshold then
					local dist = math.abs(i - target_line)
					local dist_penalty = (dist / (total_lines + 50)) * 0.15
					local score = sim - dist_penalty

					if score > best_score then
						best_score = score
						best_line = i
						best_sim = sim
					end
				end
			end
		end
	end

	if best_line and best_sim >= threshold then
		return best_line, lines[best_line], best_sim
	end

	if best_trimmed_line then
		return best_trimmed_line, lines[best_trimmed_line], 0.98
	end

	return nil, nil, nil
end

--- Adapt a list of bookmarks for a file's lines.
--- Mutates bookmark.line and bookmark.content when a relocated line is found.
---@param lines string[] Buffer or file lines
---@param bookmarks Bookmark[] Bookmarks belonging to this file
---@param opts? { threshold?: number }
---@return number adapted_count Number of bookmarks whose line was updated
---@return AdaptationChange[] changes Array of change records
function M.adapt_bookmarks_for_lines(lines, bookmarks, opts)
	opts = opts or {}
	local claimed_lines = {}
	local adapted_count = 0
	local changes = {}

	-- Claim lines that still match their bookmarks exactly
	for _, bm in ipairs(bookmarks) do
		if bm.line >= 1 and bm.line <= #lines and bm.content and lines[bm.line] == bm.content then
			claimed_lines[bm.line] = true
		end
	end

	for _, bm in ipairs(bookmarks) do
		local old_line = bm.line
		local old_content = bm.content

		-- If already an exact match at current line, nothing to adapt
		if old_line >= 1 and old_line <= #lines and old_content and lines[old_line] == old_content then
			goto continue
		end

		local new_line, matched_content, sim = M.find_relocated_line(lines, bm, {
			threshold = opts.threshold,
			claimed_lines = claimed_lines,
		})

		if new_line and new_line ~= old_line then
			claimed_lines[new_line] = true
			bm.line = new_line
			bm.content = matched_content
			adapted_count = adapted_count + 1
			table.insert(changes, {
				bookmark = bm,
				old_line = old_line,
				new_line = new_line,
				old_content = old_content,
				new_content = matched_content,
				similarity = sim,
			})
		elseif new_line and new_line == old_line and matched_content ~= old_content then
			-- Line number didn't change, but content changed (e.g. modified in-place)
			bm.content = matched_content
			claimed_lines[new_line] = true
		elseif new_line then
			claimed_lines[new_line] = true
		end

		::continue::
	end

	return adapted_count, changes
end

--- Adapt bookmarks for a specific loaded buffer.
--- Retrieves lines from buffer and bookmarks from store, adapts them,
--- and saves store if any bookmark moved.
---@param bufnr number
---@param opts? { threshold?: number }
---@return number adapted_count
---@return AdaptationChange[] changes
function M.adapt_buffer_bookmarks(bufnr, opts)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return 0, {}
	end

	local utils = require("haunt.utils")
	local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
	if filepath == "" then
		return 0, {}
	end

	local store = require("haunt.store")
	local all_bookmarks = store.get_all_raw()
	local file_bookmarks = {}
	for _, bm in ipairs(all_bookmarks) do
		if bm.file == filepath then
			table.insert(file_bookmarks, bm)
		end
	end

	if #file_bookmarks == 0 then
		return 0, {}
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local count, changes = M.adapt_bookmarks_for_lines(lines, file_bookmarks, opts)

	if count > 0 then
		store.save()
	end

	return count, changes
end

--- Adapt bookmarks for a file path (from buffer if loaded, or disk if readable).
---@param filepath string Normalized file path
---@param opts? { threshold?: number }
---@return number adapted_count
---@return AdaptationChange[] changes
function M.adapt_file_bookmarks(filepath, opts)
	local bufnr = vim.fn.bufnr(filepath)
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
		return M.adapt_buffer_bookmarks(bufnr, opts)
	end

	if vim.fn.filereadable(filepath) ~= 1 then
		return 0, {}
	end

	local ok, lines = pcall(vim.fn.readfile, filepath)
	if not ok or not lines or #lines == 0 then
		return 0, {}
	end

	local store = require("haunt.store")
	local all_bookmarks = store.get_all_raw()
	local file_bookmarks = {}
	for _, bm in ipairs(all_bookmarks) do
		if bm.file == filepath then
			table.insert(file_bookmarks, bm)
		end
	end

	if #file_bookmarks == 0 then
		return 0, {}
	end

	local count, changes = M.adapt_bookmarks_for_lines(lines, file_bookmarks, opts)
	if count > 0 then
		store.save()
	end

	return count, changes
end

return M
