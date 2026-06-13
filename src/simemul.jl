module simEmul

# qui è dove definisco insieme le due simulazioni, quella che "emula" e quella che controlla il sistema emulato ("simula")
# ovvero: simula il comportamento dell'ambiente se ricevesse azioni correttive esterne
#qui avvengono anche i cicli di confronto e pareto etc etc e definisco i path dove salvare i dati
# ==================================================================================================================================

using StableRNGs, Random
using ResumableFunctions
using CSV
using JSON3
using Distributions
using ConcurrentSim
using DataFrames
using Statistics
using Printf

println("##### Simulation Engine Loaded #############")

include("./input.jl")
include("./structures.jl")
include("./selection.jl")
include("./output.jl")
include("./coresim.jl")
#include("./aftermath.jl")

using Main.configdata
using .inputdata
using .structures
using .selectionrules
using .postprocess
#using .showdash
using .coresimulation

export simem,
       simemAdaptiveSPT,
       simemAdaptiveSlack,
       simemAdaptiveCombinedSPTFirst,
       simemAdaptiveCombinedSlackFirst,
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
    benchmarks = NamedTuple[]
    
    for (policyIdx, policy) in enumerate(selectionRules)
        outdir = joinpath(outpath, policy.label)

        policyTime = @elapsed begin
            timingData = runSaveSim(cfg, data, seeds, policy.label, policy.rule, outdir)
        end
        
        push!(benchmarks, (
            campaignType = "static",
            policy = policy.label,
            simCount = length(seeds),
            timeSimulation = timingData.simTime,
            timeSaving = timingData.saveTime,
            timeTotal = timingData.totalTime,
            index = policyIdx,
            totalPolicies = length(selectionRules)
        ))
    end
    
    # Save benchmarks to evaluation folder
    if !isempty(benchmarks)
        evaluationPath = outpath * "_evaluation"
        mkpath(evaluationPath)
        timeFile = joinpath(evaluationPath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
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
    timingData = runSaveSim(cfg, data, seeds, policyName, adaptiveRule(queueThreshold, slackThreshold, cfg), outdir)
    return timingData
end

function simemAdaptiveSPT(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    
    queueThresholds = cfg.adaptiveQueueMin:cfg.adaptiveQueueMax
    for (qIdx, queueThreshold) in enumerate(queueThresholds)
        policyName = queueScenarioName(queueThreshold)
        outdir = joinpath(outpath, policyName)
        
        timingData = runAdaptiveScenario(cfg, data, seeds, policyName, outdir; queueThreshold = queueThreshold)
        
        push!(benchmarks, (
            campaignType = "adaptive_spt",
            scenario = policyName,
            queueThreshold = queueThreshold,
            simCount = length(seeds),
            timeSimulation = timingData.simTime,
            timeSaving = timingData.saveTime,
            timeTotal = timingData.totalTime,
            index = qIdx,
            totalScenarios = length(queueThresholds)
        ))
    end
    
    # Save benchmarks to evaluation folder
    if !isempty(benchmarks)
        evaluationPath = outpath * "_evaluation"
        mkpath(evaluationPath)
        timeFile = joinpath(evaluationPath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
    
    return benchmarks
end

function simemAdaptiveSlack(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    
    slackThresholds = adaptiveSlackThresholds(cfg)
    for (sIdx, slackThreshold) in enumerate(slackThresholds)
        policyName = slackScenarioName(slackThreshold)
        outdir = joinpath(outpath, policyName)
        
        timingData = runAdaptiveScenario(cfg, data, seeds, policyName, outdir; slackThreshold = slackThreshold)
        
        push!(benchmarks, (
            campaignType = "adaptive_slack",
            scenario = policyName,
            slackThreshold = slackThreshold,
            simCount = length(seeds),
            timeSimulation = timingData.simTime,
            timeSaving = timingData.saveTime,
            timeTotal = timingData.totalTime,
            index = sIdx,
            totalScenarios = length(slackThresholds)
        ))
    end
    
    # Save benchmarks to evaluation folder
    if !isempty(benchmarks)
        evaluationPath = outpath * "_evaluation"
        mkpath(evaluationPath)
        timeFile = joinpath(evaluationPath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
    
    return benchmarks
end

function runAdaptiveCombinedCampaign(outpath::String, cfg::SimConfig, data::ImportData, priorityOrder::Tuple{Symbol, Symbol})
    combinedCfg = scenarioConfig(cfg; adaptivePriorityOrder = priorityOrder)
    seeds = buildSeeds(combinedCfg)
    benchmarks = NamedTuple[]
    
    queueThresholds = collect(combinedCfg.adaptiveQueueMin:combinedCfg.adaptiveQueueMax)
    slackThresholds = adaptiveSlackThresholds(combinedCfg)
    totalScenarios = length(queueThresholds) * length(slackThresholds)
    scenarioCount = 0
    
    for queueThreshold in queueThresholds
        for slackThreshold in slackThresholds
            scenarioCount += 1
            policyName = combinedScenarioName(queueThreshold, slackThreshold)
            outdir = joinpath(outpath, policyName)
            
            timingData = runAdaptiveScenario(combinedCfg, data, seeds, policyName, outdir; queueThreshold = queueThreshold, slackThreshold = slackThreshold)
            
            push!(benchmarks, (
                campaignType = "adaptive_combined",
                priorityOrder = String(priorityOrder[1]) * "_" * String(priorityOrder[2]),
                scenario = policyName,
                queueThreshold = queueThreshold,
                slackThreshold = slackThreshold,
                simCount = length(seeds),
                timeSimulation = timingData.simTime,
                timeSaving = timingData.saveTime,
                timeTotal = timingData.totalTime,
                index = scenarioCount,
                totalScenarios = totalScenarios
            ))
        end
    end
    
    # Save benchmarks to evaluation folder
    if !isempty(benchmarks)
        evaluationPath = outpath * "_evaluation"
        mkpath(evaluationPath)
        timeFile = joinpath(evaluationPath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
    
    return benchmarks
end

function simemAdaptiveCombinedSPTFirst(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    return runAdaptiveCombinedCampaign(outpath, cfg, data, (:SPT, :MINSLACK))
end

function simemAdaptiveCombinedSlackFirst(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    return runAdaptiveCombinedCampaign(outpath, cfg, data, (:MINSLACK, :SPT))
end
end


end #quello del modulo

#TODO rendi i path adattivi che questa roba è terrificante 
