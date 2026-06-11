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
using Printf

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
       simemAdaptiveSPT,
       simemAdaptiveSlack,
       simemAdaptiveCombined,
       SimConfig,
       ImportData,
       simConfig,
       importData

# ========     QUI IL PATH IN SALVATAGGIO     ==============================================
#nominato qui
# ========     DA QUI CREDI IN DIO CHE TI AIUTA     ========================================

#TODO: la configurazione va configurata in config dio merda
simConfig = validateConfig(SimConfig())

importData = loadImportData(simConfig)

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

function scenarioConfig(cfg::SimConfig; adaptivePriorityOrder::Tuple{Symbol, Symbol} = cfg.adaptivePriorityOrder)::SimConfig
    return validateConfig(SimConfig(
        clientNum = cfg.clientNum,
        repetitions = cfg.repetitions,
        masterSeed = cfg.masterSeed,
        inputPath = cfg.inputPath,
        registryFile = cfg.registryFile,
        matrixFile = cfg.matrixFile,
        releaseBatchSize = cfg.releaseBatchSize,
        releaseBatchSpacing = cfg.releaseBatchSpacing,
        dueDateMinOffset = cfg.dueDateMinOffset,
        dueDateMaxOffset = cfg.dueDateMaxOffset,
        adaptivePriorityOrder = adaptivePriorityOrder,
        adaptiveQueueMin = cfg.adaptiveQueueMin,
        adaptiveQueueMax = cfg.adaptiveQueueMax,
        adaptiveSlackMin = cfg.adaptiveSlackMin,
        adaptiveSlackMax = cfg.adaptiveSlackMax,
        adaptiveSlackStep = cfg.adaptiveSlackStep,
    ))
end

function queueScenarioName(queueThreshold::Int64)::String
    return "queue_" * @sprintf("%03d", queueThreshold)
end

function slackScenarioName(slackThreshold::Float64)::String
    cleanValue = replace(@sprintf("%.1f", slackThreshold), "-0.0" => "0.0")
    return "slack_$(cleanValue)"
end

function combinedScenarioName(queueThreshold::Int64, slackThreshold::Float64)::String
    return "$(queueScenarioName(queueThreshold))__$(slackScenarioName(slackThreshold))"
end

function adaptiveSlackThresholds(cfg::SimConfig)::Vector{Float64}
    thresholds = Float64[]
    value = cfg.adaptiveSlackMax
    while value >= cfg.adaptiveSlackMin - 1e-9
        push!(thresholds, round(value; digits = 10))
        value -= cfg.adaptiveSlackStep
    end
    return thresholds
end

function runAdaptiveScenario(cfg::SimConfig, data::ImportData, seeds::Vector{UInt32}, policyName::String, outdir::String; queueThreshold = nothing, slackThreshold = nothing)
    println()
    println("##### avvio adaptive scenario ######################")
    println("##### scenario: $(policyName) ######################")
    println("##### repliche: $(length(seeds)) ########################")
    println()

    runSaveSim(cfg, data, seeds, policyName, adaptiveRule(queueThreshold, slackThreshold, cfg), outdir)
end

function simemAdaptiveSPT(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    campaignRoot = joinpath(outpath, "1.adaptive_SPT")

    for queueThreshold in cfg.adaptiveQueueMin:cfg.adaptiveQueueMax
        policyName = queueScenarioName(queueThreshold)
        outdir = joinpath(campaignRoot, policyName)
        runAdaptiveScenario(cfg, data, seeds, policyName, outdir; queueThreshold = queueThreshold)
    end
end

function simemAdaptiveSlack(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    campaignRoot = joinpath(outpath, "2.adaptive_SLACK")

    for slackThreshold in adaptiveSlackThresholds(cfg)
        policyName = slackScenarioName(slackThreshold)
        outdir = joinpath(campaignRoot, policyName)
        runAdaptiveScenario(cfg, data, seeds, policyName, outdir; slackThreshold = slackThreshold)
    end
end

function runAdaptiveCombinedCampaign(outpath::String, cfg::SimConfig, data::ImportData, campaignFolder::String, priorityOrder::Tuple{Symbol, Symbol})
    combinedCfg = scenarioConfig(cfg; adaptivePriorityOrder = priorityOrder)
    seeds = buildSeeds(combinedCfg)
    campaignRoot = joinpath(outpath, campaignFolder)

    for queueThreshold in combinedCfg.adaptiveQueueMin:combinedCfg.adaptiveQueueMax
        for slackThreshold in adaptiveSlackThresholds(combinedCfg)
            policyName = combinedScenarioName(queueThreshold, slackThreshold)
            outdir = joinpath(campaignRoot, policyName)
            runAdaptiveScenario(combinedCfg, data, seeds, policyName, outdir; queueThreshold = queueThreshold, slackThreshold = slackThreshold)
        end
    end
end

function simemAdaptiveCombined(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    runAdaptiveCombinedCampaign(outpath, cfg, data, "3.adaptive_SPT_precedence", (:SPT, :MINSLACK))
    runAdaptiveCombinedCampaign(outpath, cfg, data, "4.adaptive_SLACK_precedence", (:MINSLACK, :SPT))
end


end #quello del modulo

#TODO rendi i path adattivi che questa roba è terrificante 