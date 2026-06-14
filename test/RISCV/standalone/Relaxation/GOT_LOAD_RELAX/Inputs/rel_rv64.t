SECTIONS {
    .data.zero 0 : { *(.data.zero) }
    .text 0x100 : { *(.text) }
    .got 0x1000 : { *(.got) }
    .data.relaxable 0x100000 : { *(.data.relaxable) }
    .data.oob 0x80000130 : { *(.data.oob) }
}