.option relax
.option pic

.data
.global rel_var
rel_var:
.word 5

.hidden hidden_var
hidden_var:
.word 6

.text
.type ifunc STT_GNU_IFUNC
.hidden ifunc
ifunc:
    ret

.global foo
foo:
    lga a0, rel_var
    lga a1, hidden_var
    lga a2, ifunc
