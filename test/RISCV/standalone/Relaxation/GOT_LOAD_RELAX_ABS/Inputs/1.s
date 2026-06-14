.option relax
.option pic

.weak sym_wu

.text
.global _start
_start:
    lga a0, sym_cli_pos
    lga a1, sym_cli_neg
    lga a2, sym_cli_pos_oob
    lga a4, sym_cli_neg_oob
    lga a3, sym_zero

.global foo
foo:
    lga a0, sym_wu

.global bar
bar:
    lga a0, sym_addi_pos
    lga a1, sym_addi_neg
    lga a2, sym_addi_pos_oob
    lga a3, sym_addi_neg_oob
