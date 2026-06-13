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

# ===== TIMING FORMATTING =====
function formatTime(seconds::Float64)::String
    if seconds < 1
        return @sprintf("%.0f ms", seconds * 1000)
    elseif seconds < 60
        return @sprintf("%.2f s", seconds)
    elseif seconds < 3600
        mins = seconds / 60
        return @sprintf("%.2f min", mins)
    else
        hours = seconds / 3600
        return @sprintf("%.2f h", hours)
    end
end

# ========     QUI IL PATH IN SALVATAGGIO     ==============================================
#nominato qui
# ========     DA QUI CREDI IN DIO CHE TI AIUTA     ========================================

#TODO: la configurazione va configurata in config dio merda
simConfig = validateConfig(SimConfig())

importData = loadImportData(simConfig)

function simem(outpath::String; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    allBenchmarks = NamedTuple[]
    
    campaignStartTime = time()
    
    for (policyIdx, policy) in enumerate(selectionRules)
        outdir = joinpath(outpath, policy.label)
        
        timingData = runSaveSim(cfg, data, seeds, policy.label, policy.rule, outdir)
        
        push!(allBenchmarks, (
            scenario = policy.label,
            type = "policy",
            simCount = length(seeds),
            timeSimulation = formatTime(timingData.simTime),
            timeSaving = formatTime(timingData.saveTime),
            timeTotal = formatTime(timingData.totalTime)
        ))
    end
    
    campaignTotalTime = time() - campaignStartTime
    
    # Add campaign total row
    push!(allBenchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        simCount = length(seeds) * length(selectionRules),
        timeSimulation = "-",
        timeSaving = "-",
        timeTotal = formatTime(campaignTotalTime)
    ))
    
    # Consolidate all benchmarks in main campaign folder
    if !isempty(allBenchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(allBenchmarks)
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
    
    campaignStartTime = time()
    
    queueThresholds = cfg.adaptiveQueueMin:cfg.adaptiveQueueMax
    for (qIdx, queueThreshold) in enumerate(queueThresholds)
        policyName = queueScenarioName(queueThreshold)
        outdir = joinpath(outpath, policyName)
        
        timingData = runAdaptiveScenario(cfg, data, seeds, policyName, outdir; queueThreshold = queueThreshold)
        
        push!(benchmarks, (
            scenario = policyName,
            type = "scenario",
            queueThreshold = queueThreshold,
            simCount = length(seeds),
            timeSimulation = formatTime(timingData.simTime),
            timeSaving = formatTime(timingData.saveTime),
            timeTotal = formatTime(timingData.totalTime)
        ))
    end
    
    campaignTotalTime = time() - campaignStartTime
    
    # Add campaign total row
    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        queueThreshold = "-",
        simCount = length(seeds) * length(collect(queueThresholds)),
        timeSimulation = "-",
        timeSaving = "-",
        timeTotal = formatTime(campaignTotalTime)
    ))
    
    # Consolidate all benchmarks in main campaign folder
    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function simemAdaptiveSlack(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    
    campaignStartTime = time()
    
    slackThresholds = adaptiveSlackThresholds(cfg)
    for (sIdx, slackThreshold) in enumerate(slackThresholds)
        policyName = slackScenarioName(slackThreshold)
        outdir = joinpath(outpath, policyName)
        
        timingData = runAdaptiveScenario(cfg, data, seeds, policyName, outdir; slackThreshold = slackThreshold)
        
        push!(benchmarks, (
            scenario = policyName,
            type = "scenario",
            slackThreshold = slackThreshold,
            simCount = length(seeds),
            timeSimulation = formatTime(timingData.simTime),
            timeSaving = formatTime(timingData.saveTime),
            timeTotal = formatTime(timingData.totalTime)
        ))
    end
    
    campaignTotalTime = time() - campaignStartTime
    
    # Add campaign total row
    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        slackThreshold = "-",
        simCount = length(seeds) * length(slackThresholds),
        timeSimulation = "-",
        timeSaving = "-",
        timeTotal = formatTime(campaignTotalTime)
    ))
    
    # Consolidate all benchmarks in main campaign folder
    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function runAdaptiveCombinedCampaign(outpath::String, cfg::SimConfig, data::ImportData, priorityOrder::Tuple{Symbol, Symbol})
    combinedCfg = scenarioConfig(cfg; adaptivePriorityOrder = priorityOrder)
    seeds = buildSeeds(combinedCfg)
    benchmarks = NamedTuple[]
    
    campaignStartTime = time()
    
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
                scenario = policyName,
                type = "scenario",
                priorityOrder = String(priorityOrder[1]) * "_" * String(priorityOrder[2]),
                queueThreshold = queueThreshold,
                slackThreshold = slackThreshold,
                simCount = length(seeds),
                timeSimulation = formatTime(timingData.simTime),
                timeSaving = formatTime(timingData.saveTime),
                timeTotal = formatTime(timingData.totalTime)
            ))
        end
    end
    
    campaignTotalTime = time() - campaignStartTime
    
    # Add campaign total row
    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        priorityOrder = String(priorityOrder[1]) * "_" * String(priorityOrder[2]),
        queueThreshold = "-",
        slackThreshold = "-",
        simCount = length(seeds) * totalScenarios,
        timeSimulation = "-",
        timeSaving = "-",
        timeTotal = formatTime(campaignTotalTime)
    ))
    
    # Consolidate all benchmarks in main campaign folder
    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function simemAdaptiveCombinedSPTFirst(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    return runAdaptiveCombinedCampaign(outpath, cfg, data, (:SPT, :MINSLACK))
end

function simemAdaptiveCombinedSlackFirst(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    return runAdaptiveCombinedCampaign(outpath, cfg, data, (:MINSLACK, :SPT))
end


end #quello del modulo

#TODO rendi i path adattivi che questa roba è terrificante 
