module simEmul

# qui è dove definisco insieme le due simulazioni, quella che "emula" e quella che controlla il sistema emulato ("simula")
# ovvero: simula il comportamento dell'ambiente se ricevesse azioni correttive esterne
# qui avvengono anche i cicli di confronto e pareto etc etc e definisco i path dove salvare i dati
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
       simemBest,
       simemAdaptiveSingle,
       simemAdaptive,
       simemCombinedFirst,
       simemCombinedSecond,
       SimConfig,
       ImportData,
       simConfig,
       importData

# ===== TIMING FORMATTING =====
function timingSeconds(seconds::Float64)::Float64
    return round(seconds; digits = 3)
end

# ========     QUI IL PATH IN SALVATAGGIO     ==============================================
# nominato qui
# ========     DA QUI CREDI IN DIO CHE TI AIUTA     ========================================

# TODO: la configurazione va configurata in config
simConfig = validateConfig(SimConfig())

importData = loadImportData(simConfig)

function thresholdSpec(policy::Symbol)
    hasproperty(adaptiveThresholdSpecs, policy) || error("Soglie adaptive non configurate per $(policy)")
    return getproperty(adaptiveThresholdSpecs, policy)
end

function thresholdValues(policy::Symbol)::Vector{Float64}
    spec = thresholdSpec(policy)
    spec.step > 0.0 || error("adaptiveThresholdSpecs.$(policy).step deve essere positivo")
    spec.max >= spec.min || error("adaptiveThresholdSpecs.$(policy).max deve essere >= min")

    values = Float64[]
    value = Float64(spec.min)
    while value <= Float64(spec.max) + 1e-9
        push!(values, round(value; digits = 10))
        value += Float64(spec.step)
    end

    return values
end

function configSnapshotDict(cfg::SimConfig, runMode::String, policies; extra = Dict{String, Any}())
    thresholds = Dict{String, Any}()
    for policy in propertynames(adaptiveThresholdSpecs)
        spec = getproperty(adaptiveThresholdSpecs, policy)
        thresholds[String(policy)] = Dict(
            "min" => spec.min,
            "max" => spec.max,
            "step" => spec.step,
        )
    end

    return Dict{String, Any}(
        "run_mode" => runMode,
        "clientNum" => cfg.clientNum,
        "repetitions" => cfg.repetitions,
        "masterSeed" => cfg.masterSeed,
        "paretoTolerancePercent" => cfg.paretoTolerancePercent,
        "processingTimeCV" => cfg.processingTimeCV,
        "inputPath" => cfg.inputPath,
        "registryFile" => cfg.registryFile,
        "matrixFile" => cfg.matrixFile,
        "releaseBatchSize" => cfg.releaseBatchSize,
        "releaseBatchSpacing" => cfg.releaseBatchSpacing,
        "dueDateMinOffset" => cfg.dueDateMinOffset,
        "dueDateMaxOffset" => cfg.dueDateMaxOffset,
        "adaptiveBasePolicy" => String(adaptiveBasePolicy),
        "adaptivePolicies" => [String(policy) for policy in adaptivePolicies],
        "adaptiveThresholdSpecs" => thresholds,
        "policies" => [String(policy.label) for policy in policies],
        "extra" => extra,
    )
end

function saveConfigSnapshot(outpath::String, cfg::SimConfig, runMode::String, policies; extra = Dict{String, Any}())
    mkpath(outpath)
    open(joinpath(outpath, "config_snapshot.json"), "w") do io
        JSON3.write(io, configSnapshotDict(cfg, runMode, policies; extra = extra))
    end
end

function simem(outpath::String; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    allBenchmarks = NamedTuple[]
    saveConfigSnapshot(outpath, cfg, "static", selectionRules)

    campaignStartTime = time()
    totalSimulationTime = 0.0
    totalSavingTime = 0.0

    for (policyIdx, policy) in enumerate(selectionRules)
        outdir = joinpath(outpath, policy.label)

        timingData = runSaveSim(cfg, data, seeds, policy.label, policy.rule, outdir)
        totalSimulationTime += timingData.simTime
        totalSavingTime += timingData.saveTime

        push!(allBenchmarks, (
            scenario = policy.label,
            type = "policy",
            simCount = length(seeds),
            timeSimulation = timingSeconds(timingData.simTime),
            timeSaving = timingSeconds(timingData.saveTime),
            timeTotal = timingSeconds(timingData.totalTime),
        ))
    end

    campaignTotalTime = time() - campaignStartTime

    push!(allBenchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        simCount = length(seeds) * length(selectionRules),
        timeSimulation = timingSeconds(totalSimulationTime),
        timeSaving = timingSeconds(totalSavingTime),
        timeTotal = timingSeconds(campaignTotalTime),
    ))

    if !isempty(allBenchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(allBenchmarks)
        CSV.write(timeFile, df)
    end
end

function simemBest(outpath::String; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    policies = buildBestSelectionRules(bestPolicyLabels, cfg)
    allBenchmarks = NamedTuple[]
    saveConfigSnapshot(outpath, cfg, "best", policies)

    campaignStartTime = time()
    totalSimulationTime = 0.0
    totalSavingTime = 0.0

    for (policyIdx, policy) in enumerate(policies)
        outdir = joinpath(outpath, policy.label)

        timingData = runSaveSim(cfg, data, seeds, policy.label, policy.rule, outdir)
        totalSimulationTime += timingData.simTime
        totalSavingTime += timingData.saveTime

        push!(allBenchmarks, (
            scenario = policy.label,
            type = "best_policy",
            simCount = length(seeds),
            timeSimulation = timingSeconds(timingData.simTime),
            timeSaving = timingSeconds(timingData.saveTime),
            timeTotal = timingSeconds(timingData.totalTime),
        ))
    end

    campaignTotalTime = time() - campaignStartTime

    push!(allBenchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        simCount = length(seeds) * length(policies),
        timeSimulation = timingSeconds(totalSimulationTime),
        timeSaving = timingSeconds(totalSavingTime),
        timeTotal = timingSeconds(campaignTotalTime),
    ))

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

function runAdaptiveScenario(cfg::SimConfig, data::ImportData, seeds::Vector{UInt32}, policy::SelectionPolicy, outdir::String)
    timingData = runSaveSim(cfg, data, seeds, policy.label, policy.rule, outdir)
    return timingData
end

function simemAdaptiveSingle(outpath::String, adaptivePolicy::Symbol; cfg::SimConfig = simConfig, data::ImportData = importData)
    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    thresholds = thresholdValues(adaptivePolicy)
    policies = [
        buildAdaptiveSelectionPolicy(adaptiveBasePolicy, adaptivePolicy, threshold)
        for threshold in thresholds
    ]
    saveConfigSnapshot(
        outpath,
        cfg,
        "adaptive_single",
        policies;
        extra = Dict{String, Any}(
            "basePolicy" => String(adaptiveBasePolicy),
            "adaptivePolicy" => String(adaptivePolicy),
        ),
    )

    campaignStartTime = time()
    totalSimulationTime = 0.0
    totalSavingTime = 0.0

    for (idx, policy) in enumerate(policies)
        threshold = thresholds[idx]
        outdir = joinpath(outpath, policy.label)

        timingData = runAdaptiveScenario(cfg, data, seeds, policy, outdir)
        totalSimulationTime += timingData.simTime
        totalSavingTime += timingData.saveTime

        push!(benchmarks, (
            scenario = policy.label,
            type = "scenario",
            basePolicy = String(adaptiveBasePolicy),
            adaptivePolicy = String(adaptivePolicy),
            threshold = threshold,
            simCount = length(seeds),
            timeSimulation = timingSeconds(timingData.simTime),
            timeSaving = timingSeconds(timingData.saveTime),
            timeTotal = timingSeconds(timingData.totalTime),
        ))
    end

    campaignTotalTime = time() - campaignStartTime

    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        basePolicy = String(adaptiveBasePolicy),
        adaptivePolicy = String(adaptivePolicy),
        threshold = "-",
        simCount = length(seeds) * length(thresholds),
        timeSimulation = timingSeconds(totalSimulationTime),
        timeSaving = timingSeconds(totalSavingTime),
        timeTotal = timingSeconds(campaignTotalTime),
    ))

    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function simemAdaptive(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    isempty(adaptivePolicies) && error("adaptivePolicies e vuoto: serve almeno una policy adaptive")

    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    policies = SelectionPolicy[]
    scenarioInfo = NamedTuple[]

    for adaptivePolicy in adaptivePolicies
        for threshold in thresholdValues(adaptivePolicy)
            policy = buildAdaptiveSelectionPolicy(adaptiveBasePolicy, adaptivePolicy, threshold)
            push!(policies, policy)
            push!(scenarioInfo, (
                adaptivePolicy = adaptivePolicy,
                threshold = threshold,
            ))
        end
    end

    saveConfigSnapshot(
        outpath,
        cfg,
        "adaptive",
        policies;
        extra = Dict{String, Any}(
            "basePolicy" => String(adaptiveBasePolicy),
            "adaptivePolicies" => [String(policy) for policy in adaptivePolicies],
        ),
    )

    campaignStartTime = time()
    totalSimulationTime = 0.0
    totalSavingTime = 0.0

    for (idx, policy) in enumerate(policies)
        info = scenarioInfo[idx]
        outdir = joinpath(outpath, policy.label)

        timingData = runAdaptiveScenario(cfg, data, seeds, policy, outdir)
        totalSimulationTime += timingData.simTime
        totalSavingTime += timingData.saveTime

        push!(benchmarks, (
            scenario = policy.label,
            type = "scenario",
            basePolicy = String(adaptiveBasePolicy),
            adaptivePolicy = String(info.adaptivePolicy),
            threshold = info.threshold,
            simCount = length(seeds),
            timeSimulation = timingSeconds(timingData.simTime),
            timeSaving = timingSeconds(timingData.saveTime),
            timeTotal = timingSeconds(timingData.totalTime),
        ))
    end

    campaignTotalTime = time() - campaignStartTime

    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        basePolicy = String(adaptiveBasePolicy),
        adaptivePolicy = join(String.(adaptivePolicies), "_"),
        threshold = "-",
        simCount = length(seeds) * length(policies),
        timeSimulation = timingSeconds(totalSimulationTime),
        timeSaving = timingSeconds(totalSavingTime),
        timeTotal = timingSeconds(campaignTotalTime),
    ))

    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function runAdaptiveCombinedCampaign(outpath::String, firstPolicy::Symbol, secondPolicy::Symbol; cfg::SimConfig = simConfig, data::ImportData = importData)
    firstPolicy == secondPolicy && error("Le due policy adaptive combinate devono essere diverse")
    firstThresholds = thresholdValues(firstPolicy)
    secondThresholds = thresholdValues(secondPolicy)
    seeds = buildSeeds(cfg)
    benchmarks = NamedTuple[]
    policies = SelectionPolicy[]

    for firstThreshold in firstThresholds
        for secondThreshold in secondThresholds
            push!(
                policies,
                buildCombinedAdaptiveSelectionPolicy(
                    adaptiveBasePolicy,
                    firstPolicy,
                    firstThreshold,
                    secondPolicy,
                    secondThreshold,
                ),
            )
        end
    end

    saveConfigSnapshot(
        outpath,
        cfg,
        "adaptive_combined",
        policies;
        extra = Dict{String, Any}(
            "basePolicy" => String(adaptiveBasePolicy),
            "firstPolicy" => String(firstPolicy),
            "secondPolicy" => String(secondPolicy),
        ),
    )

    campaignStartTime = time()
    totalSimulationTime = 0.0
    totalSavingTime = 0.0

    scenarioCount = 0

    for firstThreshold in firstThresholds
        for secondThreshold in secondThresholds
            scenarioCount += 1
            policy = policies[scenarioCount]
            outdir = joinpath(outpath, policy.label)

            timingData = runAdaptiveScenario(cfg, data, seeds, policy, outdir)
            totalSimulationTime += timingData.simTime
            totalSavingTime += timingData.saveTime

            push!(benchmarks, (
                scenario = policy.label,
                type = "scenario",
                basePolicy = String(adaptiveBasePolicy),
                priorityOrder = String(firstPolicy) * "_" * String(secondPolicy),
                firstPolicy = String(firstPolicy),
                firstThreshold = firstThreshold,
                secondPolicy = String(secondPolicy),
                secondThreshold = secondThreshold,
                simCount = length(seeds),
                timeSimulation = timingSeconds(timingData.simTime),
                timeSaving = timingSeconds(timingData.saveTime),
                timeTotal = timingSeconds(timingData.totalTime),
            ))
        end
    end

    campaignTotalTime = time() - campaignStartTime

    push!(benchmarks, (
        scenario = "CAMPAGNA TOTALE",
        type = "campaign_total",
        basePolicy = String(adaptiveBasePolicy),
        priorityOrder = String(firstPolicy) * "_" * String(secondPolicy),
        firstPolicy = String(firstPolicy),
        firstThreshold = "-",
        secondPolicy = String(secondPolicy),
        secondThreshold = "-",
        simCount = length(seeds) * length(policies),
        timeSimulation = timingSeconds(totalSimulationTime),
        timeSaving = timingSeconds(totalSavingTime),
        timeTotal = timingSeconds(campaignTotalTime),
    ))

    if !isempty(benchmarks)
        mkpath(outpath)
        timeFile = joinpath(outpath, "time_simulation.csv")
        df = DataFrame(benchmarks)
        CSV.write(timeFile, df)
    end
end

function configuredCombinedPolicies()
    length(adaptivePolicies) >= 2 || error("adaptivePolicies deve contenere almeno due policy per lanciare una combinata")
    adaptivePolicies[1] != adaptivePolicies[2] || error("Le prime due adaptivePolicies devono essere diverse per lanciare una combinata")
    return adaptivePolicies[1], adaptivePolicies[2]
end

function simemCombinedFirst(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    firstPolicy, secondPolicy = configuredCombinedPolicies()
    return runAdaptiveCombinedCampaign(outpath, firstPolicy, secondPolicy; cfg = cfg, data = data)
end

function simemCombinedSecond(outpath::String = "results2"; cfg::SimConfig = simConfig, data::ImportData = importData)
    firstPolicy, secondPolicy = configuredCombinedPolicies()
    return runAdaptiveCombinedCampaign(outpath, secondPolicy, firstPolicy; cfg = cfg, data = data)
end

end # quello del modulo

# TODO rendi i path adattivi che questa roba è terrificante
