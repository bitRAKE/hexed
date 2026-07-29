; Short spellings for projection values.
;
; The projection's symbol space is vertical and unambiguous —
; `win32.CONSOLE_MODE.ENABLE_VIRTUAL_TERMINAL_PROCESSING` — and a console mode
; is built from four of those OR'd together, which no longer fits a line, let
; alone a readable one. Contracts transform a single symbolic operand into its
; enum namespace; a compound expression cannot be transformed at all. So every
; value used in an expression is spelled in full somewhere, and this is the
; somewhere: an assemble-time alias, no data, no indirection.
;
; Universal names live here. Names used by exactly one module belong in that
; module and move here when a second module needs them.

if ~ definite HEXED_NAMES_INCLUDED
HEXED_NAMES_INCLUDED := 1

macro win32names? table&
	iterate <short,qualified>, table
		short = qualified
	end iterate
end macro

win32names \
	FALSE,			win32.BOOL.FALSE,\
	TRUE,			win32.BOOL.TRUE,\
	INVALID_HANDLE_VALUE,	win32.constant.Foundation.INVALID_HANDLE_VALUE,\
\	; standard handles
	STD_INPUT_HANDLE,	win32.STD_HANDLE.STD_INPUT_HANDLE,\
	STD_OUTPUT_HANDLE,	win32.STD_HANDLE.STD_OUTPUT_HANDLE,\
\	; console modes. ENABLE_EXTENDED_FLAGS is what makes the input mode
\	; assignment authoritative rather than merged with the user's defaults,
\	; and dropping ENABLE_QUICK_EDIT_MODE with it is what delivers mouse
\	; input instead of a selection rectangle.
	ENABLE_WINDOW_INPUT,	win32.CONSOLE_MODE.ENABLE_WINDOW_INPUT,\
	ENABLE_MOUSE_INPUT,	win32.CONSOLE_MODE.ENABLE_MOUSE_INPUT,\
	ENABLE_EXTENDED_FLAGS,	win32.CONSOLE_MODE.ENABLE_EXTENDED_FLAGS,\
	ENABLE_PROCESSED_OUTPUT, win32.CONSOLE_MODE.ENABLE_PROCESSED_OUTPUT,\
	ENABLE_VIRTUAL_TERMINAL_PROCESSING,\
		win32.CONSOLE_MODE.ENABLE_VIRTUAL_TERMINAL_PROCESSING,\
\	; input record discrimination
	KEY_EVENT,		win32.constant.System_Console.KEY_EVENT,\
	MOUSE_EVENT,		win32.constant.System_Console.MOUSE_EVENT,\
	WINDOW_BUFFER_SIZE_EVENT,\
		win32.constant.System_Console.WINDOW_BUFFER_SIZE_EVENT,\
	MOUSE_MOVED,		win32.constant.System_Console.MOUSE_MOVED,\
	MOUSE_WHEELED,		win32.constant.System_Console.MOUSE_WHEELED,\
	FROM_LEFT_1ST_BUTTON_PRESSED,\
		win32.constant.System_Console.FROM_LEFT_1ST_BUTTON_PRESSED,\
	LEFT_CTRL_PRESSED,	win32.constant.System_Console.LEFT_CTRL_PRESSED,\
	RIGHT_CTRL_PRESSED,	win32.constant.System_Console.RIGHT_CTRL_PRESSED,\
	LEFT_ALT_PRESSED,	win32.constant.System_Console.LEFT_ALT_PRESSED,\
	RIGHT_ALT_PRESSED,	win32.constant.System_Console.RIGHT_ALT_PRESSED,\
\	; virtual keys the editor dispatches on
	VK_TAB,			win32.VIRTUAL_KEY.VK_TAB,\
	VK_ESCAPE,		win32.VIRTUAL_KEY.VK_ESCAPE,\
	VK_PRIOR,		win32.VIRTUAL_KEY.VK_PRIOR,\
	VK_NEXT,		win32.VIRTUAL_KEY.VK_NEXT,\
	VK_END,			win32.VIRTUAL_KEY.VK_END,\
	VK_HOME,		win32.VIRTUAL_KEY.VK_HOME,\
	VK_LEFT,		win32.VIRTUAL_KEY.VK_LEFT,\
	VK_UP,			win32.VIRTUAL_KEY.VK_UP,\
	VK_RIGHT,		win32.VIRTUAL_KEY.VK_RIGHT,\
	VK_DOWN,		win32.VIRTUAL_KEY.VK_DOWN,\
	VK_F2,			win32.VIRTUAL_KEY.VK_F2,\
	VK_F3,			win32.VIRTUAL_KEY.VK_F3,\
	VK_F5,			win32.VIRTUAL_KEY.VK_F5,\
\	; UTF-8 out, so the right-hand pane can draw more than ASCII
	CP_UTF8,		win32.constant.Globalization.CP_UTF8,\
	MB_ERR_INVALID_CHARS,	win32.MULTI_BYTE_TO_WIDE_CHAR_FLAGS.MB_ERR_INVALID_CHARS,\
	MB_USEGLYPHCHARS,	win32.MULTI_BYTE_TO_WIDE_CHAR_FLAGS.MB_USEGLYPHCHARS,\
\	; file and memory
	GENERIC_READ,		win32.constant.System_SystemServices.GENERIC_READ,\
	GENERIC_WRITE,		win32.constant.System_SystemServices.GENERIC_WRITE,\
	FILE_SHARE_READ,	win32.FILE_SHARE_MODE.FILE_SHARE_READ,\
	FILE_SHARE_WRITE,	win32.FILE_SHARE_MODE.FILE_SHARE_WRITE,\
	OPEN_EXISTING,		win32.FILE_CREATION_DISPOSITION.OPEN_EXISTING,\
	FILE_ATTRIBUTE_NORMAL,	win32.FILE_FLAGS_AND_ATTRIBUTES.FILE_ATTRIBUTE_NORMAL,\
	FILE_BEGIN,		win32.SET_FILE_POINTER_MOVE_METHOD.FILE_BEGIN,\
	MEM_COMMIT,		win32.VIRTUAL_ALLOCATION_TYPE.MEM_COMMIT,\
	MEM_RESERVE,		win32.VIRTUAL_ALLOCATION_TYPE.MEM_RESERVE,\
	MEM_RELEASE,		win32.VIRTUAL_FREE_TYPE.MEM_RELEASE,\
	PAGE_READWRITE,		win32.PAGE_PROTECTION_FLAGS.PAGE_READWRITE,\
	WAIT_OBJECT_0,		win32.WIN32_ERROR.WAIT_OBJECT_0

end if
