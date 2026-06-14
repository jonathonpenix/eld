.option relax
.option pic

.section .data.zero
.global var
var:
.word 5

.section .data.relaxable
.global var2
var2:
.word 5

.section .data.oob
.global var3
var3:
.word 5

.text
.global foo
foo:
    lga a0, var
    lga a1, var2
    lga a2, var3
