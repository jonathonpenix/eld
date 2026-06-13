.option relax
.option pic

.text
.global _start
_start:
    lga a0, sym
    lga a1, sym_neg
    lga a2, sym_addi
