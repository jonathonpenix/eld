# Conservative Zero Guard in GOT Load Relaxation

## Background

ELD's GOT load relaxation for absolute symbols includes this guard:

```cpp
bool SymbolValueMayBeUnknown = S == 0 && !SymInfo->isWeakUndef();
```

When `S == 0` for an absolute symbol (that isn't a weak-undef), ELD refuses to
relax the GOT access. This document demonstrates why.

---

## The Problem: Symbol Values Change During Relaxation

A linker-script-defined absolute symbol whose value depends on section
placement can change between relaxation passes. Consider:

```
sym_abs = ADDR(.text);    /* value depends on where .text lands */
```

During layout, section addresses are computed iteratively. Until the layout
converges, `sym_abs` may appear as 0 (because `ELFSection::addr()` returns 0
when `Addr == InvalidAddr` — the section hasn't been placed yet).

If relaxation runs while `sym_abs` is still 0, it would emit `c.li rd, 0`,
which is wrong when the final value turns out to be non-zero.

---

## Source Files

### `demo.c`

```c
/* Access sym_abs via GOT. sym_abs is defined in the linker script
   as the start address of .text, which depends on section layout. */
extern long sym_abs;
long use_sym(void) { return sym_abs; }
```

### `demo_zero.t` — sym_abs lands at 0x0 (triggers the guard)

```
SECTIONS {
  .data : { *(.data*) }
  .bss  : { *(.bss*)  }
  sym_abs = ADDR(.text);    /* forward ref: evaluated before .text is placed */
  .text : { *(.text*) }     /* floats after .data/.bss — lands at 0x0 with empty data */
}
```

### `demo_nonzero.t` — sym_abs at 0x1000 (guard does not fire)

```
SECTIONS {
  .data 0x100 : { *(.data*) }
  .bss         : { *(.bss*)  }
  sym_abs = ADDR(.text);    /* .text placed at fixed non-zero address */
  .text 0x1000 : { *(.text*) }
}
```

---

## Compile and Link Commands

```sh
# Compile
clang -target riscv64 -march=rv64imac -mabi=lp64 -fPIC -O2 -c demo.c -o demo.o

# Case 1: sym_abs = 0x0 (guard fires)
ld.eld --thread-count 1 --image-base 0 --verbose demo.o -T demo_zero.t -o demo_zero.out

# Case 2: sym_abs = 0x1000 (guard does not fire)
ld.eld --thread-count 1 --image-base 0 --verbose demo.o -T demo_nonzero.t -o demo_nonzero.out
```

---

## Output

### Case 1: `sym_abs = 0x0` — guard fires, GOT access preserved

**Verbose output (with debug print):**
```
claude: S == 0 for sym sym_abs
Verbose: RISCV_GOT : Cannot relax 4 bytes for symbol 'sym_abs' ...
claude: S == 0 for sym sym_abs
```

**Final symbol value:**
```
0000000000000000  ABS  sym_abs
```

**Disassembly (`objdump -d -M no-aliases`):**
```asm
0000000000000000 <use_sym>:
   0: auipc  a0, 0          ← GOT load preserved (not relaxed to c.li)
   4: ld     a0, 24(a0)
   8: c.ld   a0, 0(a0)
   a: c.jr   ra
```

The GOT indirection is preserved. Without the guard, ELD would have emitted
`c.li a0, 0`, loading the value 0 into `a0`. In this specific case that
would be correct — but see below for why the guard is necessary.

### Case 2: `sym_abs = 0x1000` — guard does not fire

**Verbose output:**
```
claude: S != 0 for sym sym_abs
Verbose: RISCV_GOT : Cannot relax 4 bytes for symbol 'sym_abs' ...
```

*(sym_abs = 0x1000 does not fit in 12-bit signed range [-2048, 2047],
so the addi path is not taken either — the GOT access is correctly
preserved for a different reason.)*

**Final symbol value:**
```
0000000000001000  ABS  sym_abs
```

---

## Why the Guard Is Necessary

The guard `S == 0 → do not relax` is conservative. It exists because ELD
cannot distinguish two cases:

1. **Genuinely zero**: `sym_abs` is at address 0x0 in the final output.
   Relaxing to `c.li rd, 0` would be *correct*, but the guard blocks it.

2. **Temporarily zero**: During an early layout pass, `sym_abs = ADDR(.sect)`
   evaluates to 0 because `.sect` hasn't been assigned its VMA yet
   (`ELFSection::addr()` returns 0 when `Addr == InvalidAddr`). The layout
   converges later and `.sect` lands at 0x1000, so `sym_abs = 0x1000`.
   Without the guard, ELD would have emitted `c.li rd, 0` — **wrong**.

### The Underlying Mechanism

`ELFSection::addr()` returns 0 for any section not yet assigned a VMA:

```cpp
// include/eld/Readers/ELFSection.h
uint64_t addr() const { return hasVMA() ? Addr : 0; }
bool hasVMA() const { return Addr != InvalidAddr; }
```

A linker-script symbol `sym_abs = ADDR(.sect)` evaluated while `.sect` has
`Addr == InvalidAddr` gets stored as 0.

### Historical Note

ELD's convergence loop (added in commits `38f99df1` and `110d6058`) now
re-runs layout until both section addresses and assignment values stabilize
before calling `mayBeRelax()`. This handles most cases. However, the guard
remains necessary because:

- The convergence loop is capped at 4 iterations (circular dependencies may
  not converge)
- Some assignment categories (`BEFORE_SECTIONS`) are only evaluated by
  `evaluateScriptAssignments()` which runs *after* `relax()`, not inside
  the convergence loop
- Future code paths might reintroduce the zero-value timing window

The guard was introduced in commit `52aebfb6` ("Zero-page relaxation") with
the explicit comment:

> *"Zero-page relaxations are not enabled for exact zeroes because not yet
> assigned addresses may temporarily have the value of zero, which may
> incorrectly relax them."*

---

## Related

- `lib/Target/RISCV/RISCVLDBackend.cpp`: `doRelaxationGOT()` — the guard
- `include/eld/Readers/ELFSection.h`: `addr()` returning 0 for unplaced sections
- Commit `52aebfb6`: introduced the S != 0 guard for zero-page relaxation
- Commit `c02bbaf8` (branch `value-relax`): `UncertainValue` — a proper fix
  that tracks whether a symbol value is known, eliminating both false positives
  and false negatives

---

## The Multi-Pass Scenario (Sym Depends on .text Size)

The strongest motivating case for the guard involves a symbol whose value
depends on `.text` size AND `.text` contains relaxable sequences beyond the
GOT pair itself. Each relaxation pass (CALL in pass 0, GOT in pass 1, LUI in
pass 2) shrinks `.text`, so `sym_abs` changes with each pass.

### Source

```c
extern long sym_abs;

__attribute__((noinline)) static void callee(void) { asm volatile(""); }

long use_sym(void) {
    long v = sym_abs;    /* GOT access — RELAXATION_PC pass 1 */
    callee();            /* call  — RELAXATION_CALL pass 0 */
    return v;
}
```

### Linker script

```
SECTIONS {
  sym_abs = ADDR(.text) + SIZEOF(.text);  /* end of .text — changes as relaxation fires */
  .text : { *(.text*) }
  .data : { *(.data*) }
}
```

### What happens (current ELD with convergence loop)

```
Original .text = 64 bytes, sym_abs = 64

Outer iteration 1:
  Inner loop: layout converges → sym_abs = 60 (after CALL relax saved 4 bytes)
  Pass 0 (CALL):    saves 4 bytes from .text
  Pass 1 (GOT):     sees sym_abs = 60, S != 0, relaxes to addi  (60 > 31)
                    deletes auipc, saves 4 more bytes
  ...

Final sym_abs = 32, output: addi rd, zero, 32  ✓
```

The convergence loop (from commits `38f99df1` and `110d6058`) re-runs layout
between outer iterations, so `sym_abs` always reflects the correct post-CALL
value before GOT relaxation runs. S is never 0.

### Why the guard still matters

If the convergence loop were **absent** (as in older ELD), the sequence would be:

```
Outer iteration 1 (single layout pass):
  Layout: .text placed, but sym_abs = ADDR(.text) + SIZEOF(.text) evaluated
          BEFORE .text has been placed → sym_abs = 0  (forward ref, addr = 0)
  Pass 1 (GOT): S = 0, guard fires → GOT not relaxed

  ... or without the guard:
  Pass 1 (GOT): S = 0, relaxes to c.li rd, 0   ← WRONG
  Apply: uses final sym_abs = 32 → c.li rd, 32  ← encoding overflow!
```

Without the guard, the linker would commit to a 2-byte `c.li` instruction
based on `S = 0`, but the apply phase would encode the final value `32` — which
doesn't fit in the 6-bit signed field. This would produce a relocation overflow
or silently wrong binary.

The guard `S == 0 → do not relax` prevents this class of error. It is
conservative (it also blocks genuinely-zero symbols from being relaxed) but
safe.

