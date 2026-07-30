; hexed — a console hex editor.
;
;       hexed <file>
;
; Built from fasm2/examples/conio: the same non-blocking event loop over
; ReadConsoleInput, the same alternate-screen and console-mode discipline, the
; same restore-what-you-changed exit. What conio spends on displaying events,
; this spends on displaying a document cheaply while the user moves through it.
;
; WHAT AN EDIT CAN REACH
;
; The view — the rows on screen — is the whole editable surface. Typing changes
; a byte in the view and nothing else; the cursor cannot leave the view without
; a navigation request. A request proceeds while its destination still contains
; every changed byte; otherwise the user is asked first:
;
;       changes pending in this view:  W write   R restore   Esc cancel
;
; So a keystroke can never modify a byte that was not on screen when it was
; pressed, and moving a changed byte off screen is always a decision rather
; than an accident. Ctrl and Alt chords are refused by the data-entry path
; outright, which is the other half of that promise: a mis-typed chord is a
; no-op, not an edit.
;
; A resize follows the same containment rule. When it would exclude a changed
; byte it takes the same prompt, minus the cancel a resize cannot honour.
;
; GEOMETRY COMES FROM THE FIRST EVENT
;
; Nothing is painted until a WINDOW_BUFFER_SIZE_EVENT arrives, which is the
; first record the console delivers after the switch to the alternate buffer.
; That makes one path — apply geometry, load the view, repaint — responsible
; for both startup and every later resize, and removes the usual startup
; special case entirely.

define win32.select.types system_console,globalization
define win32.select.downlevel kernel32

include 'common/policy.g'
include 'common/names.g'
include 'hexed.h'
include 'common/vt.g'	; after the structures; see the note in policy.g

; Exposed and linker-recognized interface.
public hex
public mainCRTStartup
public _load_config_used

; Application-thread register contract. mainCRTStartup never returns, every
; internal call runs on that one thread, and Win64 preserves these registers:
;
;   RBX = &hex, for the lifetime of the process
;   RBP = &irec, for the lifetime of the event loop
;   RDI = next byte in the frame buffer; the event loop drains and resets it
;   RSI = source/scan cursor, intentionally owned scratch
;
; ConsoleCtrlHandler is entered by Windows on another thread and therefore
; relies on none of them.

extrn view_clamped
extrn view_load
extrn view_retain
extrn view_rescan
extrn view_commit
extrn view_restore

extrn vt_setup
extrn vt_resize
extrn vt_restore
extrn vt_summary

extrn paint_full
extrn paint_scroll
extrn paint_rows
extrn paint_cells
extrn paint_status
extrn paint_pending

□	hex	HexState
□	irec	INPUT_RECORD
□	io_count dd ?
≡	codepage_favorites dd HEXED_CODEPAGES

IREC_EVENT_TYPE		:= irec.EventType - irec
IREC_KEY_DOWN		:= irec.Event.KeyEvent.bKeyDown - irec
IREC_KEY_VK		:= irec.Event.KeyEvent.wVirtualKeyCode - irec
IREC_KEY_CHAR		:= irec.Event.KeyEvent.uChar.UnicodeChar - irec
IREC_KEY_CONTROL	:= irec.Event.KeyEvent.dwControlKeyState - irec
IREC_WINDOW_X		:= irec.Event.WindowBufferSizeEvent.dwSize.X - irec
IREC_WINDOW_Y		:= irec.Event.WindowBufferSizeEvent.dwSize.Y - irec
IREC_MOUSE_X		:= irec.Event.MouseEvent.dwMousePosition.X - irec
IREC_MOUSE_Y		:= irec.Event.MouseEvent.dwMousePosition.Y - irec
IREC_MOUSE_BUTTONS	:= irec.Event.MouseEvent.dwButtonState - irec
IREC_MOUSE_FLAGS	:= irec.Event.MouseEvent.dwEventFlags - irec

; The console as it was found, captured before anything is changed and used to
; put the width back on the way out.
□	saved	CONSOLE_SCREEN_BUFFER_INFO


; Restoring the terminal on Ctrl+Break is what makes this a well-behaved
; console program; the alternate screen buffer is not something to leave the
; user sitting in. Ctrl+C never arrives — ReadConsoleInput without
; ENABLE_PROCESSED_INPUT delivers it as an ordinary key — and a close does not
; need the terminal restored.
;
; Pending changes are discarded on this path. There is no way to ask, and
; discarding leaves the file exactly as it was, which is the safe direction.
proc ConsoleCtrlHandler dwCtrlType
	cmp	ecx, 3			; CTRL_C, CTRL_BREAK, CTRL_CLOSE
	jnc	.not_handled
	; `hex` is this module's own label and carries the whole structure's
	; size, so the field's size is stated rather than inherited.
	SetEvent qword [hex + HexState.hQuit]
	mov	eax, TRUE
	ret
.not_handled:
	xor	eax, eax
	ret
endp


proc mainCRTStartup
	locals
		oldin	dd ?
		oldout	dd ?
		nread	dd ?
		fsize	dq ?
	endl
	lea	rbx, [hex]
	lea	rbp, [irec]
	mov	dword [rbx + HexState.result], 1
	mov	dword [rbx + HexState.chg_lo], -1
	mov	dword [rbx + HexState.chg_hi], -1
	; Until the size event lands there is no geometry, and no geometry means
	; no painting and no editing.
	mov	dword [rbx + HexState.toosmall], 1

	GetStdHandle STD_INPUT_HANDLE
	mov	[rbx + HexState.hInput], rax
	GetStdHandle STD_OUTPUT_HANDLE
	mov	[rbx + HexState.hOutput], rax

	; Redirected handles have no modes, no size events and no VT. Refuse
	; them here rather than painting escape sequences into a pipe.
	GetConsoleMode [rbx + HexState.hInput], &oldin
	test	eax, eax		; BOOL
	jz	.not_a_console
	GetConsoleMode [rbx + HexState.hOutput], &oldout
	test	eax, eax
	jnz	.console_ok
.not_a_console:
.m_console GLOBSTR 'hexed: needs a console, not a redirected handle.',13,10,0
	lea	rsi, [.m_console]
	call	die
.console_ok:
	mov	eax, [oldin]
	mov	[rbx + HexState.oldInMode], eax
	mov	eax, [oldout]
	mov	[rbx + HexState.oldOutMode], eax

	; Captured before the width is taken, so it can be given back.
	GetConsoleScreenBufferInfo [rbx + HexState.hOutput], &saved

	; Capture the user's byte interpretation before changing the console's
	; output transport to UTF-8. init_codepages prepends it when it is an SBCS,
	; then adds the baked favorites from HEXED_CODEPAGES.
	GetConsoleOutputCP
	mov	[rbx + HexState.oldOutCP], eax
	call	init_codepages
	SetConsoleOutputCP CP_UTF8

	call	parse_command_line
	test	rax, rax
	jnz	.have_name
.m_usage GLOBSTR 'hexed <file>',13,10,0
	lea	rsi, [.m_usage]
	call	die
.have_name:
	mov	[rbx + HexState.name], rax

	CreateFileA [rbx + HexState.name], GENERIC_READ or GENERIC_WRITE,\
		FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0
	cmp	rax, INVALID_HANDLE_VALUE
	jnz	.opened
	; A file that cannot be written is still worth reading. The editor says
	; so in the status line and refuses every keystroke that would type.
	CreateFileA [rbx + HexState.name], GENERIC_READ,\
		FILE_SHARE_READ or FILE_SHARE_WRITE, 0, OPEN_EXISTING,\
		FILE_ATTRIBUTE_NORMAL, 0
	cmp	rax, INVALID_HANDLE_VALUE
	jnz	.opened_readonly
.m_open GLOBSTR 'hexed: cannot open that file.',13,10,0
	lea	rsi, [.m_open]
	call	die
.opened_readonly:
	mov	dword [rbx + HexState.readonly], 1
.opened:
	mov	[rbx + HexState.hFile], rax

	GetFileSizeEx [rbx + HexState.hFile], &fsize
	test	eax, eax		; BOOL
	jnz	.sized
.m_size GLOBSTR 'hexed: cannot size that file.',13,10,0
	lea	rsi, [.m_size]
	call	die
.sized:
	mov	rax, [fsize]
	mov	[rbx + HexState.file_size], rax
	; The address column is eight hex digits. Showing a ninth would cost the
	; ASCII pane its column budget, and showing a wrong address is worse
	; than refusing the file.
	mov	rcx, rax
	shr	rcx, 32
	jz	.fits
.m_big GLOBSTR 'hexed: files of 4 GiB and over are not addressable here.',13,10,0
	lea	rsi, [.m_big]
	call	die
.fits:

	; Enough arena for the setup and teardown sequences. The real size
	; depends on the window height, which is not known until the first size
	; event, and arena_fit grows this to fit each geometry from there.
	VirtualAlloc 0, OBUF_SLACK, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
	test	rax, rax
	jnz	.have_arena
.m_mem GLOBSTR 'hexed: out of memory.',13,10,0
	lea	rsi, [.m_mem]
	call	die
.have_arena:
	mov	[rbx + HexState.arena], rax
	mov	[rbx + HexState.obuf], rax
	mov	rdi, rax		; first empty frame; the event loop maintains it
	mov	qword [rbx + HexState.arena_size], OBUF_SLACK
	add	rax, OBUF_SLACK
	mov	[rbx + HexState.view], rax
	mov	[rbx + HexState.orig], rax

	; Non-inheritable, manual reset, nonsignaled, unnamed.
	CreateEventW 0, TRUE, FALSE, 0
	mov	[rbx + HexState.hQuit], rax
	SetConsoleCtrlHandler ConsoleCtrlHandler, TRUE

	; ENABLE_EXTENDED_FLAGS makes the assignment authoritative; dropping
	; ENABLE_QUICK_EDIT_MODE with it is what turns a drag into mouse input
	; instead of a selection rectangle.
	SetConsoleMode [rbx + HexState.hInput], ENABLE_EXTENDED_FLAGS\
		or ENABLE_MOUSE_INPUT or ENABLE_WINDOW_INPUT
	SetConsoleMode [rbx + HexState.hOutput], ENABLE_PROCESSED_OUTPUT\
		or ENABLE_VIRTUAL_TERMINAL_PROCESSING
	call	vt_setup

;--------------------------------------------------------------------- the loop
.safe_vt_flush:
	mov	rdx, [rbx + HexState.obuf]
	mov	r8, rdi
	sub	r8, rdx
	jz	.loop
	WriteFile [rbx + HexState.hOutput], rdx, r8, &io_count, 0
	mov	rdi, [rbx + HexState.obuf]

.loop:
	lea	rax, [rbx + HexState.hInput]	; hInput, hQuit — adjacent
	WaitForMultipleObjects 2, rax, FALSE, -1
	cmp	eax, WAIT_OBJECT_0 + 1
	jz	.finish
	cmp	eax, WAIT_OBJECT_0
	jnz	.finish				; WAIT_FAILED: leave cleanly

	ReadConsoleInputW [rbx + HexState.hInput], rbp, 1, &nread
	test	eax, eax		; BOOL
	jz	.loop
	cmp	dword [nread], 1
	jnz	.loop

	movzx	eax, word [rbp + IREC_EVENT_TYPE]
	cmp	eax, KEY_EVENT
	jz	.key
	cmp	eax, MOUSE_EVENT
	jz	.mouse
	cmp	eax, WINDOW_BUFFER_SIZE_EVENT
	jz	.resize
	jmp	.loop

.key:	cmp	dword [rbp + IREC_KEY_DOWN], 0
	jz	.key_up
	cmp	dword [rbx + HexState.prompt], PROMPT_NONE
	jz	.key_editor
	call	on_prompt_key
	jmp	.safe_vt_flush
.key_editor:
	cmp	dword [rbx + HexState.toosmall], 0
	jnz	.loop
	call	on_key_down
	jmp	.safe_vt_flush

	; ESC is tracked on release, so holding it down cannot repeat its way
	; out of the program. conio settled this question already.
.key_up:
	movzx	eax, word [rbp + IREC_KEY_VK]
	cmp	eax, VK_ESCAPE
	jnz	.remember
	cmp	dword [rbx + HexState.prompt], PROMPT_NAV
	jz	.cancel
	cmp	dword [rbx + HexState.last_up_vk], VK_ESCAPE
	jz	.quit_request
.remember:
	mov	[rbx + HexState.last_up_vk], eax
	jmp	.loop

.cancel:
	mov	dword [rbx + HexState.prompt], PROMPT_NONE
	mov	dword [rbx + HexState.pend_act], NAV_NONE
	mov	dword [rbx + HexState.last_up_vk], 0
	mov	qword [rbx + HexState.msg], 0
	call	paint_status
	jmp	.safe_vt_flush

.quit_request:
	mov	dword [rbx + HexState.last_up_vk], 0
	mov	ecx, NAV_QUIT
	xor	edx, edx
	call	nav_request
	jmp	.safe_vt_flush

.mouse:	cmp	dword [rbx + HexState.prompt], PROMPT_NONE
	jnz	.loop
	cmp	dword [rbx + HexState.toosmall], 0
	jnz	.loop
	call	on_mouse
	jmp	.safe_vt_flush

.resize:
	call	on_resize
	jmp	.safe_vt_flush

;------------------------------------------------------------------- and out
.finish:
	mov	dword [rbx + HexState.result], 0

	; Whatever is pending here is about to be abandoned — this path is
	; reached by Ctrl+Break and by a window close as well as by Esc Esc, and
	; the first two cannot stop to ask. Count it before the screen holding
	; it is torn down, so the exit line can say so.
	cmp	dword [rbx + HexState.chg_lo], 0
	js	.nothing_pending
	mov	eax, [rbx + HexState.chg_hi]
	sub	eax, [rbx + HexState.chg_lo]
	inc	eax
	mov	[rbx + HexState.discarded], eax
.nothing_pending:

	call	vt_restore
	; XTWINOPS resized the terminal window, not merely the alternate screen
	; buffer. After returning to the main buffer, ask the terminal to restore
	; the exact window extent captured at startup. The console calls below
	; remain the corresponding legacy path.
	movsx	edx, word [saved.srWindow.Bottom]
	movsx	eax, word [saved.srWindow.Top]
	sub	edx, eax
	inc	edx
	movsx	ecx, word [saved.srWindow.Right]
	movsx	eax, word [saved.srWindow.Left]
	sub	ecx, eax
	inc	ecx
	call	vt_resize
	call	restore_width
	call	vt_summary
	mov	rdx, [rbx + HexState.obuf]
	mov	r8, rdi
	sub	r8, rdx
	WriteFile [rbx + HexState.hOutput], rdx, r8, &io_count, 0
	mov	rdi, [rbx + HexState.obuf]
	mov	eax, [rbx + HexState.oldOutCP]
	SetConsoleOutputCP eax
	mov	eax, [rbx + HexState.oldOutMode]
	SetConsoleMode [rbx + HexState.hOutput], eax
	mov	eax, [rbx + HexState.oldInMode]
	SetConsoleMode [rbx + HexState.hInput], eax
	CloseHandle [rbx + HexState.hFile]
	mov	eax, [rbx + HexState.result]
	ExitProcess rax
endp


; RSI -> message. Says why, then leaves. Only reached before the console has
; been reconfigured, so there is nothing to put back.
proc die
	mov	rdi, rsi
	xor	eax, eax
	mov	ecx, -1
	repnz	scasb
	not	ecx
	dec	ecx			; the terminator is not part of it
	mov	r8d, ecx
	WriteFile [rbx + HexState.hOutput], rsi, r8, &io_count, 0
	ExitProcess 2
endp


; -> RAX = the file name, terminated in place inside the command line, or zero.
; A quoted first argument is unwrapped; everything after it is ignored, because
; this program has no options to confuse a file name with.
proc parse_command_line
	GetCommandLineA
	mov	rsi, rax

	cmp	byte [rsi], '"'
	jnz	.bare_program
	inc	rsi
.quoted_program:
	mov	al, [rsi]
	test	al, al
	jz	.none
	inc	rsi
	cmp	al, '"'
	jnz	.quoted_program
	jmp	.spaces
.bare_program:
	mov	al, [rsi]
	test	al, al
	jz	.none
	cmp	al, ' '
	jbe	.spaces
	inc	rsi
	jmp	.bare_program

.spaces:
	mov	al, [rsi]
	cmp	al, ' '
	jz	.skip
	cmp	al, 9
	jnz	.argument
.skip:	inc	rsi
	jmp	.spaces

.argument:
	test	al, al
	jz	.none
	cmp	al, '"'
	jnz	.bare_argument
	inc	rsi
	mov	rax, rsi
.quoted_argument:
	mov	cl, [rsi]
	test	cl, cl
	jz	.done
	cmp	cl, '"'
	jz	.terminate
	inc	rsi
	jmp	.quoted_argument
.bare_argument:
	mov	rax, rsi
.scan_argument:
	mov	cl, [rsi]
	test	cl, cl
	jz	.done
	cmp	cl, ' '
	jbe	.terminate
	inc	rsi
	jmp	.scan_argument
.terminate:
	mov	byte [rsi], 0
.done:	ret
.none:	xor	eax, eax
	ret
endp


; ECX = code-page identifier -> EAX nonzero only for an available SBCS.
proc codepage_is_sbcs
	locals
		info	CPINFOEXW
	endl
	GetCPInfoExW ecx, 0, &info
	test	eax, eax
	jz	.done
	xor	eax, eax
	cmp	dword [info + CPINFOEXW.MaxCharSize], 1
	sete	al
.done:	ret
endp


; ECX = candidate, EDX = number already in HexState.codepages.
; EAX = one when appended, zero when invalid, multibyte or duplicate.
proc append_codepage
	locals
		page	dd ?
		count	dd ?
	endl
	mov	[page], ecx
	mov	[count], edx
	call	codepage_is_sbcs
	test	eax, eax
	jz	.no

	mov	ecx, [page]
	xor	eax, eax
.scan:	cmp	eax, [count]
	jnc	.append
	cmp	ecx, [rbx + HexState.codepages + rax*4]
	jz	.no
	inc	eax
	jmp	.scan
.append:
	mov	[rbx + HexState.codepages + rax*4], ecx
	mov	eax, 1
	ret
.no:	xor	eax, eax
	ret
endp


; ECX = SBCS identifier -> cache its complete byte-to-Unicode map.
; Invalid byte values receive FFFF and are rendered as highlighted dots.
proc select_codepage
	locals
		page	dd ?
		flags	dd ?
		wide	dw ?
		source	db ?
	endl
	mov	[page], ecx
	mov	eax, MB_ERR_INVALID_CHARS or MB_USEGLYPHCHARS
	cmp	ecx, 42			; CP_SYMBOL accepts only zero flags
	jnz	.have_flags
	xor	eax, eax
.have_flags:
	mov	[flags], eax

	xor	esi, esi
.byte:
	mov	eax, esi
	mov	[source], al
	MultiByteToWideChar [page], [flags], &source, 1, &wide, 1
	cmp	eax, 1
	jnz	.invalid
	movzx	eax, word [wide]
	mov	[rbx + HexState.glyphs + rsi*2], ax
	jmp	.next
.invalid:
	mov	word [rbx + HexState.glyphs + rsi*2], 0xFFFF
.next:	inc	esi
	cmp	esi, 256
	jb	.byte

	mov	eax, [page]
	mov	[rbx + HexState.codepage], eax
	ret
endp


; Build the short F3 cycle: startup console SBCS first, then the compile-time
; HEXED_CODEPAGES favorites. Entries that are unavailable, multibyte or
; duplicates are omitted. The shipped first favorite, CP437, is the fallback
; when the console starts in UTF-8 or another multibyte code page.
proc init_codepages
	locals
		call_align	dq ?
	endl
	xor	edi, edi

	mov	ecx, [rbx + HexState.oldOutCP]
	mov	edx, edi
	call	append_codepage
	add	edi, eax

	lea	rsi, [codepage_favorites]
	repeat HEXED_CODEPAGE_FAVORITES
		lodsd
		mov	ecx, eax
		mov	edx, edi
		call	append_codepage
		add	edi, eax
	end repeat

	; HEXED_CODEPAGES always supplies a valid fallback in the shipped build.
	; Keep a defensive CP437 fallback so a locally edited list cannot leave
	; the renderer without a mapping.
	test	edi, edi
	jnz	.ready
	mov	dword [rbx + HexState.codepages], 437
	mov	edi, 1
.ready:
	mov	[rbx + HexState.codepage_count], edi
	mov	dword [rbx + HexState.charset], 0
	mov	ecx, [rbx + HexState.codepages]
	call	select_codepage
	ret
endp


;--------------------------------------------------------------------- geometry
; Two rows are spoken for: the ruler and the status line. Everything else is
; view, however many rows that is — height carries a minimum and no ceiling.
proc apply_geometry
	locals
		call_align	dq ?
	endl
	mov	dword [rbx + HexState.toosmall], 0
	mov	eax, [rbx + HexState.cols]
	cmp	eax, LAYOUT_COLS
	jl	.too_small
	mov	eax, [rbx + HexState.lines]
	cmp	eax, MIN_LINES
	jl	.too_small
	sub	eax, 2
	mov	[rbx + HexState.viewrows], eax
	call	arena_fit		; may lower viewrows, never raises it
	mov	eax, [rbx + HexState.viewrows]
	shl	eax, 4			; * BPR
	mov	[rbx + HexState.view_cap], eax
	ret
.too_small:
	mov	dword [rbx + HexState.toosmall], 1
	mov	dword [rbx + HexState.viewrows], 1
	mov	dword [rbx + HexState.view_cap], BPR
	ret
endp


; Size the arena for HexState.viewrows and carve it three ways.
;
; This is what "no maximum height" costs: the buffers are a function of the
; window rather than a constant, so a taller window means a larger allocation
; rather than a truncated view. The arena only ever grows, so dragging a window
; taller and shorter again does not churn.
;
; The new allocation is taken before the old one is released — the peak is two
; arenas rather than none, and a failure leaves the program still holding a
; working buffer to report it with.
proc arena_fit
	locals
		need	dq ?
	endl
	mov	eax, [rbx + HexState.viewrows]
	imul	rax, rax, ARENA_PER_ROW
	add	rax, OBUF_SLACK
	mov	[need], rax
	cmp	rax, [rbx + HexState.arena_size]
	jbe	.carve

	VirtualAlloc 0, [need], MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
	test	rax, rax
	jz	.no_room
	mov	rsi, [rbx + HexState.arena]	; the one being replaced
	mov	[rbx + HexState.arena], rax
	mov	rax, [need]
	mov	[rbx + HexState.arena_size], rax
	test	rsi, rsi
	jz	.carve
	VirtualFree rsi, 0, MEM_RELEASE

.carve:	mov	rax, [rbx + HexState.arena]
	mov	[rbx + HexState.obuf], rax
	mov	rdi, rax		; a new arena also starts a new empty frame
	mov	ecx, [rbx + HexState.viewrows]
	imul	rcx, rcx, OBUF_PER_ROW
	add	rcx, OBUF_SLACK
	add	rax, rcx
	mov	[rbx + HexState.view], rax
	mov	ecx, [rbx + HexState.viewrows]
	shl	ecx, 4
	add	rax, rcx
	mov	[rbx + HexState.orig], rax
	ret

	; Out of memory is the only thing that puts a ceiling on the height, and
	; when it does the view is cut to what the arena in hand can hold rather
	; than left describing space that was never allocated.
.no_room:
	mov	rax, [rbx + HexState.arena_size]
	sub	rax, OBUF_SLACK
	mov	ecx, ARENA_PER_ROW
	xor	edx, edx
	div	rcx
	mov	[rbx + HexState.viewrows], eax
.m_room GLOBSTR 'out of memory: view shortened',0
	lea	rax, [.m_room]
	mov	[rbx + HexState.msg], rax
	jmp	.carve
endp


; Take the width. The layout is LAYOUT_COLS wide and can use nothing else, so
; the program sets the console to it rather than reporting that the window is
; wrong. Height is left exactly as the user has it.
;
; A screen buffer may not be narrower than its window, which fixes the order:
; narrow the window before the buffer, widen the buffer before the window.
proc force_width
	locals
		info	CONSOLE_SCREEN_BUFFER_INFO
		rect	SMALL_RECT
		size	dd ?
	endl
	GetConsoleScreenBufferInfo [rbx + HexState.hOutput], &info
	test	eax, eax		; BOOL
	jz	.done

	mov	ax, [info.srWindow.Top]
	mov	[rect.Top], ax
	mov	ax, [info.srWindow.Bottom]
	mov	[rect.Bottom], ax
	mov	word [rect.Left], 0
	mov	word [rect.Right], LAYOUT_COLS - 1

	movzx	eax, word [info.dwSize.Y]	; keep the height, take the width
	shl	eax, 16
	or	eax, LAYOUT_COLS
	mov	[size], eax

	movzx	ecx, word [info.dwSize.X]
	cmp	ecx, LAYOUT_COLS
	jbe	.widen
	SetConsoleWindowInfo [rbx + HexState.hOutput], TRUE, &rect
	mov	eax, [size]
	SetConsoleScreenBufferSize [rbx + HexState.hOutput], eax
	ret
.widen:	mov	eax, [size]
	SetConsoleScreenBufferSize [rbx + HexState.hOutput], eax
	SetConsoleWindowInfo [rbx + HexState.hOutput], TRUE, &rect
.done:	ret
endp


; Give it back, in the mirror order.
proc restore_width
	locals
		rect	SMALL_RECT
		size	dd ?
	endl
	mov	ax, [saved.srWindow.Left]
	mov	[rect.Left], ax
	mov	ax, [saved.srWindow.Top]
	mov	[rect.Top], ax
	mov	ax, [saved.srWindow.Right]
	mov	[rect.Right], ax
	mov	ax, [saved.srWindow.Bottom]
	mov	[rect.Bottom], ax

	movzx	eax, word [saved.dwSize.Y]
	shl	eax, 16
	movzx	ecx, word [saved.dwSize.X]
	or	eax, ecx
	mov	[size], eax

	cmp	ecx, LAYOUT_COLS
	jbe	.narrow
	SetConsoleScreenBufferSize [rbx + HexState.hOutput], eax
	SetConsoleWindowInfo [rbx + HexState.hOutput], TRUE, &rect
	ret
.narrow:
	SetConsoleWindowInfo [rbx + HexState.hOutput], TRUE, &rect
	mov	eax, [size]
	SetConsoleScreenBufferSize [rbx + HexState.hOutput], eax
	ret
endp


; Take the window's extent and its position within the buffer.
;
; WINDOW_BUFFER_SIZE_EVENT reports dwSize, which is the buffer, and a buffer
; can be taller than the window it is shown through — the two coincide in the
; alternate screen buffer, which is the only place this program paints, but
; coinciding by convention is not the same as being the same number. srWindow
; is the thing the layout is actually about, and srWindow.Top is where the
; program's row 1 has to land.
proc read_window
	locals
		info	CONSOLE_SCREEN_BUFFER_INFO
	endl
	GetConsoleScreenBufferInfo [rbx + HexState.hOutput], &info
	test	eax, eax		; BOOL
	jz	.done			; keep whatever the caller had
	movsx	eax, word [info.srWindow.Right]
	movsx	ecx, word [info.srWindow.Left]
	sub	eax, ecx
	inc	eax
	mov	[rbx + HexState.cols], eax
	movsx	eax, word [info.srWindow.Bottom]
	movsx	ecx, word [info.srWindow.Top]
	sub	eax, ecx
	inc	eax
	mov	[rbx + HexState.lines], eax
	movsx	eax, word [info.srWindow.Top]
	mov	[rbx + HexState.row0], eax
.done:	ret
endp


; The first size event is startup; every later one is a resize. Same path.
proc on_resize
	locals
		old_cap		dd ?
		new_cap		dd ?
		next		dq ?
		change_off	dq ?
		span		dd ?
		saved		dq ?
	endl
	; The event's dwSize is the fallback; read_window replaces it whenever
	; the console will say what the window is.
	movsx	eax, word [rbp + IREC_WINDOW_X]
	mov	[rbx + HexState.cols], eax
	movsx	eax, word [rbp + IREC_WINDOW_Y]
	mov	[rbx + HexState.lines], eax
	mov	dword [rbx + HexState.row0], 0
	call	read_window

	; Width is the program's, so a window that is not LAYOUT_COLS wide gets
	; set rather than refused. Asking twice for a width the host already
	; declined would spin — a terminal that owns its own size reasserts it
	; and the two would trade resizes forever — so each width is attempted
	; once. If the attempt does not take, a wider window is simply used from
	; its left edge, and only a narrower one is reported as too small.
	mov	eax, [rbx + HexState.cols]
	cmp	eax, LAYOUT_COLS
	jz	.width_taken
	cmp	eax, [rbx + HexState.fix_cols]
	jz	.width_settled
	mov	[rbx + HexState.fix_cols], eax
	mov	edx, [rbx + HexState.lines]
	mov	ecx, LAYOUT_COLS
	call	vt_resize
	call	force_width		; legacy path, for a host without XTWINOPS

	; Continue from the size the console actually ended up with rather than
	; waiting for the event this resize raises — that event will find the
	; width already settled and fall through without changing anything.
	call	read_window
	jmp	.width_settled
.width_taken:
	mov	dword [rbx + HexState.fix_cols], 0
.width_settled:

	; A resize can proceed with pending changes when the new view still
	; contains their complete absolute span. Save that span outside the arena
	; because apply_geometry may move and release the arena, then reload and
	; reapply it at its rebased index. A smaller view that would exclude a
	; changed byte still has to ask; the resize itself cannot be cancelled.
	cmp	dword [rbx + HexState.chg_lo], 0
	js	.apply
	cmp	dword [rbx + HexState.cols], LAYOUT_COLS
	jl	.prompt
	cmp	dword [rbx + HexState.lines], MIN_LINES
	jl	.prompt

	mov	eax, [rbx + HexState.lines]
	sub	eax, 2
	shl	eax, 4
	mov	[new_cap], eax
	mov	eax, [rbx + HexState.view_cap]
	mov	[old_cap], eax
	mov	eax, [new_cap]
	mov	[rbx + HexState.view_cap], eax
	mov	rax, [rbx + HexState.view_off]
	call	view_clamped
	mov	[next], rax
	mov	eax, [old_cap]
	mov	[rbx + HexState.view_cap], eax

	mov	eax, [rbx + HexState.chg_lo]
	add	rax, [rbx + HexState.view_off]
	mov	[change_off], rax
	cmp	rax, [next]
	jb	.prompt
	mov	eax, [rbx + HexState.chg_hi]
	add	rax, [rbx + HexState.view_off]
	mov	rcx, [next]
	mov	edx, [new_cap]
	add	rcx, rdx
	cmp	rax, rcx
	jnc	.prompt

	mov	ecx, [rbx + HexState.chg_hi]
	sub	ecx, [rbx + HexState.chg_lo]
	inc	ecx
	mov	[span], ecx
	VirtualAlloc 0, [span], MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE
	test	rax, rax
	jz	.prompt
	mov	[saved], rax
	mov	r10, [rbx + HexState.view]
	mov	edx, [rbx + HexState.chg_lo]
	add	r10, rdx
	mov	r11, rax
	mov	ecx, [span]
.save:	mov	al, [r10]
	mov	[r11], al
	inc	r10
	inc	r11
	dec	ecx
	jnz	.save

	call	apply_geometry

	; A growth allocation can fail, in which case arena_fit falls back to the
	; largest geometry the existing arena can hold. Validate that actual
	; geometry before touching its newly carved view. If it no longer contains
	; the pending span, restore the old carving (the failed allocation left
	; that arena alive) and keep the resize behind the forced prompt.
	mov	rax, [rbx + HexState.view_off]
	call	view_clamped
	mov	[next], rax
	cmp	[change_off], rax
	jb	.retain_failed
	mov	rax, [change_off]
	mov	edx, [span]
	add	rax, rdx
	dec	rax
	mov	rcx, [next]
	mov	edx, [rbx + HexState.view_cap]
	add	rcx, rdx
	cmp	rax, rcx
	jnc	.retain_failed

	call	view_load
	mov	rax, [change_off]
	sub	rax, [rbx + HexState.view_off]
	mov	r10, [saved]
	mov	r11, [rbx + HexState.view]
	add	r11, rax
	mov	ecx, [span]
.reapply:
	mov	al, [r10]
	mov	[r11], al
	inc	r10
	inc	r11
	dec	ecx
	jnz	.reapply
	call	view_rescan
	VirtualFree [saved], 0, MEM_RELEASE

	; A later resize may make a previously forced resize fit. It has now been
	; honoured without discarding anything, so that question is no longer
	; pending.
	cmp	dword [rbx + HexState.prompt], PROMPT_FORCED
	jnz	.retained
	cmp	dword [rbx + HexState.pend_act], NAV_RESIZE
	jnz	.retained
	mov	dword [rbx + HexState.prompt], PROMPT_NONE
	mov	dword [rbx + HexState.pend_act], NAV_NONE
	mov	qword [rbx + HexState.msg], 0
.retained:
	call	paint_full
	ret

.retain_failed:
	mov	eax, [old_cap]
	shr	eax, 4
	mov	[rbx + HexState.viewrows], eax
	mov	eax, [old_cap]
	mov	[rbx + HexState.view_cap], eax
	call	arena_fit
	VirtualFree [saved], 0, MEM_RELEASE

.prompt:
	mov	dword [rbx + HexState.prompt], PROMPT_FORCED
	mov	dword [rbx + HexState.pend_act], NAV_RESIZE
	call	paint_pending
	ret
.apply:
	mov	ecx, NAV_RESIZE
	xor	edx, edx
	xor	r8d, r8d
	call	nav_perform
	ret
endp


;------------------------------------------------------------------- navigation
; ECX = action, RDX = argument. Either performs it now or holds it behind the
; prompt. Every change of view_off in the program comes through here — that is
; what makes the guarantee checkable rather than a habit.
proc nav_request
	locals
		act	dd ?
		arg	dq ?
		next	dq ?
	endl
	mov	[act], ecx
	mov	[arg], rdx

	; Resolve every view-moving request before it can become a question. A
	; clamp that leaves the view where it is has nothing to ask or perform.
	cmp	ecx, NAV_SCROLL
	jz	.scroll
	cmp	ecx, NAV_GOTO
	jnz	.gate
	mov	rax, rdx
	jmp	.clamp
.scroll:
	movsxd	rax, dword [arg]
	shl	rax, 4
	add	rax, [rbx + HexState.view_off]
.clamp:
	call	view_clamped
	mov	[next], rax
	cmp	rax, [rbx + HexState.view_off]
	jz	.nothing

.gate:	cmp	dword [rbx + HexState.chg_lo], 0
	js	.fresh

	; A scroll or goto can proceed without a prompt when its destination still
	; contains the complete absolute change span. view_retain reloads the new
	; range and reapplies that span before painting it.
	mov	eax, [act]
	cmp	eax, NAV_SCROLL
	jz	.contains
	cmp	eax, NAV_GOTO
	jnz	.prompt
.contains:
	mov	eax, [rbx + HexState.chg_lo]
	add	rax, [rbx + HexState.view_off]
	cmp	rax, [next]
	jb	.prompt
	mov	eax, [rbx + HexState.chg_hi]
	add	rax, [rbx + HexState.view_off]
	mov	rcx, [next]
	mov	edx, [rbx + HexState.view_cap]
	add	rcx, rdx
	cmp	rax, rcx
	jnc	.prompt
	mov	r8d, VIEW_RETAIN
	jmp	.perform

.prompt:
	mov	eax, [act]
	mov	[rbx + HexState.pend_act], eax
	mov	rax, [arg]
	mov	[rbx + HexState.pend_arg], rax
	mov	dword [rbx + HexState.prompt], PROMPT_NAV
	mov	qword [rbx + HexState.msg], 0
	call	paint_status
	ret

.fresh:
	xor	r8d, r8d
.perform:
	mov	ecx, [act]
	mov	rdx, [arg]
	fastcall nav_perform
.nothing:
	ret
endp


; ECX = action, RDX = argument, R8D = VIEW_* acquisition/paint mode.
proc nav_perform
	locals
		act	dd ?
		arg	dq ?
		delta	dd ?
		mode	dd ?
	endl
	mov	[act], ecx
	mov	[arg], rdx
	mov	[mode], r8d

	cmp	ecx, NAV_QUIT
	jz	.quit
	cmp	ecx, NAV_RESIZE
	jz	.resize
	cmp	ecx, NAV_GOTO
	jz	.goto

	; NAV_SCROLL. The rows the terminal can move for us are the whole point:
	; ask it to scroll the region, then draw only what that exposed.
	movsxd	rax, dword [arg]
	shl	rax, 4
	add	rax, [rbx + HexState.view_off]
	call	view_clamped
	mov	rcx, rax
	sub	rcx, [rbx + HexState.view_off]
	jz	.done
	sar	rcx, 4
	mov	[delta], ecx
	cmp	dword [mode], VIEW_RETAIN
	jz	.retain_scroll
	mov	[rbx + HexState.view_off], rax
	call	view_load
	jmp	.paint_scroll
.retain_scroll:
	call	view_retain
.paint_scroll:
	cmp	dword [mode], VIEW_REPAINT
	jz	.repaint

	mov	eax, [delta]
	cdq
	xor	eax, edx
	sub	eax, edx		; |delta|
	cmp	eax, [rbx + HexState.viewrows]
	jnc	.repaint
	mov	ecx, [delta]
	call	paint_scroll
	ret

.goto:	mov	rax, [arg]
	call	view_clamped
	cmp	dword [mode], VIEW_RETAIN
	jz	.retain_goto
	mov	[rbx + HexState.view_off], rax
	call	view_load
	jmp	.repaint
.retain_goto:
	call	view_retain
	jmp	.repaint

.resize:
	call	apply_geometry
	call	view_load
.repaint:
	call	paint_full
.done:	ret

	; The wait in the main loop is already watching for this, so quitting is
	; the same event a Ctrl+Break raises and needs no second mechanism.
.quit:	SetEvent [rbx + HexState.hQuit]
	ret
endp


;---------------------------------------------------------------------- keys
proc on_key_down
	locals
		oldcur	dd ?
		row_lo	dd ?
		row_hi	dd ?
		call_align	dq ?
	endl
	mov	qword [rbx + HexState.msg], 0
	mov	eax, [rbx + HexState.cur]
	mov	[oldcur], eax

	movzx	eax, word [rbp + IREC_KEY_VK]
	iterate <vk,handler>,\
		VK_LEFT,	.left,\
		VK_RIGHT,	.right,\
		VK_UP,		.up,\
		VK_DOWN,	.down,\
		VK_PRIOR,	.page_up,\
		VK_NEXT,	.page_down,\
		VK_HOME,	.home,\
		VK_END,		.end,\
		VK_TAB,		.pane,\
		VK_F2,		.write,\
		VK_F3,		.charset,\
		VK_F5,		.restore

		cmp	eax, vk
		jz	handler
	end iterate
	jmp	.typed

;   Cursor motion inside the view. Left and right stop at the ends rather than
;   pulling the view along: an arrow key should not be able to raise a question
;   about unwritten data.
.left:	mov	eax, [rbx + HexState.cur]
	test	eax, eax
	jz	.nothing
	dec	eax
	jmp	.set_cursor

.right:	mov	eax, [rbx + HexState.cur]
	inc	eax
	cmp	eax, [rbx + HexState.view_bytes]
	jnc	.nothing
	jmp	.set_cursor

;   Up and down do pull the view, because that is what they are for. The cursor
;   index is unchanged across a one-row scroll: the content moves under it and
;   it stays in the same screen row and column.
.up:	mov	eax, [rbx + HexState.cur]
	cmp	eax, BPR
	jc	.scroll_back
	sub	eax, BPR
	jmp	.set_cursor
.scroll_back:
	mov	ecx, NAV_SCROLL
	mov	edx, -1
	call	nav_request
	ret

.down:	mov	eax, [rbx + HexState.cur]
	add	eax, BPR
	cmp	eax, [rbx + HexState.view_bytes]
	jnc	.scroll_forward
	jmp	.set_cursor
.scroll_forward:
	mov	ecx, NAV_SCROLL
	mov	edx, 1
	call	nav_request
	ret

.page_up:
	mov	ecx, NAV_SCROLL
	mov	edx, [rbx + HexState.viewrows]
	neg	edx
	call	nav_request
	ret

.page_down:
	mov	ecx, NAV_SCROLL
	mov	edx, [rbx + HexState.viewrows]
	call	nav_request
	ret

.home:	mov	edx, [rbp + IREC_KEY_CONTROL]
	test	edx, LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED
	jz	.row_start
	mov	ecx, NAV_GOTO
	xor	edx, edx
	call	nav_request
	ret
.row_start:
	mov	eax, [rbx + HexState.cur]
	and	eax, not (BPR-1)
	jmp	.set_cursor

.end:	mov	edx, [rbp + IREC_KEY_CONTROL]
	test	edx, LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED
	jz	.row_end
	mov	ecx, NAV_GOTO
	mov	rdx, [rbx + HexState.file_size]
	call	nav_request		; the clamp pins it to the last page
	ret
.row_end:
	mov	eax, [rbx + HexState.cur]
	or	eax, BPR-1
	cmp	eax, [rbx + HexState.view_bytes]
	jc	.set_cursor
	mov	eax, [rbx + HexState.view_bytes]
	test	eax, eax
	jz	.nothing
	dec	eax
	jmp	.set_cursor

.set_cursor:
	mov	[rbx + HexState.cur], eax
	mov	dword [rbx + HexState.nibble], 0
.moved:	mov	ecx, [oldcur]
	call	paint_cells
	ret

.nothing:
	ret

;   Pane and file commands.
.pane:	mov	eax, [rbx + HexState.pane]
	xor	eax, PANE_ASCII
	mov	[rbx + HexState.pane], eax
	mov	dword [rbx + HexState.nibble], 0
	call	paint_status		; which also re-parks the cursor
	ret

;   A character set is the one setting that changes every cell on screen, so it
;   is also the one that has earned a full repaint.
.charset:
	mov	eax, [rbx + HexState.charset]
	inc	eax
	cmp	eax, [rbx + HexState.codepage_count]
	jc	.set_charset
	xor	eax, eax
.set_charset:
	mov	[rbx + HexState.charset], eax
	mov	ecx, [rbx + HexState.codepages + rax*4]
	call	select_codepage
	call	paint_full
	ret

;   A write or a restore takes the highlight off exactly the rows that carried
;   changes, so those are the rows that get redrawn.
.write:	mov	eax, [rbx + HexState.chg_lo]
	mov	[row_lo], eax
	mov	eax, [rbx + HexState.chg_hi]
	mov	[row_hi], eax
	call	view_commit
	jmp	.changed_rows

.restore:
	mov	eax, [rbx + HexState.chg_lo]
	mov	[row_lo], eax
	mov	eax, [rbx + HexState.chg_hi]
	mov	[row_hi], eax
	call	view_restore

.changed_rows:
	mov	ecx, [row_lo]
	test	ecx, ecx
	js	.status_only
	mov	edx, [row_hi]
	shr	ecx, 4
	shr	edx, 4
	call	paint_rows
	ret
.status_only:
	call	paint_status
	ret

;--------------------------------------------------------------- data entry
;   Everything above this point moves; only what follows can change a byte.
.typed:	mov	ecx, [rbp + IREC_KEY_CONTROL]
	test	ecx, LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED\
		or LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED
	jnz	.nothing		; a chord is a command, never data
	cmp	dword [rbx + HexState.readonly], 0
	jnz	.refuse
	mov	ecx, [rbx + HexState.cur]
	cmp	ecx, [rbx + HexState.view_bytes]
	jnc	.nothing		; past end of file; the file never grows
	movzx	eax, word [rbp + IREC_KEY_CHAR]
	test	eax, eax
	jz	.nothing
	cmp	dword [rbx + HexState.pane], PANE_ASCII
	jz	.ascii_entry

	call	hex_value
	jc	.nothing
	mov	rsi, [rbx + HexState.view]
	movzx	edx, byte [rsi + rcx]
	cmp	dword [rbx + HexState.nibble], 0
	jnz	.low_nibble
	shl	eax, 4
	and	edx, 0x0F
	or	eax, edx
	mov	[rsi + rcx], al
	mov	dword [rbx + HexState.nibble], 1
	jmp	.edited
.low_nibble:
	and	edx, 0xF0
	or	eax, edx
	mov	[rsi + rcx], al
	mov	dword [rbx + HexState.nibble], 0
	jmp	.advance

.ascii_entry:
	cmp	eax, 0x20
	jc	.nothing
	cmp	eax, 0x7F
	jnc	.nothing
	mov	rsi, [rbx + HexState.view]
	mov	[rsi + rcx], al

;   Advance, but never off the view: typing is not navigation and must not be
;   able to raise the prompt.
.advance:
	inc	ecx
	cmp	ecx, [rbx + HexState.view_bytes]
	jnc	.edited
	mov	[rbx + HexState.cur], ecx

.edited:
	call	view_rescan
	; The byte that changed is either where the cursor was or where it is,
	; so the two-cell repaint covers it.
	mov	ecx, [oldcur]
	call	paint_cells
	ret

.refuse:
.m_ro GLOBSTR 'read-only',0
	lea	rax, [.m_ro]
	mov	[rbx + HexState.msg], rax
	call	paint_status
	ret
endp


; EAX = character -> EAX = 0..15 with CF clear, or CF set if it is not a hex
; digit. A leaf: no frame, no calls.
hex_value:
	cmp	eax, '0'
	jc	.no
	cmp	eax, '9'+1
	jc	.digit
	or	eax, 0x20		; fold case
	cmp	eax, 'a'
	jc	.no
	cmp	eax, 'f'+1
	jnc	.no
	sub	eax, 'a'-10
	clc
	retn
.digit:	sub	eax, '0'
	clc
	retn
.no:	stc
	retn


; Only W and R answer. Anything else is ignored rather than guessed at, and
; Esc — which cancels a navigation prompt — is handled on release in the main
; loop so that a forced prompt simply has no escape.
proc on_prompt_key
	locals
		call_align	dq ?
	endl
	movzx	eax, word [rbp + IREC_KEY_CHAR]
	or	eax, 0x20
	cmp	eax, 'w'
	jz	.write
	cmp	eax, 'r'
	jz	.restore
	ret

.write:	call	view_commit
	test	eax, eax
	jnz	.resume
	call	paint_status		; the note says why it did not
	ret

.restore:
	call	view_restore

.resume:
	mov	dword [rbx + HexState.prompt], PROMPT_NONE
	mov	ecx, [rbx + HexState.pend_act]
	mov	rdx, [rbx + HexState.pend_arg]
	mov	dword [rbx + HexState.pend_act], NAV_NONE
	mov	r8d, VIEW_REPAINT
	call	nav_perform
	ret
endp


;--------------------------------------------------------------------- mouse
proc on_mouse
	locals
		call_align	dq ?
	endl
	mov	eax, [rbp + IREC_MOUSE_FLAGS]
	test	eax, MOUSE_WHEELED
	jnz	.wheel
	test	eax, MOUSE_MOVED
	jnz	.done			; thin the stream: movement changes nothing
	test	dword [rbp + IREC_MOUSE_BUTTONS],\
		FROM_LEFT_1ST_BUTTON_PRESSED
	jz	.done
	call	on_click
.done:	ret

	; The wheel delta is the high half of dwButtonState, signed. Forward is
	; positive and means earlier in the file.
.wheel:	mov	eax, [rbp + IREC_MOUSE_BUTTONS]
	sar	eax, 16
	mov	ecx, NAV_SCROLL
	mov	edx, -3
	test	eax, eax
	jns	.scroll
	neg	edx
.scroll:
	call	nav_request
	ret
endp


; Placing the cursor is motion inside the view, so it needs no permission and
; costs the same two cells an arrow key does. Buffer coordinates are 0-based
; where VT rows and columns are 1-based.
proc on_click
	locals
		call_align	dq ?
	endl
	; Mouse coordinates are buffer rows, and the window may not start at the
	; top of the buffer.
	movsx	eax, word [rbp + IREC_MOUSE_Y]
	sub	eax, [rbx + HexState.row0]
	sub	eax, DATA_ROW0 - 1
	js	.done
	cmp	eax, [rbx + HexState.viewrows]
	jnc	.done
	mov	r8d, eax

	movsx	eax, word [rbp + IREC_MOUSE_X]
	inc	eax
	cmp	eax, ASCII_COL0
	jc	.hex_pane
	sub	eax, ASCII_COL0
	cmp	eax, BPR
	jnc	.done
	mov	edx, eax
	mov	dword [rbx + HexState.pane], PANE_ASCII
	jmp	.place

.hex_pane:
	sub	eax, HEX_COL0
	js	.done
	cmp	eax, GROUP*3
	jc	.ungapped
	dec	eax			; undo the group gap
.ungapped:
	xor	edx, edx
	mov	ecx, 3
	div	ecx
	cmp	eax, BPR
	jnc	.done
	mov	edx, eax
	mov	dword [rbx + HexState.pane], PANE_HEX

.place:	mov	eax, r8d
	shl	eax, 4
	add	eax, edx
	cmp	eax, [rbx + HexState.view_bytes]
	jnc	.done
	mov	ecx, [rbx + HexState.cur]
	mov	[rbx + HexState.cur], eax
	mov	dword [rbx + HexState.nibble], 0
	mov	qword [rbx + HexState.msg], 0
	call	paint_cells
.done:	ret
endp


;------------------------------------------------------------------------------
; Subsystem 10.0 takes the modern normal-launch path through the loader, which
; requires a valid Load Configuration Directory. There is no stack cookie or
; CFG instrumentation in this no-CRT image, so the legacy prefix through
; GuardFlags is the complete truthful structure and says the cookie is unused.

IMAGE_GUARD_SECURITY_COOKIE_UNUSED := 00000800h

section '.rdata$loadcfg' data readable align 8

_load_config_used:
	dd	.end - _load_config_used	; Size
	dd	0				; TimeDateStamp
	dw	0,0				; MajorVersion, MinorVersion
	dd	0				; GlobalFlagsClear
	dd	0				; GlobalFlagsSet
	dd	0				; CriticalSectionDefaultTimeout
	dq	0				; DeCommitFreeBlockThreshold
	dq	0				; DeCommitTotalFreeThreshold
	dq	0				; LockPrefixTable
	dq	0				; MaximumAllocationSize
	dq	0				; VirtualMemoryThreshold
	dq	0				; ProcessAffinityMask
	dd	0				; ProcessHeapFlags
	dw	0				; CSDVersion
	dw	0				; DependentLoadFlags
	dq	0				; EditList
	dq	0				; SecurityCookie VA
	dq	0				; SEHandlerTable
	dq	0				; SEHandlerCount
	dq	0				; GuardCFCheckFunctionPointer
	dq	0				; GuardCFDispatchFunctionPointer
	dq	0				; GuardCFFunctionTable
	dq	0				; GuardCFFunctionCount
	dd	IMAGE_GUARD_SECURITY_COOKIE_UNUSED
.end:
	assert	.end - _load_config_used = 148


; The linker options travel with the code that depends on them. Object files
; stay in the makefile: build dependencies belong there.

virtual as "response"
	db '/NOLOGO',10
	db '/NODEFAULTLIB',10

; Create unique binary using image version and checksum:
	db '/RELEASE',10		; set program checksum in header
repeat 1,T:__TIME__ shr 16,t:__TIME__ and 0xFFFF
	db '/VERSION:',`T,'.',`t,10	; time based binary version
end repeat

	db '/DYNAMICBASE',10
	db '/SUBSYSTEM:CONSOLE,10.0',10
	db 'kernel32.lib',10
end virtual
