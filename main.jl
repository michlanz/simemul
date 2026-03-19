#qui lancio il main

include("src/simemul.jl")
include("src/aftermath.jl")

using .simEmul
using .showdash

outpath = "results1"

simem(outpath)
savefigs(outpath)