# Layout and Emission in eld

## Overview

After all input files have been read and symbols resolved, the linker has two remaining jobs before it can write output:

1. **Layout** — decide where everything goes: assign a virtual address and file offset to every output section and a section-relative offset to every fragment within it.
2. **Emission** — write the result: iterate every fragment in order and copy its bytes into the output file buffer, then write the ELF headers around it.

Between those two phases there is a third step that depends on layout having finished: **relocation application** — patching the fragment byte buffers in place using the addresses that layout just assigned.

The high-level call sequence is:

```
Linker::link()
  └─► resolve()          — symbol resolution, section assignment
  └─► layout()
        ├─► GNULDBackend::layout()   — address / offset assignment
        └─► ObjectLinker::relocation()  — patch fragment data in place
  └─► emit()
        └─► ELFObjectWriter::writeObject()  — write bytes to file
```

---

## Layout

### What layout produces

By the end of layout every `ELFSection` has:

- `addr()` — virtual address (for allocatable sections).
- `offset()` — file offset.
- `size()` — total byte count.

Every `Fragment` has:

- `UnalignedOffset` — its byte position within the section, before alignment padding.

From those two numbers the fragment can derive its absolute virtual address and its file position on demand.

### How it happens

Layout is driven by `GNULDBackend::layout()`, which runs these steps in order.

**1. placeOutputSections**

Maps every input `ELFSection` to an output `OutputSectionEntry` by matching it against the linker script rules (or generating default rules when there is no script). This determines section order and which input fragments end up in which output section.

**2. Relaxation**

Calls the target backend's `mayBeRelax` repeatedly until convergence. This is the phase where `RegionFragmentEx` fragments may shrink (instructions replaced or deleted). Because relaxation changes fragment sizes, it must happen before addresses are locked in.

**3. evaluateScriptAssignments**

Evaluates linker script symbol assignments (`PROVIDE`, `=`, etc.) that appear between section rules.

**4. setupProgramHdrs / createProgramHdrs**

Groups output sections into `ELFSegment`s (`PT_LOAD`, `PT_DYNAMIC`, `PT_GNU_STACK`, etc.) according to the linker script or default heuristics. The set of segments is needed before addresses can be assigned because segment alignment constraints affect where sections land.

**5. assignOffsets**

The core address-assignment pass. It iterates segments in order, and for each segment iterates its contained output sections. For each section it:

- Advances the current virtual address to satisfy the section's alignment.
- Sets `ELFSection::addr()` and `ELFSection::offset()`.
- Iterates the section's flat fragment list and calls `Fragment::setOffset()` on each fragment in sequence, accumulating the running byte count within the section.

NOBITS sections (`.bss`) consume virtual address space but no file space, so their fragments do not advance the file offset.

Non-allocatable sections (`.debug_*`, `.symtab`, etc.) are handled in a second pass after all loadable segments have been placed, since they have no virtual address requirement.

### Fragment offsets and alignment

When `Fragment::setOffset(unaligned)` is called, the fragment stores the raw `unaligned` value. The aligned offset is computed on demand:

```
getOffset() = UnalignedOffset + paddingSize()

paddingSize() = bytes needed to align (UnalignedOffset + sectionAddr)
                to the fragment's Alignment
```

Padding is not a separate fragment — it is an implicit gap that the emitter fills when writing the preceding fragment.

---

## Relocation Application

Relocation application runs after layout has locked in all addresses but before the output file is written. It is a separate pass in `ObjectLinker::relocation()`.

For each input section that carries relocations, for each `Relocation` object:

1. The target symbol's address is computed (now known, because layout is done).
2. The relocator calculates the relocation value (e.g. `S + A - P` for a PC-relative reloc).
3. The value is written directly into the fragment's byte buffer at the relocation's offset.

After this pass the fragment buffers contain the final, fully-patched bytes ready to be copied to the output file. Relocations that need to remain in the output (emit-relocs, dynamic relocations) are recorded separately and written to `.rel.*` / `.rela.*` sections during emission.

---

## Emission

Emission is handled by `ELFObjectWriter::writeObject()`. It works on a `FileOutputBuffer` — a memory-mapped region backed by the output file — that was pre-sized during layout.

### Section iteration

The writer iterates output sections in layout order. For each section it obtains a `MemoryRegion` — a view into the `FileOutputBuffer` at that section's file offset — and then calls `emitSection()`.

### Fragment loop

`emitSection()` iterates the section's flat fragment list:

```cpp
for (auto &Frag : S->getFragmentList())
    Frag->emit(CurRegion, Module);
```

Each fragment type implements `emit()` to copy its bytes into the `MemoryRegion`:

- `RegionFragment` — `memcpy` of the raw input data.
- `RegionFragmentEx` — `memcpy` of the (already patched) mutable buffer.
- `FillFragment` — fills with a byte or multi-byte pattern.
- `MergeStringFragment` — writes only the surviving (non-deduplicated) strings at their assigned output offsets.
- `EhFrameFragment` — writes the surviving CIEs and FDEs at their assigned output offsets.
- `Stub`, `GOT`, `PLT` — write linker-generated code or data.

Alignment padding between fragments is written by the preceding fragment's `emit()` (for `RegionFragment`) or handled implicitly by the fill logic.

### ELF structural sections

Alongside the content sections, the writer emits:

- The ELF header and program header table (at the start of the file).
- `.symtab` / `.strtab` and `.dynsym` / `.dynstr` — built from the name pool.
- `.rel.*` / `.rela.*` — built from the recorded emit-relocs.
- The section header table (at the end of the file).

### Segment handling

The `PT_LOAD` segments written into the program header table describe the regions of the file that the OS loader maps into memory. Their `p_offset`, `p_vaddr`, `p_filesz`, and `p_memsz` fields are all filled in during layout. Emission just copies those precomputed values into the ELF program header slots.

---

## Summary: what each phase owns

| Phase | Reads | Writes |
|---|---|---|
| Layout | Fragment sizes, alignment, linker script | Section `addr`, `offset`; fragment `UnalignedOffset`; segment fields |
| Relocation application | Section addresses, symbol values | Fragment byte buffers (in place) |
| Emission | Fragment byte buffers, section offsets | Output file bytes |

The clean separation means that each phase can assume the previous one is complete: relocation application can trust that all addresses are final, and emission can trust that all bytes are fully patched.
