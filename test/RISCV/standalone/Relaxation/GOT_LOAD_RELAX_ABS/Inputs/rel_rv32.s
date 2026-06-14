.option relax
.option pic

.data
.global rel_var
rel_var:
.word 5

.text
.global foo
foo:
    lga a0, rel_var
