# hexed

![hexed editing a binary file](screenshot.png)

`hexed` is a compact console hex editor for existing files. It displays sixteen
bytes per row, supports hexadecimal and character entry, and keeps changes in
memory until you explicitly write or restore them.

```cmd
hexed <file>
```

There are no command-line options. Quote a path containing spaces.

## Requirements

- x64 Windows 10 or Windows 11
- Windows Terminal or another console host with VT-sequence support
- a window at least 76 columns wide and four lines high

The executable uses PE subsystem version 10.0 and is intentionally aimed at
modern Windows console environments.

## Editing model

`hexed` edits bytes in place. It never inserts, deletes, appends, or resizes the
file.

Only the bytes in the visible view can be edited. Changes remain pending in
memory until you press `F2`; `F5` restores the snapshot loaded for the current
view. Retyping a byte's original value removes that byte from the pending
changes.

Navigation that would replace the view—including paging, jumping, quitting, or
resizing—is held while changes are pending:

```text
changes pending in this view:  W write   R restore   Esc cancel
```

- `W` writes the pending span and continues the requested action.
- `R` restores the view from disk and continues.
- `Esc` cancels an ordinary navigation request.

A resize has already happened and therefore cannot be cancelled; its prompt
offers only write or restore.

`F2` writes directly to the original file and flushes it. There is no backup and
no undo after a write. If the file cannot be opened for writing, `hexed` opens
it read-only, marks that state in the footer, and refuses data entry.

Ctrl+Break and closing the console cannot stop for a prompt. They safely discard
pending in-memory changes, restore the terminal, and report the discard on exit.

## Controls

| Key | Action |
| --- | --- |
| `←` `→` | move one byte within the view |
| `↑` `↓` | move one row; scroll at the top or bottom |
| `PgUp` `PgDn` | move by one screen |
| `Home` `End` | move to the start or end of the row |
| `Ctrl+Home` `Ctrl+End` | move to the start or final page of the file |
| `Tab` | switch between the hexadecimal and character panes |
| `F3` | select the next configured single-byte code page |
| `0`–`9`, `A`–`F` | enter a nibble in the hexadecimal pane |
| printable ASCII | enter a byte in the character pane |
| `F2` | write pending changes |
| `F5` | restore the loaded snapshot for this view |
| mouse wheel | scroll three rows |
| left click | place the cursor |
| `Esc` `Esc` | request exit; pending changes still require a decision |

Character-pane entry accepts bytes `20h` through `7Eh`. Use the hexadecimal pane
to enter all other byte values.

## Reading the screen

The fixed 76-column layout contains an address, sixteen hexadecimal bytes, and
their character interpretation:

```text
  offset  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  0123456789ABCDEF
00000000  48 69 21 0A FF                                    Hi!..
```

Changed bytes are highlighted. The real terminal caret is placed on the nibble
or character that will receive the next keystroke.

The footer shows information not already visible in the dump:

- file name and size
- active character mapping, such as `cp437`
- `read-only` or `MODIFIED` state
- the most recent status message

## Character interpretation

The right-hand pane interprets every byte through a Windows single-byte code
page. The console output code page in effect when `hexed` starts becomes the
first choice when it is single-byte, so the shell can select the initial view:

```cmd
chcp 866 >nul
hexed file
```

`F3` cycles through that captured page and the favourites compiled into
`HEXED_CODEPAGES` in `hexed.h`. The supplied favourites are CP437, CP850, and
Windows-1252. Unsupported, multibyte, and duplicate pages are skipped; CP437 is
the fallback when the startup page is unsuitable.

Byte mappings that Windows rejects, plus Unicode C0 and C1 control characters,
are shown as coloured dots rather than being sent to the terminal. Display
output itself is UTF-8; the original console output code page is restored on
exit.

## Window behavior

The editor uses sixteen bytes per row and therefore owns a fixed width of 76
columns. It asks the terminal to take that width while running and restores the
original width and height on exit. Height is dynamic: every line beyond the
ruler and footer becomes another data row.

If the console host refuses resizing, a wider window is used from its left edge.
A narrower window displays a size warning and recovers when sufficient space is
available.

`hexed` uses the alternate screen buffer, leaving the shell's original screen
and scrollback intact. On exit it prints one lasting summary:

```text
hexed: C:\path\file.bin: 1 byte written
hexed: C:\path\file.bin: unchanged
hexed: C:\path\file.bin: unchanged, 3 pending bytes DISCARDED
```

## Limitations

- Existing files only; no creation or resizing.
- Files of 4 GiB and larger are refused because addresses are eight hex digits.
- Character-pane input is printable ASCII; use hex entry for the full byte
  range.
- Correct startup depends on a console host delivering window-size events after
  the alternate screen is activated.
- Terminal resizing and restoration depend on host VT support.

## Building and development

Assembler architecture, build requirements, binary-format policy, and the
verification record are in [DEVELOPING.md](DEVELOPING.md).
