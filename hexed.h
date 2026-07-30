; Geometry, state and the contract between the three objects.
;
; LAYOUT
;
; Sixteen bytes per row, one fixed arrangement, 76 columns wide:
;
;   1        11                          36                        61      76
;   |        |                           |                         |       |
;     offset  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  0123456789ABCDEF
;   00000000  7F 45 4C 46 02 01 01 00  00 00 00 00 00 00 00 00  .ELF............
;
; Row 1 is the ruler, row LINES is status or prompt, and the rows between are
; the view.
;
; WIDTH IS THE PROGRAM'S, HEIGHT IS THE USER'S
;
; Sixteen bytes per row is what a hex dump means, and reflowing to eight would
; silently change every address on screen. So the width is not negotiated: it
; is read at start, held at LAYOUT_COLS while running, and put back on exit.
; There is nothing useful to do with a wider window and nothing honest to do
; with a narrower one, so the program takes the column budget it needs rather
; than reporting that the window is wrong.
;
; Height is the opposite. It has a minimum — a ruler, a row, and a status line
; — and no maximum: the view is however many rows the window has. That is why
; the buffers below are sized from the geometry at run time instead of from a
; constant. A taller window is simply a bigger read.
;
; VIEW
;
; The view is the unit of everything. It is the rows on screen, it is the
; region read from the file, it is the only region an edit can reach, and it is
; the only region a write can touch. `view` holds what is displayed, `orig`
; holds what the file says, and the difference between them is the pending
; change set — there is no separate dirty map to fall out of step.
;
; Navigation can carry that difference into an overlapping destination only
; while every changed absolute byte remains visible. The pending span is saved,
; the destination and its baseline are read, and the span is reapplied at its
; new index. A move that would exclude any change prompts instead. This keeps
; the display code free of a persistent shadow document.

if ~ definite HEXED_H_INCLUDED
HEXED_H_INCLUDED := 1

BPR		:= 16		; bytes per row
LAYOUT_COLS	:= 76		; the width the layout needs, and the width it takes
MIN_LINES	:= 4		; ruler + one view row + status, and one to spare

HDR_ROW		:= 1
DATA_ROW0	:= 2
HEX_COL0	:= 11		; column of the first hex digit
GROUP		:= 8		; extra space after this many bytes
ASCII_COL0	:= 61

; Frame-buffer budget for one view row, worst case: a cursor address (10), the
; address colour and its reset (10), the address and the two gaps (12), then
; sixteen hex cells each preceded by the longest SGR this program emits,
; ESC[0;93;7m (16 x 12 = 192), fifteen separators each preceded by a reset
; (60), the group gap, and sixteen ASCII cells on the same terms (176). That
; comes to 466; 512 leaves room and keeps the arithmetic in shifts.
;
; A row costs nothing like this in practice — emit_attr only speaks when the
; class changes, so an ordinary row is two sequences — but the frame buffer
; must survive the pathological case, because the pathological case is just an
; edit that touched alternate bytes.
; plus two more bytes per ASCII cell, because a single-byte code-page glyph is
; up to three bytes of UTF-8 in one column.
OBUF_PER_ROW	:= 640
OBUF_SLACK	:= 4096		; ruler, status, prompt, setup and teardown
ARENA_PER_ROW	:= OBUF_PER_ROW + 2 * BPR	; frame + view + orig

; Attribute classes. CHG, CUR and NP are bits, so a changed control byte under
; the cursor is their union and emit_attr composes the sequence rather than
; looking one up. The renderer emits SGR only where the class differs from the
; last one emitted, which is why an ordinary row costs no escape sequences at
; all and a row holding the cursor costs four.
ATTR_NORM	:= 0
ATTR_CHG	:= 1		; differs from the file
ATTR_CUR	:= 2		; under the cursor
ATTR_NP		:= 4		; no glyph in the current character set
ATTR_DIM	:= 8		; addresses, rulers, past end of file
ATTR_BAR	:= 16		; the footer, so it reads as a bar
ATTR_PROMPT	:= 32		; the footer when it is asking a question
ATTR_UNKNOWN	:= -1		; frame start: force the next SGR

PANE_HEX	:= 0
PANE_ASCII	:= 1

; Single-byte code pages for the right-hand pane. The console output code page
; captured at startup is prepended when it is an SBCS; F3 then cycles that page
; and these baked-in favorites, skipping duplicates and unsupported entries.
; Edit this one list to make the cycle fit the local workflow.
define HEXED_CODEPAGES 437,850,1252

match pages, HEXED_CODEPAGES
	iterate cp, pages
		; %% is the total number of elements in this iterate block.
		if % = 1
			HEXED_CODEPAGE_FAVORITES := %%
		end if
	end iterate
end match
HEXED_CODEPAGE_CAPACITY := HEXED_CODEPAGE_FAVORITES + 1

; A navigation request becomes data when its destination would exclude a
; pending change: the prompt stores the request and replays it once the user
; has answered.
NAV_NONE	:= 0
NAV_SCROLL	:= 1		; pend_arg = signed row delta
NAV_GOTO	:= 2		; pend_arg = absolute view offset
NAV_QUIT	:= 3
NAV_RESIZE	:= 4		; geometry already in cols/lines

; How nav_perform obtains and paints the destination view.
VIEW_FRESH	:= 0		; clean view: reload and use damage-sized painting
VIEW_REPAINT	:= 1		; prompt resolved: reload and replace stale attributes
VIEW_RETAIN	:= 2		; pending span remains visible: reload and reapply it

PROMPT_NONE	:= 0
PROMPT_NAV	:= 1		; write / restore / cancel
PROMPT_FORCED	:= 2		; write / restore; the request cannot be refused

; Fields carry the `?` prefix the projection's generated types use. Without it
; a field's name is defined as a real label when the struct is declared, and
; instantiating the struct then collides with it — `HexState.hInput already
; defined`. Offsets are spelled `HexState.field` either way, which is the only
; form this program uses: the state is reached through RBX, never by name.
struct HexState
	; WaitForMultipleObjects takes these two as an array. Adjacent, in this
	; order, is load-bearing — see the assert below.
	?hInput		dq ?
	?hQuit		dq ?

	?hOutput	dq ?
	?hFile		dq ?

	?arena		dq ?	; one VirtualAlloc, carved into the three below
	?arena_size	dq ?	; what that allocation currently holds
	?obuf		dq ?	; frame buffer, viewrows * OBUF_PER_ROW + slack
	?view		dq ?	; displayed bytes, view_cap
	?orig		dq ?	; the same bytes as the file has them, view_cap

	?file_size	dq ?
	?view_off	dq ?	; file offset of view row 0; always BPR-aligned
	?pend_arg	dq ?
	?written	dq ?	; bytes committed this session, for the exit line
	?name		dq ?	; -> file name, into the process command line
	?msg		dq ?	; -> transient status note, 0 = none

	?view_bytes	dd ?	; valid bytes in view; short at end of file
	?view_cap	dd ?	; viewrows * BPR
	?cols		dd ?	; the window's extent, not the buffer's
	?lines		dd ?
	?row0		dd ?	; top row of the window within the buffer, 0-based
	?viewrows	dd ?
	?cur		dd ?	; cursor, index into view
	?nibble		dd ?	; 0 = high, 1 = low; hex pane only
	?pane		dd ?
	?charset	dd ?	; index into codepages
	?codepage	dd ?	; active byte-to-Unicode mapping
	?codepage_count	dd ?
	?discarded	dd ?	; pending bytes abandoned at exit, for the exit line
	?chg_lo		dd ?	; lowest changed index, -1 when clean
	?chg_hi		dd ?	; highest changed index, inclusive
	?readonly	dd ?
	?toosmall	dd ?	; the window could not be made to fit
	?fix_cols	dd ?	; width already attempted; a terminal that will
				; not take LAYOUT_COLS must not be asked twice
	?prompt		dd ?
	?pend_act	dd ?
	?last_up_vk	dd ?	; ESC ESC to leave
	?attr		dd ?	; SGR class currently in effect in the frame
	?oldInMode	dd ?
	?oldOutMode	dd ?
	?oldOutCP	dd ?	; startup decode candidate, restored on exit
	?result		dd ?

	?codepages	dd HEXED_CODEPAGE_CAPACITY dup ?
	?glyphs		dw 256 dup ?	; byte -> BMP code point; FFFF = invalid
ends

assert HexState.hQuit = 8 + HexState.hInput

end if
