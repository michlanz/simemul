module SimEmul

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
#using ResumableFunctions
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
println()

include("./input.jl")
#include("./structures.jl")
#include("./output.jl")
#include("./prioritystore.jl")
#include("./coresimulation.jl")

using .inputdata
#using .structures
#using .postprocess
#using .showdash
#using .prioritystore
#using .coresimulation

export simem

REPETITIONS = 10

function simem()        ARRIVALGATE = false
    #vettore_risultati inizializza
    for i in 1:REPETITIONS
        #immagino ragionevolmente che ciclerò per qualche parametro sia una versione di simulazione "tutto spento"
        #e una a cui dico "se x allora y" e simili
        #anche perchè si crea tutto qui in giro e poi sparisce
        #pusha i risultati
        println("## simulazione numero $i ##")
    end
    
    #leggi i risultati, srotola e salva i csv
end

#la funzione per salvare le figure va messa altrove cazzo


end #quello del modulo