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
using Statistics

println("## abbiamo importato, perdoni la lentezza ##")

include("./config.jl")
include("./input.jl")
include("./structures.jl")
include("./selection.jl")
include("./output.jl")
include("./coresim.jl")
#include("./aftermath.jl")

using .configdata
using .inputdata
using .structures
using .selectionrules
using .postprocess
#using .showdash
using .coresimulation

export simem,
       SimConfig,
       ImportData,
       simConfig,
       importData

# ========     QUI IL PATH IN SALVATAGGIO     ==============================================
#nominato qui
# ========     DA QUI CREDI IN DIO CHE TI AIUTA     ========================================

const simConfig = validateConfig(SimConfig(
    clientNum = 320,
    repetitions = 100,
    masterSeed = 42,
    inputPath = "inputfile",
    registryFile = "code_registry_3route_5client_norm.json",
    matrixFile = "lavoration_matrix.csv",
    releaseBatchSize = 80,
    releaseBatchSpacing = 40.0,
    dueDateMinOffset = 16.0,
    dueDateMaxOffset = 40.0,
))

const importData = loadImportData(simConfig)

function simem(outpath::String; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    for policy in selectionRules
        outdir = joinpath(outpath, policy.name)

        println()    
        println("##### avvio emulatore ######################")
        println("##### policy: $(policy.name) ######################")
        println("##### repliche: $(length(seeds)) ########################")
        println()

        runSaveSim(cfg, data, seeds, policy.name, policy.rule, outdir)
    end
end


end #quello del modulo
