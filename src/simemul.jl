module simEmul

# qui è dove definisco insieme le due simulazioni, quella che "emula" e quella che controlla il sistema emulato ("simula")
# ovvero: simula il comportamento dell'ambiente se ricevesse azioni correttive esterne
#qui avvengono anche i cicli di confronto e pareto etc etc e definisco i path dove salvare i dati
# ==================================================================================================================================

println()
println("############################################")
println("########                            ########")
println("########     Buongiorno Padrona     ########")
println("########                            ########")
println("############################################")
println()

using StableRNGs, Random
using ResumableFunctions
using CSV
using JSON3
using Distributions
using ConcurrentSim
using DataFrames
using StatsPlots
using Plots
using Statistics
using PrettyTables

println("## abbiamo importato, perdoni la lentezza ##")

include("./input.jl")
include("./structures.jl")
include("./selection.jl")
include("./output.jl")
include("./coresim.jl")
#include("./aftermath.jl")

using .inputdata
using .structures
using .selectionrules
using .postprocess
#using .showdash
using .coresimulation

export simem

# ========     QUI IL PATH IN SALVATAGGIO     ==============================================
#nominato qui
# ========     DA QUI CREDI IN DIO CHE TI AIUTA     ========================================

const CLIENTNUM = 320

const REPETITIONS::Int64 = 100
const master_seed = 42
seeds_rng = StableRNG(master_seed)
seeds = rand(seeds_rng, UInt32, REPETITIONS)

const inpath::String = "inputfile"
const registry::String = "code_registry_3route_5client_norm.json"
matrix::String = "lavoration_matrix.csv"

#mettile dentro una funzione, anche se sono "variabili globali"
codesnames,
codesdistribution,
codesroute,
stationsnames,
codessizevalues,
codessizedistributions,
codesprocessingtimes,
stationscapacities = buildinput(inpath, registry, matrix)

function simem(outpath::String)
    for policy in selectionRules
        outdir = joinpath(outpath, policy.name)

        println()    
        println("##### avvio emulatore ######################")
        println("##### policy: $(policy.name) ######################")
        println("##### repliche: $(length(seeds)) ########################")
        println()

        runSaveSim(seeds, stationsnames, stationscapacities, codesroute, codesnames, codesdistribution, codessizevalues, codessizedistributions, codesprocessingtimes, CLIENTNUM, policy.rule, outdir)
    end
end


end #quello del modulo
