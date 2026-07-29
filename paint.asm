; Display.
;
; ONE FRAME, ONE WRITE
;
; Every routine below composes into the frame buffer and ends with a single
; WriteFile. A console program that writes per fragment spends nearly all of
; its time in the console host, and it shows the moment a key is held down.
;
; DAMAGE, NOT REDRAW
;
; The interesting part is that a full repaint is the exceptional case. Each
; kind of change has an entry point sized to it:
;
;   paint_full     ruler, every row, status        resize, page move, goto
;   paint_scroll   SU/SD plus the rows exposed     one- or few-row scrolling
;   paint_rows     a row range plus status         a write or restore landed
;   paint_cells    two byte cells plus status      the cursor moved, a byte
;                                                  was typed
;   paint_status   the last line                   pane toggle, a note
;
; Arrow-key navigation — the thing the user does most — costs paint_cells:
; four cursor addresses, four SGR changes, three characters of payload, about
; ninety bytes for the whole frame. Scrolling costs one SU/SD and one rendered
; row, because the terminal moves the other rows itself; the addresses in the
; address column move with them, which is the reason a hex dump can be scrolled
; this way at all.
;
; SGR runs, not SGR per cell
;
; render_row asks emit_attr for a class per byte, and emit_attr emits nothing
; unless the class differs from the one already in effect. An ordinary row is
; therefore one address colour and one reset for the whole 76 columns; a row
; carrying the cursor costs four more sequences.
;
; REGISTERS
;
; RBX -> hex, RDI = frame-buffer write pointer, both live across every helper
; here. The `<| |>` fragment notation clobbers RSI and RCX, which is why no
; helper holds anything in them. The emit_* leaves take no frame: they make no
; calls and cannot fault, so there is nothing for an unwinder to describe.

define win32.select.types system_console
define win32.select.downlevel kernel32

include 'common/policy.g'
include 'common/names.g'
include 'hexed.h'
include 'common/vt.g'	; after the structures; see the note in policy.g

extrn hex

□	io_count	dd ?


; RDI -> end of the composed frame.
public vt_flush
proc vt_flush
	mov	rdx, [hex + HexState.obuf]
	mov	r8, rdi
	sub	r8, rdx
	WriteFile [hex + HexState.hOutput], rdx, r8, &io_count, 0
	ret
endp


; Title, then the alternate screen buffer, so the shell's scrollback is left
; exactly as it was found.
public vt_setup
proc vt_setup uses rbx rsi rdi
	lea	rbx, [hex]
	mov	rdi, [hex + HexState.obuf]
	<| 27,']0;hexed - ' |>
	mov	rsi, [rbx + HexState.name]
.title:	lodsb
	test	al, al
	jz	.done
	stosb
	jmp	.title
.done:
	<|	7,\
		27,'[?1049h',\		; alternate screen buffer
		27,'[?25l'	|>	; nothing is painted until the size is known
	call	vt_flush
	ret
endp


; Ask for a window ECX columns by EDX lines:
; XTWINOPS `CSI 8 ; rows ; cols t`.
;
; This is the terminal's own mechanism and the only one a modern host honours.
; SetConsoleWindowInfo/SetConsoleScreenBufferSize are the legacy path: a host
; that owns its window — anything over ConPTY — ignores them, and so does the
; HWND from GetConsoleWindow, which under ConPTY is a hidden 0x0 stub owned by
; this process rather than the terminal's window.
public vt_resize
proc vt_resize uses rbx rsi rdi
	locals
		want_cols	dd ?
		want_lines	dd ?
	endl
	mov	[want_cols], ecx		; the fragment notation clobbers RCX
	mov	[want_lines], edx
	lea	rbx, [hex]
	mov	rdi, [rbx + HexState.obuf]
	<| 27,'[8;' |>
	mov	eax, [want_lines]
	call	emit_dec
	mov	al, ';'
	stosb
	mov	eax, [want_cols]
	call	emit_dec
	mov	al, 't'
	stosb
	call	vt_flush
	ret
endp


public vt_restore
proc vt_restore uses rbx rsi rdi
	lea	rbx, [hex]
	mov	rdi, [hex + HexState.obuf]
	<|	27,'[r',\			; release the scroll region
		27,'[m',27,'[?25h',\
		27,'[?1049l'		|>	; main screen buffer
	call	vt_flush
	ret
endp


; The one line that outlives the alternate screen buffer.
;
; Everything the editor knew was on a screen that is torn down on the way out,
; so leaving without a word means the session's only lasting question — did
; this change the file? — is answered nowhere. It is written to the main
; screen, after the alternate buffer is gone, and it doubles as the linefeed
; PowerShell wants before it repaints its prompt.
public vt_summary
proc vt_summary uses rbx rsi rdi
	lea	rbx, [hex]
	mov	rdi, [rbx + HexState.obuf]
	<| 'hexed: ' |>
	mov	rsi, [rbx + HexState.name]
.name:	lodsb
	test	al, al
	jz	.state
	stosb
	jmp	.name
.state:
	mov	rax, [rbx + HexState.written]
	test	rax, rax
	jz	.unchanged
	<| ': ' |>
	mov	eax, dword [rbx + HexState.written]
	call	emit_dec
	cmp	dword [rbx + HexState.written], 1
	jz	.one_written
	<| ' bytes written' |>
	jmp	.discarded
.one_written:
	<| ' byte written' |>
	jmp	.discarded
.unchanged:
	<| ': unchanged' |>

	; Ctrl+Break and a window close cannot stop to ask, so they drop pending
	; changes. Dropping them is the safe direction; dropping them quietly is
	; not, and this is the only place left to say so.
.discarded:
	cmp	dword [rbx + HexState.discarded], 0
	jz	.done
	<| ', ' |>
	mov	eax, [rbx + HexState.discarded]
	call	emit_dec
	cmp	dword [rbx + HexState.discarded], 1
	jz	.one_lost
	<| ' pending bytes DISCARDED' |>
	jmp	.done
.one_lost:
	<| ' pending byte DISCARDED' |>
.done:
	<| 13,10 |>
	call	vt_flush
	ret
endp


public paint_full
proc paint_full uses rbx rsi rdi
	lea	rbx, [hex]
	call	frame_begin
	cmp	dword [rbx + HexState.toosmall], 0
	jnz	.small

	<| 27,'[2J' |>
	call	emit_stbm
	call	render_header
	xor	r10d, r10d
.row:	call	render_row
	inc	r10d
	cmp	r10d, [rbx + HexState.viewrows]
	jc	.row
	call	render_status
	call	frame_end
	call	vt_flush
	ret

.small:
	<| 27,'[r',27,'[2J' |>
	mov	eax, [rbx + HexState.row0]
	inc	eax
	mov	edx, 1
	call	emit_cup
	mov	eax, ATTR_NORM
	call	emit_attr
	<| 'hexed: needs 76 columns and 4 lines; this window will not take them.' |>
	<| 27,'[?25h' |>
	call	vt_flush
	ret
endp


; ECX = signed row delta, already applied to view_off and loaded. |ECX| is less
; than viewrows; anything larger is not cheaper than a full repaint, and the
; caller sends those to paint_full instead.
public paint_scroll
proc paint_scroll uses rbx rsi rdi
	locals
		delta	dd ?		; signed; the stale-cell arithmetic needs it
		count	dd ?		; how many rows, unsigned
		endrow	dd ?
	endl
	mov	[delta], ecx
	lea	rbx, [hex]
	call	frame_begin

	mov	eax, [delta]
	test	eax, eax
	js	.back

	; forward: the region scrolls up, the last rows are exposed
	mov	[count], eax
	<| 27,'[' |>
	mov	eax, [count]
	call	emit_dec
	mov	al, 'S'
	stosb
	mov	r10d, [rbx + HexState.viewrows]
	sub	r10d, [count]
	jmp	.rows

.back:	; backward: the region scrolls down, the first rows are exposed
	neg	eax
	mov	[count], eax
	<| 27,'[' |>
	mov	eax, [count]
	call	emit_dec
	mov	al, 'T'
	stosb
	xor	r10d, r10d

.rows:	mov	eax, r10d
	add	eax, [count]
	mov	[endrow], eax
.row:	call	render_row
	inc	r10d
	cmp	r10d, [endrow]
	jc	.row

	; The terminal moved the cursor's highlight along with everything else,
	; so it is now one scroll away from where it belongs — a stale reverse
	; cell at the old screen position and no highlight at the new one. The
	; byte that *should* be drawn where the stale one sits is exactly
	; `cur - delta*BPR`, so repainting that cell and the cursor's own puts
	; both right. Only the cursor is at stake: scrolling is refused while
	; anything is changed, so no cell can be carrying ATTR_CHG here.
	;
	; Rendering the exposed rows without this is the bug that made an
	; up-scroll leave a highlight behind.
	mov	eax, [rbx + HexState.cur]
	mov	ecx, [delta]
	shl	ecx, 4			; * BPR
	sub	eax, ecx
	js	.cursor			; scrolled off the top; nothing stale
	cmp	eax, [rbx + HexState.view_cap]
	jnc	.cursor			; scrolled off the bottom
	mov	r11d, eax
	call	render_cell
.cursor:
	mov	r11d, [rbx + HexState.cur]
	call	render_cell

	call	render_status
	call	frame_end
	call	vt_flush
	ret
endp


; ECX = first row, EDX = last row, inclusive.
public paint_rows
proc paint_rows uses rbx rsi rdi
	locals
		endrow	dd ?
	endl
	lea	rbx, [hex]
	mov	eax, [rbx + HexState.viewrows]
	dec	eax
	cmp	edx, eax
	cmovg	edx, eax
	mov	[endrow], edx
	mov	r10d, ecx
	call	frame_begin
.row:	call	render_row
	inc	r10d
	cmp	r10d, [endrow]
	jbe	.row
	call	render_status
	call	frame_end
	call	vt_flush
	ret
endp


; ECX = the index that was highlighted; HexState.cur is the one that is now.
; Repainting exactly two byte cells is what makes held-down arrow keys cheap.
public paint_cells
proc paint_cells uses rbx rsi rdi
	locals
		older	dd ?
	endl
	mov	[older], ecx
	lea	rbx, [hex]
	call	frame_begin
	mov	r11d, [older]
	call	render_cell
	mov	r11d, [rbx + HexState.cur]
	call	render_cell
	call	render_status
	call	frame_end
	call	vt_flush
	ret
endp


public paint_status
proc paint_status uses rbx rsi rdi
	lea	rbx, [hex]
	call	frame_begin
	call	render_status
	call	frame_end
	call	vt_flush
	ret
endp


; The forced prompt: a resize arrived while this view held changes, so the
; geometry cannot be applied until the user has said what to do with them. The
; data rows are deliberately not drawn — they would have to be drawn at a
; geometry that does not match the buffer they came from.
public paint_pending
proc paint_pending uses rbx rsi rdi
	lea	rbx, [hex]
	call	frame_begin
	<| 27,'[r',27,'[2J' |>
	mov	eax, ATTR_NORM
	call	emit_attr
	mov	eax, [rbx + HexState.row0]
	add	eax, 2
	mov	edx, 3
	call	emit_cup
	<| 'This view holds changes that are not in the file.' |>
	mov	eax, [rbx + HexState.row0]
	add	eax, 4
	mov	edx, 3
	call	emit_cup
	<| 'The window was resized, so the view has to be rebuilt.' |>
	call	render_status
	call	frame_end
	call	vt_flush
	ret
endp


;------------------------------------------------------------------ composition
; Plain labels from here down: no frames, no calls out, RBX and RDI live.

frame_begin:
	mov	rdi, [rbx + HexState.obuf]
	mov	dword [rbx + HexState.attr], ATTR_UNKNOWN
	<| 27,'[?25l' |>
	retn


; Park the terminal's own cursor on the nibble being edited, so the caret the
; user is watching is the real one and blinks where the next keystroke lands.
frame_end:
	mov	eax, ATTR_NORM
	call	emit_attr
	cmp	dword [rbx + HexState.prompt], PROMPT_NONE
	jnz	.prompt			; the prompt line already left it there
	mov	r11d, [rbx + HexState.cur]
	mov	r10d, r11d
	and	r10d, BPR-1
	mov	eax, r11d
	shr	eax, 4
	add	eax, DATA_ROW0
	add	eax, [rbx + HexState.row0]
	cmp	dword [rbx + HexState.pane], PANE_ASCII
	jz	.ascii
	call	hex_column
	add	edx, [rbx + HexState.nibble]
	jmp	.place
.ascii:	lea	edx, [r10 + ASCII_COL0]
.place:	call	emit_cup
.prompt:
	<| 27,'[?25h' |>
	retn


; DECSTBM over the data rows. Absolute cursor addressing ignores the margins,
; so the ruler and the status line stay reachable; only SU/SD care.
emit_stbm:
	<| 27,'[' |>
	mov	eax, [rbx + HexState.row0]
	add	eax, DATA_ROW0
	call	emit_dec
	mov	al, ';'
	stosb
	mov	eax, [rbx + HexState.viewrows]
	add	eax, [rbx + HexState.row0]
	add	eax, DATA_ROW0 - 1
	call	emit_dec
	mov	al, 'r'
	stosb
	retn


render_header:
	mov	eax, [rbx + HexState.row0]
	add	eax, HDR_ROW
	mov	edx, 1
	call	emit_cup
	mov	eax, ATTR_DIM
	call	emit_attr
	<| '  offset  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  0123456789ABCDEF',27,'[K' |>
	retn


; R10D = row within the view, preserved. R11D is the running byte index and R8D
; the column counter; neither emit_cup nor emit_u32 touches them.
render_row:
	lea	eax, [r10 + DATA_ROW0]
	add	eax, [rbx + HexState.row0]
	mov	edx, 1
	call	emit_cup

	mov	eax, ATTR_DIM
	call	emit_attr
	mov	eax, r10d
	shl	eax, 4
	add	eax, dword [rbx + HexState.view_off]
	mov	ecx, 8
	call	emit_u32

	mov	eax, ATTR_NORM
	call	emit_attr
	<| '  ' |>

	mov	r11d, r10d
	shl	r11d, 4
	xor	r8d, r8d
.hex:	call	cell_class
	call	emit_attr
	cmp	eax, ATTR_DIM
	jz	.hexpad
	call	emit_byte_hex
	jmp	.hexsep
.hexpad:
	mov	ax, '  '
	stosw
.hexsep:
	inc	r11d
	inc	r8d
	cmp	r8d, BPR
	jnc	.ascii
	mov	eax, ATTR_NORM
	call	emit_attr
	mov	al, ' '
	stosb
	cmp	r8d, GROUP
	jnz	.hex
	mov	al, ' '			; the group gap
	stosb
	jmp	.hex

.ascii:	mov	eax, ATTR_NORM
	call	emit_attr
	<| '  ' |>
	mov	r11d, r10d
	shl	r11d, 4
	xor	r8d, r8d
.asc:	call	cell_class		; EAX = class, DL = byte
	mov	r9d, eax		; byte_is_plain wants EAX for itself
	cmp	r9d, ATTR_DIM
	jz	.ascpad
	call	byte_is_plain
	mov	eax, r9d
	jnc	.ascattr
	or	eax, ATTR_NP
.ascattr:
	call	emit_attr
	call	emit_glyph
	jmp	.ascnext
.ascpad:
	mov	eax, r9d
	call	emit_attr
	mov	al, ' '
	stosb
.ascnext:
	inc	r11d
	inc	r8d
	cmp	r8d, BPR
	jc	.asc
	retn


; R11D = byte index: repaint that byte in both panes and nothing else.
render_cell:
	mov	r10d, r11d
	and	r10d, BPR-1
	mov	eax, r11d
	shr	eax, 4
	add	eax, DATA_ROW0
	add	eax, [rbx + HexState.row0]
	call	hex_column
	call	emit_cup
	call	cell_class		; EAX = class, DL = byte
	mov	r9d, eax
	call	emit_attr
	cmp	r9d, ATTR_DIM
	jz	.hexpad
	call	emit_byte_hex
	jmp	.ascii
.hexpad:
	mov	ax, '  '
	stosw

.ascii:	mov	eax, r11d
	shr	eax, 4
	add	eax, DATA_ROW0
	add	eax, [rbx + HexState.row0]
	lea	edx, [r10 + ASCII_COL0]
	call	emit_cup		; clobbers RDX, so the byte is re-read
	cmp	r9d, ATTR_DIM
	jz	.ascpad
	mov	rsi, [rbx + HexState.view]
	mov	dl, [rsi + r11]
	call	byte_is_plain
	mov	eax, r9d
	jnc	.ascattr
	or	eax, ATTR_NP
.ascattr:
	call	emit_attr
	call	emit_glyph
	retn
.ascpad:
	mov	eax, r9d
	call	emit_attr
	mov	al, ' '
	stosb
	retn


; R10D = byte position within the row -> EDX = 1-based hex column.
hex_column:
	lea	edx, [r10 + r10*2]
	add	edx, HEX_COL0
	xor	ecx, ecx
	cmp	r10d, GROUP
	setnc	cl			; the group gap, once past byte 7
	add	edx, ecx
	retn


; R11D = byte index -> EAX = attribute class, DL = the byte.
;
; The class comes from comparing view against orig, so there is no dirty map to
; keep in step: what the screen colours and what a write would commit are the
; same comparison. ATTR_DIM means the index is past the end of the file, and DL
; is then meaningless.
cell_class:
	mov	eax, ATTR_DIM
	cmp	r11d, [rbx + HexState.view_bytes]
	jnc	.done
	mov	rsi, [rbx + HexState.view]
	mov	rcx, [rbx + HexState.orig]
	mov	dl, [rsi + r11]
	xor	eax, eax
	cmp	dl, [rcx + r11]
	jz	.notchanged
	or	eax, ATTR_CHG
.notchanged:
	cmp	r11d, [rbx + HexState.cur]
	jnz	.done
	or	eax, ATTR_CUR
.done:	retn


; EAX = class. Emits nothing when the class is already in effect, which is the
; whole reason a plain row costs no escape sequences.
;
; The sequence is composed rather than looked up: the classes are bits and
; there are more combinations than are worth naming. Every sequence starts from
; 0, so a class never has to be unwound in the order it was applied.
emit_attr:
	cmp	eax, [rbx + HexState.attr]
	jz	.done
	mov	[rbx + HexState.attr], eax
	<| 27,'[0' |>
	cmp	eax, ATTR_BAR
	jz	.bar
	cmp	eax, ATTR_PROMPT
	jz	.prompt
	test	eax, ATTR_DIM
	jz	.ink
	<| ';90' |>			; addresses, rulers, past end of file
	jmp	.close
.ink:	test	eax, ATTR_CHG
	jz	.plain
	<| ';93' |>			; changed, not yet in the file
	jmp	.reverse
.plain:	test	eax, ATTR_NP
	jz	.reverse
	<| ';36' |>			; a byte with no glyph of its own
.reverse:
	test	eax, ATTR_CUR
	jz	.close
	<| ';7' |>			; under the cursor
.close:	mov	al, 'm'
	stosb
.done:	retn
.bar:
	<| ';7m' |>			; the footer is a bar, not a line of text
	retn
.prompt:
	<| ';43;30m' |>			; and a question is not the footer
	retn


; DL = byte -> two hex digits. No lookup table: a table would need an absolute
; address to index, and the arithmetic is shorter than the load anyway.
emit_byte_hex:
	movzx	eax, dl
	shr	eax, 4
	lea	ecx, [rax + 'A' - 10]
	cmp	eax, 10
	lea	eax, [rax + '0']
	cmovnc	eax, ecx
	stosb
	movzx	eax, dl
	and	eax, 15
	lea	ecx, [rax + 'A' - 10]
	cmp	eax, 10
	lea	eax, [rax + '0']
	cmovnc	eax, ecx
	stosb
	retn


; DL = byte -> CF set when the active code page has no ordinary glyph for it,
; so the caller can colour the replacement dot before drawing it. The cached
; table uses FFFF for byte values rejected by MultiByteToWideChar; Unicode C0
; and C1 controls are also kept out of the terminal stream.
byte_is_plain:
	movzx	eax, dl
	movzx	eax, word [rbx + HexState.glyphs + rax*2]
	cmp	eax, 0xFFFF
	jz	.no
	cmp	eax, 0x20
	jc	.no
	cmp	eax, 0x7F
	jc	.yes
	cmp	eax, 0xA0
	jc	.no
.yes:	clc
	retn
.no:	stc
	retn


; DL = byte -> one column of the right-hand pane.
emit_glyph:
	movzx	eax, dl
	movzx	eax, word [rbx + HexState.glyphs + rax*2]
	cmp	eax, 0xFFFF
	jz	.dot
	cmp	eax, 0x20
	jc	.dot
	cmp	eax, 0x7F
	jc	.utf8
	cmp	eax, 0xA0
	jc	.dot
.utf8:
	jmp	emit_utf8
.dot:	mov	al, '.'
	stosb
	retn


; EAX = code point below U+10000 -> UTF-8. One column, up to three bytes, which
; is why the frame budget carries three per ASCII cell.
emit_utf8:
	cmp	eax, 0x80
	jc	.one
	cmp	eax, 0x800
	jc	.two
	mov	ecx, eax
	shr	ecx, 12
	or	ecx, 0xE0
	mov	[rdi], cl
	inc	rdi
	mov	ecx, eax
	shr	ecx, 6
	and	ecx, 0x3F
	or	ecx, 0x80
	mov	[rdi], cl
	inc	rdi
	jmp	.tail
.two:	mov	ecx, eax
	shr	ecx, 6
	or	ecx, 0xC0
	mov	[rdi], cl
	inc	rdi
.tail:	and	eax, 0x3F
	or	eax, 0x80
.one:	stosb
	retn


; EAX = row, EDX = column, both 1-based.
emit_cup:
	mov	word [rdi], 27 + ('[' shl 8)
	add	rdi, 2
	mov	r8d, edx
	call	emit_dec
	mov	al, ';'
	stosb
	mov	eax, r8d
	call	emit_dec
	mov	al, 'H'
	stosb
	retn


; EAX = value, ECX = digit count. Written backwards from the end so the width
; is fixed without a leading-zero pass.
emit_u32:
	add	rdi, rcx
	mov	r9, rdi
.digit:	mov	edx, eax
	and	edx, 15
	shr	eax, 4
	lea	r8d, [rdx + 'A' - 10]
	cmp	edx, 10
	lea	edx, [rdx + '0']
	cmovnc	edx, r8d
	dec	rdi
	mov	[rdi], dl
	dec	ecx
	jnz	.digit
	mov	rdi, r9
	retn


; EAX = value, no leading zeros. The sentinel makes the emit loop its own
; terminator.
emit_dec:
	push	-1
	mov	ecx, 10
.split:	xor	edx, edx
	div	ecx
	push	rdx
	test	eax, eax
	jnz	.split
	pop	rax
.out:	add	al, '0'
	stosb
	pop	rax
	test	eax, eax
	jns	.out
	retn



;-------------------------------------------------------------------- the footer
; What is NOT on screen already.
;
; The offset, the byte under the cursor and its character were all in here, and
; all three are things the user reads off the view — the cursor is highlighted,
; the address is at the head of its row, the character is in the right-hand
; pane. Restating them cost a line and told nobody anything. What the view
; cannot say is which file this is, how big it is, how the right-hand pane is
; being read, and whether what is on screen matches the disk. That is the
; footer.
;
; It is drawn reversed and padded to the window edge so it reads as a bar
; rather than as another row of data. The prompt takes the whole line in a
; different colour again: a question about unwritten data should not have to
; share, and should not look like the thing it replaces.

render_status:
	mov	eax, [rbx + HexState.lines]
	add	eax, [rbx + HexState.row0]
	mov	edx, 1
	call	emit_cup
	cmp	dword [rbx + HexState.prompt], PROMPT_NONE
	jnz	.prompt

	mov	eax, ATTR_BAR
	call	emit_attr
	mov	r9, rdi			; the bar starts here; see .eol
	<| ' ' |>

	; Base name only, and clipped at that. The full path is in the window
	; title, where it costs nothing; here it would push the state that
	; matters off the end of the bar.
	mov	rsi, [rbx + HexState.name]
	mov	rcx, rsi
.scan:	lodsb
	test	al, al
	jz	.base
	cmp	al, '\'
	jz	.sep
	cmp	al, '/'
	jnz	.scan
.sep:	mov	rcx, rsi		; one past the separator
	jmp	.scan
.base:	mov	rsi, rcx
	mov	ecx, 28
.name:	lodsb
	test	al, al
	jz	.sized
	stosb
	dec	ecx
	jnz	.name
	mov	al, '~'
	stosb
.sized:
	<| '  ' |>
	mov	eax, dword [rbx + HexState.file_size]
	call	emit_dec
	<| ' bytes  ' |>

	<| 'cp' |>
	mov	eax, [rbx + HexState.codepage]
	call	emit_dec

.flags:	cmp	dword [rbx + HexState.readonly], 0
	jz	.mod
	<| '  read-only' |>
	jmp	.note
.mod:	cmp	dword [rbx + HexState.chg_lo], 0
	js	.note
	<| '  MODIFIED' |>

.note:	mov	rsi, [rbx + HexState.msg]
	test	rsi, rsi
	jz	.keys
	<| '  - ' |>
	mov	rsi, [rbx + HexState.msg]
.copy:	lodsb
	test	al, al
	jz	.eol
	stosb
	jmp	.copy
.keys:
	<| '   F2 write  F5 restore  F3 charset  Tab pane  Esc Esc quit' |>

; Pad or clip to the window edge.
;
; ESC[K is not enough. It erases with the current background colour, and
; reverse video is an attribute rather than a colour, so the bar ended where
; its text ended and the rest of the line stayed plain — measured, at
; attr[0] = 0x4007 and attr[75] = 0x0007.
;
; Nothing between R9 and here emits an escape sequence, so bytes written are
; columns used and the line can be squared off exactly.
.eol:	mov	rcx, rdi
	sub	rcx, r9
	mov	eax, [rbx + HexState.cols]
	cmp	ecx, eax
	jnc	.clip
	sub	eax, ecx
	mov	ecx, eax
	mov	al, ' '
	rep	stosb
	jmp	.done
.clip:	lea	rdi, [r9 + rax]
.done:	mov	eax, ATTR_NORM
	call	emit_attr
	retn

.prompt:
	mov	eax, ATTR_PROMPT
	call	emit_attr
	mov	r9, rdi
	cmp	dword [rbx + HexState.prompt], PROMPT_FORCED
	jz	.forced
	<| ' changes pending in this view:  W write   R restore   Esc cancel ' |>
	jmp	.eol
.forced:
	<| ' changes pending in this view:  W write   R restore ' |>
	jmp	.eol
