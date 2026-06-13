.option relax
.option pic

.weak sym_wu

.text
.global foo
foo:
    lga a0, sym_wu
