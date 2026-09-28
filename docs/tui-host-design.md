# In-process terminal (TUI) host: design

Status: design proposal. Nothing in this document is implemented.
Date: 2026-09-20.
Scope: a generic full-screen terminal transport for the Odin port, the
imperative `term_*` builtin surface, and the screen and input model behind it.
The host is world-agnostic; console tools and, later, the agent shell are
ordinary consumers.
References: `host/web` (thread roles, session and subscription patterns),
`docs/http-host-design.md`, `tools/repl/main.odin` (host input driving),
`mica/kernel/kernel.odin` (`Store_Hooks` host-hook precedent),
`mica/runtime/scheduler.odin` (mailboxes and task suspension).

## 1. Summary

Add a terminal host that gives Mica tasks a mutable screen:

- `mica/term` (new): a pure screen model. Cell buffer, styles, cursor,
  display width, damage diff, and input event types. No OS calls, no ANSI.
- `mica/runtime/terminal.odin` (new): `term_*` builtins backed by a
  host-supplied device. Installed for every world; calls fail with
  `E_NO_TERMINAL` when no terminal is attached, following the `llm_*`
  precedent.
- `host/tui` (new): the POSIX transport. Raw mode, alternate screen, window
  size, `SIGWINCH`, UTF-8 input decoding, ANSI frame encoding, and a writer
  thread.
- `tools/tuihost` (new): a binary that boots a world like `tools/webhost`
  and serves a terminal session.

The API is imperative, in the curses tradition: move, write, set attributes,
refresh. Two properties keep it compatible with the runtime:

1. **No call blocks a scheduler worker.** Output goes to a framebuffer and is
   published by a host writer thread. Input arrives through a mailbox or a
   parked `read(:key)`, exactly as host input already does.
2. **Drawing is presentation, not committed state.** `term_*` builtins never
   touch the kernel. A task that draws and then aborts may leave its last
   frame on the screen; apps redraw from state rather than relying on pixel
   rollback.

The web host's DOM/sync layer is deliberately not reused. A terminal is not a
lossy HTML projection, and a layout engine is not in scope.

## 2. Goals and non-goals

Goals:

- Full-screen TUI applications written in Mica: panes, scrolling, line
  editing, focus, and redraw policy in fileins, not in the runtime.
- One generic host usable by any world that is granted terminal access.
- Deterministic, headless tests: a fake device records frames and feeds
  scripted input, so TUI builtins and Mica screens are unit-testable.
- No terminal escapes in `mica/*`; no OS calls outside `host/tui`.
- Grow to multiple sessions keyed by endpoint identity (tmux panes, multiple
  SSH connections) without changing the Mica API.

Non-goals for this design:

- A widget, layout, or styling library in the runtime or host. `mica/term`
  provides a screen; apps compose cells.
- Reusing the DOM, sync protocol, or `sync_view_*` verbs.
- Windows. The transport is POSIX (termios); CI is Linux and macOS.
- Mouse, clipboard, hyperlinks, and true color beyond 256 in the first
  milestone. They are listed as later work.
- Text-editor or buffer semantics. That is application work on top of the
  screen.
- The LLM host bridge and the agent shell. The host is generic; the agent
  adopts it later (issue #8 is unaffected by this design).

## 3. Reference behaviour

### 3.1 curses conventions we keep

- `term_move(row, col)` and all coordinates are zero-based, row first,
  matching curses `move(y, x)`.
- Writes go to a virtual screen; `term_refresh()` publishes it. Without a
  refresh an app may compose a frame incrementally with no terminal traffic.
- Attributes apply to subsequent writes until changed, like `attron`/`attroff`.
- `term_clear()` blanks the screen and homes the cursor.

### 3.2 curses conventions we drop

- No blocking `getch()`. Input is asynchronous and delivered as a value.
- No window/pad objects. Apps clip and scroll their own content; `mica/term`
  clips writes at the screen edges.
- No `termcap`/`terminfo`. The host targets ANSI/VT100-compatible terminals,
  which covers the macOS Terminal and modern Linux terminals. `TERM=dumb`
  sessions are out of scope; the host refuses to start without a TTY unless
  an explicit fake-device flag is passed.

### 3.3 Runtime precedents

- `log` requires effect authority (`authority_can_effect`) and fails with
  `E_PERMISSION`. Terminal writes mirror that check.
- `llm_responses_stream` and `llm_chat_stream_to` are installed but fail with
  `E_NOT_IMPLEMENTED`. `term_*` follows the same shape for a missing device:
  installed, callable, clear error.
- `Kernel.store: Store_Hooks` supplies durable-store behaviour without the
  kernel knowing the implementation. The terminal device is supplied the same
  way, through `Builtin_Env`.

## 4. Architecture

### 4.1 Thread roles

Four roles share queues and the device, never call across each other:

```
 stdin reader thread        writer thread            scheduler workers
        |                        |                         |
  read(2), decode keys    drain frame queue         run tasks, transactions
        |                  encode ANSI, write(2)           |
        v                        ^                         v
   input queue  --------->  device (screen, style)  <---- term_* builtins
        |                                                  |
        +------ deliver to session mailbox / resume read ---+
```

Rules, copied from `host/web`:

- Connection-side threads (reader and writer) never call the kernel.
- Scheduler workers never call `read(2)` or `write(2)` on the terminal.
- The device is shared; every mutation and snapshot takes its lock briefly.
- Frame publication is bounded: `term_refresh` enqueues at most one pending
  frame per session and coalesces, so a slow terminal cannot grow memory.

### 4.2 Modules

| File | Contents |
| --- | --- |
| `mica/term/term.odin` | `Style`, `Color`, `Cell`, `Screen`, cursor, `clear`/`move`/`write`/`set_style` |
| `mica/term/width.odin` | Display width for scalars and grapheme runs |
| `mica/term/diff.odin` | Pure screen diff to damage runs for the encoder |
| `mica/term/event.odin` | `Input_Event` types: key, paste, resize, eof |
| `mica/runtime/terminal.odin` | `term_*` builtins, device registry, event-to-value encoding |
| `host/tui/term.odin` | Raw mode, alternate screen, window size, `SIGWINCH`, restore |
| `host/tui/input.odin` | Byte stream to `Input_Event`: UTF-8, escape tables, paste |
| `host/tui/frame.odin` | Damage diff to ANSI bytes, clipping, synchronized output |
| `host/tui/device.odin` | `term.Sink` implementation, reader and writer threads |
| `host/tui/session.odin` | Endpoint registry, input delivery, detach and cleanup |
| `tools/tuihost/main.odin` | Flags, world boot, session start, signal handling |

`mica/term` is a value-model package, comparable to `mica/dom`: pure, no I/O,
unit-tested on its own. `host/tui` is the only package that knows about fd 0/1,
termios, and ANSI bytes.

### 4.3 Device interface

The screen model is pure and lives in `mica/term`; the host supplies a sink
through function pointers, so neither package imports the other (the runtime
imports `mica/term`, the host imports both):

```odin
// mica/term
Style :: struct {
	bold, dim, italic, underline, reverse: bool,
	fg, bg:                               Color,
}

Screen :: struct {
	rows, cols:     int,
	cells:          []Cell,      // row-major, rows*cols
	cursor_row:     int,
	cursor_col:     int,
	cursor_visible: bool,
	style:          Style,       // current pen
}

// Implemented by host/tui. `user` is the host's session pointer.
Sink :: struct {
	user: rawptr,
	// Called by term_refresh on the task thread. Copies the frame into the
	// host's pending slot; the writer thread encodes and writes it. No I/O
	// happens here and it must not block. Return false when the terminal is
	// gone.
	publish: proc(user: rawptr, screen: ^Screen, full: bool) -> bool,
	// Reads the window size from the terminal; false when not a TTY.
	size:    proc(user: rawptr) -> (rows, cols: int, ok: bool),
}
```

`Builtin_Env` gains a `terminal` handle:

```odin
Builtin_Env :: struct {
	// ... existing fields ...
	terminal: Terminal_Handle,   // {screen: ^term.Screen, sink: term.Sink, mailbox: v.Value}
}
```

M0 sets one handle for the process's single session. M2 replaces it with a
registry keyed by endpoint identity and resolves it from the submitting
task's endpoint. A world without a handle gets `E_NO_TERMINAL`, never a
crash.

### 4.4 Input path

Two delivery modes, both driven by the host reader thread:

**Session mailbox (primary).** The app creates a mailbox and registers its
sender with the terminal:

```mica
let [events, input] = mailbox()
term_attach(input)
...
let event = mailbox_recv([events], 100)
```

This composes with `subscribe_changes` and timers in one receive: an app can
wait for keys, relation changes, and timeouts together. The web host already
uses the mailbox-plus-subscription pattern for sessions, and the scheduler
already supports multiple receivers with a timeout.

**Parked `read` (convenience).** A task that calls `read(:key)` parks with
`Task_Suspend.Host_Request` and request metadata `:key`. The host watches for
that state and resumes it with the next event via `world_resume` (the `Read`
opcode in `mica/vm/vm.odin`; the driving loop in `tools/repl/main.odin`).
Simple screens need no mailbox setup.

Host-side requirement: `world_task_outcome` is non-blocking and `scheduler_wait`
blocks only until a terminal outcome, so neither helps a host wait for a task
to park on `Host_Request`. M0 adds a host-facing boundary wait
(`world_wait_boundary(world, id) -> Task_Outcome` that returns on a host
request as well as completion), or the host polls like the REPL does. Polling
at 2 ms is acceptable for M0 but a wait is the better fix and closes a general
host gap.

Event values delivered to Mica:

```mica
{:kind -> :key, :key -> :char, :char -> "a", :mods -> []}
{:kind -> :key, :key -> :up,    :mods -> []}
{:kind -> :paste,  :text -> "pasted text"}
{:kind -> :resize, :rows -> 40, :cols -> 120}
{:kind -> :eof}
```

Named keys: `:enter`, `:tab`, `:backspace`, `:escape`, `:delete`, `:insert`,
`:up`, `:down`, `:left`, `:right`, `:home`, `:end`, `:page_up`, `:page_down`,
`:f1` through `:f12`. Modifiers are symbols in `:mods` (`:ctrl`, `:alt`,
`:shift`); Ctrl+A is `{:key -> :char, :char -> "a", :mods -> [:ctrl]}`, not a
control byte. Unknown escape sequences decode to `:char` events or are
dropped, never leaked to the app as raw bytes.

### 4.5 Output path

1. `term_*` builtins mutate the shared `term.Screen` under its lock.
2. `term_refresh()` snapshots the screen and posts it to the session's frame
   slot, replacing any unconsumed frame (coalescing). It does not write.
3. The writer thread takes the newest frame, diffs it against the last frame
   it wrote, encodes the damage as ANSI (CUP, SGR, text runs), and writes it
   as one buffer. Full repaints are used after resize, attach, or when the
   host asks for resynchronization.
4. Frames are wrapped in synchronized output (`CSI ?2026h` / `l`) when the
   terminal advertises support, so updates are not torn.

M0 may start with a full repaint on every refresh; damage diffing is a pure
function in `mica/term` and lands in M1 with golden-byte tests.

### 4.6 Terminal lifecycle

- On session start: save termios, enter raw mode (no echo, no line buffering,
  no signals from keys), switch to the alternate screen, hide the cursor,
  query the window size, and clear.
- On session end: show the cursor, leave the alternate screen, restore
  termios. This must run on normal exit, `SIGINT`, `SIGTERM`, and `SIGHUP`.
  Odin has no reliable global destructor; the host installs a signal handler
  that writes to a self-pipe and lets the main loop restore, with an
  `atexit`-equivalent best effort for panic paths.
- `SIGWINCH` goes through the same self-pipe. The reader thread sees it,
  updates the size, resizes the screen (blanking newly exposed cells),
  invalidates the last written frame, and posts `{:kind -> :resize, ...}`.

### 4.7 Sessions and endpoints

M0 runs one session with one endpoint identity. The registry is keyed by
endpoint from the start so the following can land later without API changes:

- multiple `tools/tuihost` processes against one store are separate processes,
  not multiple sessions;
- one host process with several terminals (for example detached and attached)
  routes by endpoint;
- `Endpoint`, `EndpointActor`, `EndpointPrincipal`, and `EndpointOpen` are
  already installed as volatile relations but no host populates them.
  Populating them here is optional and can wait until a consumer needs
  endpoint reflection.

Terminal and input state is ephemeral: the screen, the mailbox registration,
and the event queue are host and runtime state, never durable. A boot from a
store starts a fresh screen.

## 5. Builtin surface

| Builtin | Arity | Semantics |
| --- | --- | --- |
| `term_size` | 0 | `{:rows, :cols}` for the current terminal |
| `term_clear` | 0 | Blank every cell, reset the pen, home the cursor |
| `term_move` | 2 | Set the cursor; out-of-range coordinates clip, `E_INVARG` on non-integers |
| `term_write` | 1 | Write a string at the cursor, width-aware, advancing it; returns `{:row, :col}` after the write |
| `term_style` | 1 | Set the pen from a style map; `{}` resets |
| `term_cursor` | 0 | `{:row, :col}` of the current cursor |
| `term_set_cursor` | 3 | Position and show or hide the cursor |
| `term_refresh` | 0 | Publish the frame to the writer thread |
| `term_attach` | 1 | Register a mailbox sender for input and resize events |
| `term_detach` | 0 | Stop input delivery and tear down the session; the world keeps running |

Deliberately not builtins: lines, boxes, scrolling, wrapping, and list
rendering. Those are loops and comprehensions in Mica, possibly shared in
`apps/shared/tui.mica` with the same status as `apps/shared/list.mica`.

Errors:

- `E_NO_TERMINAL`: no device attached to this task; the builtin is installed
  but unusable in this world.
- `E_PERMISSION`: the task lacks effect authority. Terminal output is an
  external effect; the check mirrors `log`.
- `E_INVARG` / `E_TYPE`: coordinates outside the screen, malformed style
  maps, non-string writes, unknown style keys.

Style map:

```mica
term_style({:bold -> true, :underline -> true, :fg -> :red, :bg -> :default})
term_style({:fg -> [255, 128, 0]})   // 24-bit later; 8/16 colors in M0/M1
```

Unknown keys are rejected rather than ignored, so typos surface at once.

## 6. Application contract

A minimal screen, complete as a filein:

```mica
verb tui_main()
  while true
    term_clear()
    term_move(0, 0)
    term_style({:bold -> true, :reverse -> true})
    term_write(" mica ")
    term_style({})
    term_move(1, 0)
    term_write("press q to quit")
    term_refresh()

    let event = read(:key)
    if event[:kind] == :key && event[:key] == :char && event[:char] == "q"
      break
    end
  end
  return none
end
```

Notes:

- The loop is a normal task; each `read` commits at the boundary, so input
  handling and relation writes are transactional per key.
- `term_refresh` before `read` means the last frame is always what the user
  was looking at when they pressed the key.
- `q` handling, scroll position, and focus are app state. The host has no
  opinions about them.

The host binary flags mirror `tools/webhost`:

```
tuihost --filein FILE [--filein FILE ...] [--actor NAME]
        [--store DIR] [--durability none|group|strict]
```

`tools/tuihost` runs the terminal loop on the main thread, starts the
scheduler and world as `webhost` does, and waits for the session task to
complete or `term_detach`.

## 7. Unicode, width, and sanitization

- The cell is a short string, not a scalar: one base rune plus any combining
  marks that follow it. ZWJ emoji sequences are stored whole when they fit in
  one cell and fall back to their first scalar otherwise.
- Display width follows East Asian Width: wide and fullwidth scalars occupy
  two cells (lead plus a continuation), zero-width and combining scalars
  occupy none. A small range table lives in `mica/term/width.odin`; it does
  not need to be exhaustive to be useful.
- `term_write` clips at the right edge. Writing into the last column never
  wraps (the host keeps autowrap off) and never splits a wide cell.
- **Sanitization is a security property.** Every string drawn to the screen
  is stripped of C0 controls and DEL, and the host never passes application
  text through raw. Without this, a tool result or user input containing an
  OSC sequence could rewrite the terminal title, the clipboard, or worse.
  Newlines and tabs are not interpreted by `term_write`; apps place lines.

## 8. Testing

Unit (Odin, no terminal):

- `mica/term`: width table, screen edits, clipping, style transitions, diff
  damage, event value encoding.
- `host/tui`: input decoder tables (printable, UTF-8, every escape sequence,
  bare Esc timeout, paste), ANSI encoder golden bytes, resize handling.
- Runtime: `term_*` builtins against a recording fake device; authority
  denial; `E_NO_TERMINAL`; `term_attach` delivery into a mailbox.

Integration:

- A PTY test starts `tools/tuihost` with a fixture world, writes scripted
  bytes, reads the emitted ANSI, and asserts the final screen by replaying it
  through a small test emulator (or by parsing the exact expected bytes). The
  PTY is available through `posix_openpt` on Linux and macOS.
- A smoke path exercises login-free start, resize, `q`, and clean restore
  (termios back to the saved state).
- `scripts/test.sh` gains `mica/term` and `host/tui` in the package list and
  the smoke test next to the web smoke test.

Headless Mica tests:

- A TUI filein runs through `run_files` with a fake device and scripted
  input; the test asserts relation effects and recorded frames, no TTY.

## 9. Milestones

**M0: transport and builtins.**

- `mica/term` screen model, width, event types.
- `term_size`, `term_clear`, `term_move`, `term_write`, `term_style`,
  `term_refresh` builtins plus a fake device and unit tests.
- `host/tui`: raw mode, alternate screen, size, input decoding for printable
  keys, Enter, Backspace, arrows, Ctrl combos, and flat escape sequences;
  full repaint per refresh; writer and reader threads.
- `read(:key)` delivery and `term_attach` mailbox delivery.
- `tools/tuihost` running one filein. A demo console filein in
  `apps/examples/`.
- Host boundary wait (`world_wait_boundary`) or a documented polling loop.

**M1: fidelity and safety.**

- Damage diffing and ANSI frame optimization; golden tests.
- 8/16/256 colors; cursor visibility; `SIGWINCH` and resize events.
- Paste (`:paste`) and complete control-character sanitization.
- Signal-safe restore, PTY integration test, `scripts/test.sh` wiring.

**M2: multiple sessions and terminals.**

- Endpoint-keyed registry, detach and attach, per-session authority.
- Mouse wheel as `:wheel_up`/`:wheel_down` key events.
- Synchronized output and optional 24-bit color.

**M3: consumers (separate work).**

- A reflection inspector or console over live worlds, in the spirit of
  `ui-mica-inspect.mica`.
- The agent shell, once the LLM bridge lands.

## 10. Risks and open questions

1. **Escape disambiguation.** A bare Esc and the start of a sequence need a
   timeout (25 ms is the usual choice). It makes Esc feel slightly delayed.
   The decoder must be table-driven and thoroughly tested; this is the single
   largest correctness surface in the host.
2. **Width and graphemes.** Wide and combining characters affect cursor math
   and the diff. The design scopes this to a good-enough width table and
   whole-cell graphemes; perfect emoji handling is not promised.
3. **Restore on abnormal exit.** A crash that skips the signal handler can
   leave the terminal raw and the alternate screen active. A best-effort
   signal path is planned; `reset` remains the escape hatch. This should be
   stated in the operator docs.
4. **Host wait for parked input.** The runtime has no boundary wait today.
   M0 either adds one or polls. Adding one benefits every host, not only the
   TUI.
5. **Input fan-in.** Apps that need keys, relation changes, and timers in one
   loop should use `term_attach` with `subscribe_changes`. The `read(:key)`
   convenience is single-source. M0 ships both; the mailbox path is the one
   to document for event loops.
6. **Frame pacing.** Coalescing to one pending frame keeps memory bounded but
   can drop intermediate frames. For a TUI this is correct; for a recording
   or debugging mode it may matter. A debug flag can write every refresh.
7. **Authority model.** The design checks effect authority, matching `log`.
   A finer model (a terminal-specific right, or per-endpoint capability)
   can wait until multiple sessions exist.
8. **Terminal variance.** ANSI/VT100 is assumed. Terminals without
   synchronized output, 256-color support, or alternate screen still work but
   with more flicker; the host should degrade, not fail.
9. **Detach semantics.** What happens to the session task when the terminal
   closes: abort, park, or keep running for reattach? M0 can treat `:eof` as
   "resume with `:eof` and let the app return". Reattach needs the store of
   session state to be host-owned and is deferred with M2.
10. **Documentation.** A runtime chapter (`mdbook/src/runtime/`) and a
    built-in table entry are required once M1 lands; `docs/builtins-gap.md`
    tracks the difference in the meantime.
