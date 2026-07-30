# Developing hexed

This document covers the build, implementation contracts, binary-format
requirements, and verification history. See [README.md](README.md) for usage.

## Build

The build trajectory is:

```text
fasmg -> MS64 NEWCOFF bigobj -> link -> PE64
```

The resulting executable is 12,288 bytes and imports only `kernel32`.

Run from an x64 Visual Studio developer prompt so `link.exe` and the Windows SDK
libraries are on `PATH`:

```cmd
VsDevCmd.bat -arch=amd64 -host_arch=amd64
nmake
nmake verify
nmake clean
```

`fasmg.exe` is driven directly rather than through `fasm2.cmd`. The wrapper
pre-includes `fasm2.inc`, which already carries `dd`, `align`, `format`, and
`x86-2`; [`common/policy.g`](common/policy.g) includes those itself.

[`hexed.asm`](hexed.asm) emits the linker response through
`virtual as "response"`, keeping executable policy beside the code that depends
on it. Object membership and dependencies remain in the makefile.

`nmake verify` emits header, import, unwind, and disassembly information for
manual inspection. Generated objects, response files, and disassembly output are
ignored by Git.

## Repository layout

```text
hexed/
  .gitattributes        line-ending, binary, and source-language handling
  .gitignore            assembler, linker, debugger, and IDE byproducts
  README.md             user documentation
  DEVELOPING.md         this document
  makefile              fasmg, link, and inspection trajectory
  hexed.h               geometry, HexState, and cross-object contracts
  hexed.asm             entry, console lifetime, event loop, input and response
  view.asm              view load, commit, restore, rescan, and clamp
  paint.asm             VT composition and rendering
  common/
    policy.g            NEWCOFF, projection, PROC, unwind, and debug policy
    names.g             short spellings for projected values
    data_blocks.g       pooled CONST, DATA, and BSS gatherers
    vt.g                pooled `<| ... |>` output-fragment notation
```

## State and edit invariants

The visible view is the complete editable surface. Three rules enforce that:

1. Typing writes `view[cur]`, and `cur` is clamped to
   `[0, view_bytes)`.
2. `view_rescan` compares `view` with `orig` after every edit and records the
   first and last differing byte.
3. Every change of `view_off` passes through `nav_request`. It permits an
   overlapping destination only when the complete absolute change span remains
   visible; otherwise it defers the request behind the prompt.

`view_commit` writes the smallest continuous span containing every difference:

```text
view_off + chg_lo .. view_off + chg_hi
```

Unchanged bytes between separated edits may be rewritten with their existing
values. Nothing before `chg_lo`, after `chg_hi`, or outside the current view is
touched. The write is followed by `FlushFileBuffers`.

Clean navigation uses `view_load` directly. Overlapping navigation with pending
changes uses `view_retain`: the changed span is copied into the empty output
buffer, the destination view and baseline are reloaded, and the span is
reapplied at its new index before `view_rescan`. No shadow document or dirty
bitmap is needed.

Resize follows the same containment rule, but cannot use arena-local scratch
because `arena_fit` may replace the arena. It saves the changed span in a
temporary allocation, applies geometry, reloads, reapplies, and frees the
temporary block. The span is checked again against `arena_fit`'s actual
geometry, including its allocation-failure fallback. A resize that would
exclude any changed byte remains a forced prompt.

Ctrl and Alt chords are rejected by the data-entry path. The character pane
accepts only printable ASCII; the hexadecimal pane provides the full byte range.

## Application-thread register contract

The entry point never returns, and ordinary internal work remains on one thread:

```text
RBX = &hex, for the process lifetime
RBP = &irec, for the event loop lifetime
RDI = next byte in the output buffer
RSI = source and scan cursor
```

Internal procedures do not save registers already owned by the application
thread. Win64 preserves the nonvolatile set across API calls.

`ConsoleCtrlHandler` is the exception. Windows may invoke it on another thread
with unrelated register contents, so it uses the absolute `hex` object and none
of the application-thread register state.

Procedures that execute an ABI call have an aligned static-RSP frame. Output
builders call only private leaves and require no ABI call frame. The `emit_*`
leaves have no frame or unwindable state.

## Output architecture

### One event, one write

Painting routines append to a shared buffer through `RDI` and return without
writing. The event loop drains `[obuf,RDI)` once after a completed input event
and resets `RDI` to `obuf`.

`vt_resize` is the sole mid-event drain. Its XTWINOPS request must reach the
terminal before the legacy resize fallback and size readback execute.

The output region is sized as:

```text
viewrows * OBUF_PER_ROW + OBUF_SLACK
```

`OBUF_PER_ROW` covers the pathological per-row rendering cost; the slack covers
the ruler, footer, prompts, setup, and teardown. A normal event composes at most
one complete frame between drains.

### Damage-sized painters

| Entry point | Work | Used for |
| --- | --- | --- |
| `paint_cells` | two byte cells and the footer | cursor movement and typing |
| `paint_scroll` | one `SU`/`SD`, exposed rows, two cells | short scrolling |
| `paint_rows` | an inclusive row range and footer | write or restore |
| `paint_status` | footer only | pane changes and messages |
| `paint_full` | complete screen | resize, page movement, goto, code page |

Scrolling uses `DECSTBM` over only the data rows. The terminal moves the address
column with its data, and only newly exposed rows are rendered. Scrolling also
moves the highlighted cursor cell; repainting `cur - delta*BPR` and `cur`
removes the stale highlight and draws the new one.

`emit_attr` tracks the active SGR class and emits only when the class changes.
Every emitted class begins from SGR 0, so classes do not depend on an unwind
order. The terminal's real cursor is parked on the selected nibble or character
at frame end.

### Footer and exit summary

The footer is reverse-video across the complete logical width. It is padded
explicitly because `ESC[K` erases using colours, while reverse video is an
attribute and would end with the text.

The alternate screen is removed on exit, so `vt_summary` writes one persistent
line to the restored main screen describing bytes written and any pending bytes
discarded by Ctrl+Break or console close.

## Character mapping

Startup captures the console output code page before switching output transport
to UTF-8. `init_codepages` prepends that page when it is an SBCS, then appends
the favourites in `HEXED_CODEPAGES`, omitting unavailable, multibyte, and
duplicate entries.

`GetCPInfoExW` validates each candidate. `MultiByteToWideChar` with
`MB_USEGLYPHCHARS` builds the complete 256-entry Unicode map; there is no
embedded CP437 table. Rejected mappings and Unicode C0/C1 controls render as
attribute-marked dots. Valid characters are encoded as UTF-8 for the terminal.

## Geometry and console lifetime

The layout is 76 columns and sixteen bytes per row. Width is taken while the
program runs and restored on exit; height has a four-line minimum and no fixed
maximum.

The modern path is XTWINOPS:

```text
CSI 8 ; rows ; cols t
```

`SetConsoleWindowInfo` and `SetConsoleScreenBufferSize` remain as the legacy
fallback. Under ConPTY they affect the pseudoconsole buffer, not the terminal's
own window. `GetConsoleWindow` is not useful there either: it identifies a
hidden zero-sized `PseudoConsoleWindow`, so adding a user32 dependency would not
provide a working resize path.

If a host declines the requested width, it is asked only once to avoid an event
loop in which the host and application repeatedly reassert different sizes. A
wider window is used from the left; a narrower one produces the size warning.

The arena grows with `viewrows` and is carved into output, `view`, and `orig`
regions. It never shrinks, avoiding allocation churn during resize. On
allocation failure, the view is shortened to the capacity already available.

Nothing is painted until the first `WINDOW_BUFFER_SIZE_EVENT` after alternate
screen activation. Startup and subsequent resize therefore share the same
geometry, load, and repaint path. The event's buffer size is only a fallback;
`read_window` prefers `srWindow` and retains its top-row origin for cursor
placement.

## PE and NEWCOFF policy

### Release-oriented PE header

The emitted linker response selects:

```text
/NODEFAULTLIB
/DYNAMICBASE
/SUBSYSTEM:CONSOLE,10.0
kernel32.lib
```

The linked image uses the default x64 image base and carries `DYNAMIC_BASE`,
`HIGH_ENTROPY_VA`, and `NX_COMPAT`.

Subsystem 10.0 normal launch requires a valid Load Configuration Directory.
Without it, Windows rejects the image with `0xC000007B` before reaching the entry
point. `_load_config_used` supplies the 148-byte legacy prefix through
`GuardFlags`, leaves unused pointers null, and sets
`IMAGE_GUARD_SECURITY_COOKIE_UNUSED`. The linker publishes it as data-directory
entry 10.

This is the minimal normal-launch condition isolated by
`C:\git\fasm2\examples\ss10`. Relocations and x64 unwind metadata do not
substitute for load configuration metadata.

### Uninitialized NEWCOFF data

The intended BSS declaration is:

```asm
section '.bss' readable writeable align 64
```

Do not add the `data` attribute. With only uninitialized declarations and no
emitted bytes, NEWCOFF derives `IMAGE_SCN_CNT_UNINITIALIZED_DATA` and sets
`PointerToRawData` to zero.

BSS must remain separate from initialized data. COFF object-section
`VirtualSize` is reserved and must be zero; unlike a PE image, an object section
cannot describe a logical tail larger than its raw initialized prefix.

Adding `data` marks the section `IMAGE_SCN_CNT_INITIALIZED_DATA`. Combining that
with NEWCOFF's derived uninitialized flag and zero raw pointer makes the linker
interpret bytes at file offset zero as initial state. The result can load
without fault while global state contains object-header bytes instead of zeros.

### CALM interceptor ordering

[`common/vt.g`](common/vt.g) installs a `calminstruction ?` catch-all for output
fragment notation. It must be included after local `struct` declarations.

`struct` and `ends` move the `?` handler chain with `mvmacro` and `mvstruc`.
Installing a catch-all across that shuffle can route field declarations through
the wrong handler and define fields twice. Generated projection types are
unaffected because they are declared before the catch-all exists.

## Verification record

The editor has been exercised in a live console by attaching a harness, feeding
`INPUT_RECORD`s with `WriteConsoleInput`, and reading the result with
`ReadConsoleOutputCharacter` and console-attribute APIs.

Verified behavior includes:

- initial `WINDOW_BUFFER_SIZE_EVENT` and first paint
- all keyboard navigation, wheel scrolling, and click placement
- hexadecimal and character entry
- pending-change gating when page, goto, exit, or resize would evict changes
- write, restore, and prompt cancellation paths
- width acquisition and exact width/height restoration on exit
- dynamic heights through 64 lines
- recovery from a window below 76 by four
- partial final rows and cursor clamping on a five-byte file
- read-only opening and edit refusal
- only the intended file values differ after a write
- console modes, code page, and terminal state restored on exit
- no stale cursor highlight after scrolling in either direction
- startup SBCS capture and `F3` filtering/cycling
- complete 76-column footer and distinct prompt attributes
- persistent `written` and `unchanged` exit summaries
- PE subsystem 10.0 normal launch with the load-config directory present

Not exercised:

- files at the 4 GiB boundary
- console hosts other than Windows Terminal on Windows 11
- the live `DISCARDED` summary path

The discard count follows the same exit path, but reliably driving Ctrl+Break or
console close from the harness also tears down the console that must be inspected.
