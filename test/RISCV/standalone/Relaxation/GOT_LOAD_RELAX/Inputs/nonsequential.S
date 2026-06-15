.option relax
.option pic

#ifdef USE_REL
.data
.global var
var:
.word 10

.global var2
var2:
.word 5
#endif

## The relaxation should work with unrelated instructions
## and relocations interspersed.
.text
.global foo
foo:
.La:
    auipc a0, %got_pcrel_hi(var)
    nop
    nop
    lw a3, %pcrel_lo(.La)(a0)
    lga a1, var2
    lw a2, %pcrel_lo(.La)(a0)
