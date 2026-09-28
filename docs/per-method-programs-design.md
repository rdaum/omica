# Per-method programs and incremental filein

Status: design, approved for implementation 2026-09-26.

## What this serves

Mica is a database, a programming language and a runtime at once. A world is
live: its identities, facts, rules, verbs, authority, effects and tasks all
change while it runs, and behavior is installed into the world beside the
facts it reads and writes. The world, not any source file, is the source of
truth. It blends Smalltalk (a live image authored in place, with filein and
fileout), Self (prototypes, delegation and slots) and a Datalog database
(facts and derived relations). Installing new behavior into a running world is therefore a core
operation of the runtime, not a convenience, and a compiled program is data
the world stores and serves like any other fact.

## Problem

A world compiles every loaded file into one `vm.Program`. A method is a
function index into that program (`MethodProgram(method, index)`), the store
holds exactly one `ProgramBytes` row, and a verb that calls another verb
compiles to a direct `.Call <index>`. A running world therefore cannot take a
new filein without recompiling every source and keeping every existing index
stable. `tools/filein` into a booted store silently ignored new files for
this reason. In a live, image-based system, filing into a running world is
the normal way to extend it, so `tools/filein` now files into the booted
world (`world_filein`, below).

Rust mica compiles each method to its own program, identified by a program
identity. `MethodProgram(method, program)` names it, `ProgramBytes` holds one
row per program, a resolver caches programs by identity, and a later filein
only installs more methods and runs its top-level expressions
(`crates/runtime/src/lib.rs:1261-1345`, `crates/vm/src/program.rs:4320`).
omica adopts the same model.

## Relation to open issues

- **#78 (dynamic compile and source installation).** This design supplies
  #78's program registry: `World.program` becomes a set of programs,
  `MethodProgram` resolves through a registry, and an install coexists with
  tasks running older programs. `world_filein` is the host-side install path;
  #78's `compile` and `install_source` builtins, and their authority gate,
  build on the same registry.
- **#110 and #111 (runtime `make_relation` and `make_identity`).** Filein
  into a running world still declares through the loader prescan. Once #110
  and #111 make the constructors real, the prescan becomes an optimization
  over the same catalog logic, and verbs can declare at run time. The
  greenfield parity runs record today's gap: a conflicting redeclaration is
  silently ignored where Rust fails, and `make_relation` returns `[] {}`
  where Rust returns the relation.
- **#115 (artifact services).** One `ProgramBytes` row per program, keyed by
  artifact id, is the artifact contract a generated runtime must load.
- **#116 (bootstrap tracker).** A generator library installs its verbs into a
  build world incrementally; it needs this registry to do so without
  recompiling the world.

## Design

**Programs.** A world holds many programs:

- one per verb, whose function 0 is the verb body and whose remaining
  functions are the `fn` literals inside it;
- one entry program per filein, holding that file's top-level expressions
  (and the `fn` literals inside them). Entry programs run once and are not
  persisted, as today.

**Program identity.** A program's identity is its artifact id,
`vm.program_artifact_id(bytes)`: content addressed, stable across boots, and
already used for the single row today. `MethodProgram(method, program_id)`
stores it, and `ProgramBytes(program_id, bytes)` holds one row per verb
program. Two verbs with identical bodies share one program.

**Calls between verbs go through dispatch.** A call to another verb by name
compiles to named positional dispatch, the path overloaded or restricted
verbs already take. A verb calling itself keeps the direct `.Call 0`. This
matches Rust, where every method call is a dispatch. It changes behavior in
one way: under `enforce_authority`, a verb-to-verb call is now checked
against `CanInvoke` like any other dispatch.

**Resolver.** The world owns a `Program_Resolver`: a map from program id to
`^vm.Program`, guarded by a mutex and filled when programs are compiled or
decoded from `ProgramBytes`. Programs are immutable once published and live
until the world is destroyed, so a resolved pointer never dangles. Dispatch
(VM and scheduler) reads `MethodProgram`, then asks the resolver.

**VM frames carry their program.** `Frame` gains `program: ^vm.Program`.
`state.program` is the current frame's program: set on call, restored on
return, unwind and resume. Every instruction that reads constants, patterns,
shapes, dispatch specs, builtins or functions uses the current program.
Builtin indices are per program, so the builtin index table becomes
per-program (resolved lazily and cached on the program).

**Function values are world-scoped.** A function value is an id into a
callable table. Today each program owns its table, so a closure made in one
program cannot be called from another. The table moves to one registry
shared by all of a world's programs; an entry records `(program, function,
captures)`.

**Boot.** Boot decodes every `ProgramBytes` row into the resolver. A store
whose `MethodProgram` values are integers (the single-program layout) is
migrated on boot: it recompiles from `UnitSource` under the new layout and
rewrites `MethodProgram` and `ProgramBytes` in one commit.

**Eval.** `world_eval` compiles only the eval source. Verbs are reached by
dispatch, so it no longer recompiles every stored source.

**Filein into a running world.** `world_filein(world, paths, unit, mode)`
matches Rust's `run_filein_with_unit` and `FileinMode`:

- `Add` (default): prescan declarations, install rules, compile and install
  each new verb, record `UnitSource`, then run the files' top-level
  expressions as one root task. Nothing already loaded is recompiled.
- `Replace`: first retract what the unit owns (its `SourceOwns*` facts,
  rules and methods), then proceed as `Add`, in one transaction, so readers
  see the old unit or the new one, never a mix.

`tools/filein` on a booted store files the given paths in with `Add`, or
`Replace` under `--replace`, as the Rust CLI does.

**Units are namespaces with persistent state (decided 2026-09-26).** Rust
mica runs each top-level statement of a filein as its own task, so a `let`
in one statement is not visible to the next, and a unit only groups what it
owns (`crates/runtime/src/lib.rs:418-537`; mdbook
`runtime/filein-fileout.md`). omica departs from this deliberately: a filein
is composed of verbs and the unit's own state. Top-level bindings become that
unit's state, stored as facts, readable by the unit's verbs, and kept across
reboot and `Replace`. Until the units RFC specifies that state, a filein's
top-level statements keep today's behavior (one root task sharing one scope),
and verbs cannot yet read it. In Smalltalk terms a unit is a package with
its own variables; in Self terms it is an object whose slots hold its state
and whose verbs are its methods. Either reading keeps the state in the world
as facts, where fileout, replacement and queries see it.

## What does not change

- The instruction set, value encoding and artifact codec (a verb program is
  an ordinary program).
- `compile_program` for a whole file stays available to the bootstrap,
  self-differential and profiling tools, which compare whole programs.
- Hosts keep passing fileins at start; on a booted store the web host keeps
  ignoring them, as today.

## Tests

- A verb calls another verb from a different file loaded earlier (dispatch
  across programs), in memory and after reboot.
- A closure created in one verb is called from another verb.
- `world_filein` Add: new relation, identity, rule, verb and facts usable
  immediately and after reboot; existing verbs unchanged; `ProgramBytes` has
  one row per verb program.
- `world_filein` Replace: facts, rules and verbs only the old unit declared
  are gone; the new ones are present.
- Migration: a store written in the single-program layout boots and runs.
- The full suite (`scripts/test.sh all`) stays green; benchmark dispatch cost
  with `tools/micabench` before and after.
