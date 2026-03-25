#qui lancio il main

include("src/simemul.jl")
include("src/aftermath.jl")
include("src/anova.jl")

using .simEmul
using .showdash
using .showanova

outpath = "results1"

#simem(outpath)
performAnova(outpath)
#savefigs(outpath)
