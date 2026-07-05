# Non-Adjacent auipc/ld GOT Pairs in RISC-V LLVM Codegen

## Question

Can Clang/LLVM generate a `auipc + lw/ld` GOT pair where other instructions appear
between the two instructions?

## Short Answer

**Yes.** With a specific CPU model and enough surrounding independent work, the
post-RA instruction scheduler inserts independent instructions between `auipc` and
its paired `ld`/`lw` to hide load latency.

---

## Sources

### Expansion happens Pre-RA

`llvm/lib/Target/RISCV/RISCVExpandPseudoInsts.cpp`

`RISCVPreRAExpandPseudo::expandAuipcInstPair()` (line 730) expands `PseudoLGA` and
`PseudoLLA` before register allocation. It creates a fresh virtual `ScratchReg`,
emits `AUIPC` (defining `ScratchReg`), then immediately emits the `LD`/`ADDI`
(using `ScratchReg`):

```cpp
Register ScratchReg =
    MF->getRegInfo().createVirtualRegister(&RISCV::GPRRegClass);
...
BuildMI(MBB, MBBI, DL, TII->get(RISCV::AUIPC), ScratchReg).add(Symbol);
BuildMI(MBB, MBBI, DL, TII->get(SecondOpcode), DestReg)
    .addReg(ScratchReg)
    .addSym(AUIPCSymbol, RISCVII::MO_PCREL_LO);
```

Because this runs **before** register allocation and **before** the post-RA
scheduler, the two instructions are adjacent at expansion time but the scheduler
is free to insert independent instructions between them afterwards.

### Scheduler can split the pair

The `ld` only has a data dependency on `auipc` (it uses `ScratchReg`), not an
adjacency constraint. The post-RA scheduler can legally schedule any independent
instruction between them as long as `ld` follows `auipc`.

`RISCVMergeBaseOffset.cpp` line 111 is also relevant context — it explicitly
checks `if (!MRI->hasOneUse(HiDestReg)) return false`, confirming the one-to-one
pair invariant at the IR level, but this does not prevent post-RA reordering.

---

## Compilation Commands

### Commands that produce adjacent pairs (default, no CPU model)

```sh
clang -target riscv64 -march=rv64gc -mabi=lp64d -fPIC -O3 -S -o - sched3.c
```

### Command that produces non-adjacent pairs

```sh
clang -target riscv64 -march=rv64gc -mabi=lp64d \
  -mcpu=sifive-u74 -fPIC -O3 -S -o - sched3.c
```

The `-mcpu=sifive-u74` flag provides detailed pipeline scheduling information
that enables the scheduler to fill the GOT load latency slot.

### Source file (`sched3.c`)

```c
extern int *gptr;
int test(int a, int b, int c, int d, int e, int f) {
    /* Many independent multiplications to give scheduler work
       to fill the load latency */
    int g = *gptr;
    int r = a*b + c*d + e*f + a*c + b*d + e*a + f*b;
    return g + r;
}
```

---

## Output

### Without `-mcpu` (adjacent pair)

```asm
test:
    auipc   a4, %got_pcrel_hi(gptr)
    ld      a4, %pcrel_lo(.Lpcrel_hi0)(a4)   # immediately adjacent
    ld      a4, 0(a4)
    lw      a4, 0(a4)
    ...
```

### With `-mcpu=sifive-u74` (non-adjacent pair)

```asm
test:
    auipc   a6, %got_pcrel_hi(gptr)
    add     a7, a4, a1          # independent — inserted by scheduler
    add     a1, a1, a2          # independent — inserted by scheduler
    add     a4, a4, a1          # independent — inserted by scheduler
    ld      a6, %pcrel_lo(.Lpcrel_hi0)(a6)   # 3 instructions later
    mul     a5, a7, a5
    mul     a1, a1, a3
    mul     a0, a4, a0
    add     a1, a1, a5
    ld      a2, 0(a6)
    add     a0, a0, a1
    lw      a2, 0(a2)
    addw    a0, a0, a2
    ret
```

The scheduler inserted three `add` instructions between `auipc` and `ld` to
keep the execution units busy while the GOT load completes.

---

## CPU Survey

The gap size depends on the CPU's scheduling model and its modelled GOT load
latency. The same source file was compiled with `-O3 -fPIC` for each target.
Note that some CPU names are rv32-only and were not tested here.

| `-mcpu` | Gap (instructions) | Notes |
|---|---|---|
| (none) | 0 | Generic scheduler, no latency model |
| `sifive-u54` | 0 | In-order core |
| `mips-p8700` | 0 | No gap with this workload |
| `andes-ax45` | 1 | |
| `sifive-p450` | 2 | |
| `sifive-p550` | 2 | |
| `sifive-p670` | 2 | |
| `sifive-p870` | 2 | |
| `sifive-u74` | 3 | |
| `sifive-s76` | 3 | |
| `sifive-x280` | 3 | |

The pattern is consistent: higher-performance out-of-order cores with detailed
scheduling models insert more independent instructions to hide the GOT load
latency. Non-adjacency is **not** unique to `sifive-u74` — it occurs across the
SiFive P-series, S-series, X-series, and Andes AX-series.

### Example: `andes-ax45` (1 instruction between)

```asm
    auipc   a6, %got_pcrel_hi(gptr)
    add     a7, a4, a1              # 1 independent instruction
    ld      a6, %pcrel_lo(.Lpcrel_hi0)(a6)
```

### Example: `sifive-p550` (2 instructions between)

```asm
    auipc   a6, %got_pcrel_hi(gptr)
    add     a7, a4, a1              # independent
    add     a1, a1, a2              # independent
    ld      a6, %pcrel_lo(.Lpcrel_hi0)(a6)
```

---

## Implications for ELD

ELD's GOT relaxation uses `findRelocation(offset, type)` to locate the
`R_RISCV_GOT_HI20` relocation by offset, and the `%pcrel_lo` relocation
references the **label** of the `auipc` (not the offset of the `ld`), so
non-adjacency is already handled correctly. Relaxation does not assume the
two instructions are adjacent in memory.

---

## Interleaved GOT Pairs: Another Relocation Inside gptr1's Pair

When a function accesses two GOT symbols, the scheduler naturally issues
both `auipc`s back-to-back to overlap the two loads. This places the
`R_RISCV_GOT_HI20` for `gptr2` — and its `R_RISCV_RELAX` — **inside**
`gptr1`'s `GOT_HI20`/`PCREL_LO12_I` pair.

This happens with **no `-mcpu` flag required** and across all tested CPUs
because issuing both `auipc`s before either `ld` is universally the optimal
schedule for two independent memory loads.

### Source

```c
extern int *gptr1, *gptr2;
int test(void) { return *gptr1 + *gptr2; }
```

### Compile command

```sh
clang -target riscv64 -march=rv64gc -mabi=lp64d -fPIC -O3 -c two_got.c
```

### Disassembly with relocations (`objdump -dr`)

```
0000000000000000 <test>:
       0: auipc  a0, 0
              R_RISCV_GOT_HI20   gptr1        ← gptr1 HI (offset 0x00)
              R_RISCV_RELAX

0000000000000004 <.Lpcrel_hi1>:
       4: auipc  a1, 0
              R_RISCV_GOT_HI20   gptr2        ← gptr2 HI (offset 0x04) — inside gptr1's pair
              R_RISCV_RELAX
       8: ld     a0, 0(a0)
              R_RISCV_PCREL_LO12_I  .Lpcrel_hi0  ← gptr1 LO (offset 0x08)
              R_RISCV_RELAX
       c: ld     a1, 0(a1)
              R_RISCV_PCREL_LO12_I  .Lpcrel_hi1  ← gptr2 LO (offset 0x0c)
              R_RISCV_RELAX
```

### Relocation table (`readelf -r`)

```
Offset  Type                  Symbol + Addend
0x00    R_RISCV_GOT_HI20      gptr1 + 0
0x00    R_RISCV_RELAX
0x04    R_RISCV_GOT_HI20      gptr2 + 0     ← between gptr1's HI and LO
0x04    R_RISCV_RELAX
0x08    R_RISCV_PCREL_LO12_I  .Lpcrel_hi0 + 0
0x08    R_RISCV_RELAX
0x0c    R_RISCV_PCREL_LO12_I  .Lpcrel_hi1 + 0
0x0c    R_RISCV_RELAX
```

`gptr2`'s `R_RISCV_GOT_HI20` (and RELAX) sit at offset 0x04, squarely
between gptr1's `GOT_HI20` at 0x00 and its `PCREL_LO12_I` at 0x08.

