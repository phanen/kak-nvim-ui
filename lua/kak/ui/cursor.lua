---
--- Per-session nvim `guicursor` swap.
---
--- The Kakoune cursor sits on the just-typed char in insert/replace
--- while nvim's block cursor would cover a character and look
--- wrong; we swap to a beam so the vertical bar marks the insertion
--- point without covering any cell. The user's original `guicursor`
--- is captured on the first insert/replace entry and restored when
--- the session leaves the kak window or closes.
---
--- Previously the captured `guicursor` lived as a module-level
--- variable inside `render.lua` -- any caller flipped the global
--- state directly. Encapsulating it on a `Cursor` object means a
--- second session can run its own swap independently. The
--- `M.apply_cursor_shape` / `M.restore_cursor_shape` module-level
--- helpers stay for backward compat (init.lua / handlers.lua call
--- them) but now share a single module-instance Cursor.
---

---@class kak.ui.cursor.Cursor
---@field _orig string? saved user guicursor, nil before first capture
local Cursor = {}
Cursor.__index = Cursor

--- BEAM in insert/replace so the cursor marks the insertion point
--- without covering a character (kakoune's terminal does the same).
--- `a:` applies to every nvim mode since the kak content buffer is
--- always in nvim normal mode; the WinLeave autocmd in `kak.ui.open`
--- restores the original so non-kak windows keep their own shape.
Cursor.BEAM = 'a:ver25-Cursor'

--- Construct a fresh cursor-swap instance. Each session can own
--- one to keep its `_orig` capture round-trip isolated; the
--- module-level helpers below share a single instance so the
--- existing single-state behaviour is preserved.
---@return kak.ui.cursor.Cursor
function Cursor.new() return setmetatable({ _orig = nil }, Cursor) end

--- Switch the nvim cursor shape to match the kakoune mode.
--- Captures the original `guicursor` lazily on the first insert/
--- replace entry; a user who never enters insert keeps their default
--- untouched.
---@param mode string
function Cursor:apply(mode)
  if mode == 'insert' or mode == 'replace' then
    if self._orig == nil then self._orig = vim.o.guicursor end
    if vim.o.guicursor ~= Cursor.BEAM then vim.o.guicursor = Cursor.BEAM end
  elseif self._orig ~= nil then
    if vim.o.guicursor ~= self._orig then vim.o.guicursor = self._orig end
    self._orig = nil
  end
end

--- Restore the user's original `guicursor` (called from WinLeave /
--- Session:close / VimLeavePre so non-kak windows keep their shape).
--- No-op if no capture happened yet.
function Cursor:restore()
  if self._orig ~= nil then
    if vim.o.guicursor ~= self._orig then vim.o.guicursor = self._orig end
    self._orig = nil
  end
end

-- Shared singleton for the module-level helpers. New sessions can
-- spin up their own `Cursor.new()` if they need isolated state; the
-- existing call sites (init.lua, handlers.lua) keep using the
-- facade and share this instance, preserving the previous "one
-- process-wide cursor swap" behaviour.
local shared = Cursor.new()

---@class kak.ui.cursor.Module
---@field apply_cursor_shape fun(mode: string)
---@field restore_cursor_shape fun()
local M = {}

---@param mode string
function M.apply_cursor_shape(mode) shared:apply(mode) end

function M.restore_cursor_shape() shared:restore() end

return M
