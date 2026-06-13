.option relax
.option pic

.weak sym_wu

.text
.global _start
_start:
    lga a0, sym
    lga a1, sym_neg
    lga a2, sym_addi

.global foo
foo:
    lga a0, sym_wu
