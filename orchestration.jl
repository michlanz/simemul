module orchestration

export runCampaign

const SIMULATION_RUN_MODES = (
    :static,
    :adaptive_spt,
    :adaptive_slack,
    :adaptive_combined_spt_first,
    :adaptive_combined_slack_first,
)

campaignName(::Val{:static}) = "static"
campaignName(::Val{:adaptive_spt}) = "adaptiveSPT"
campaignName(::Val{:adaptive_slack}) = "adaptiveSLACK"
campaignName(::Val{:adaptive_combined_spt_first}) = "adaptive_comb_SPTfirst"
campaignName(::Val{:adaptive_combined_slack_first}) = "adaptive_comb_SLACKfirst"

isSimulationRunMode(runMode::Symbol)::Bool = runMode in SIMULATION_RUN_MODES
campaignPath(runNumber::Int, runMode::Symbol)::String = "r$(runNumber)_$(campaignName(Val(runMode)))"

function existingRunNumbers(root::String = ".")::Vector{Int}
    numbers = Int[]

    for item in readdir(root)
        isdir(joinpath(root, item)) || continue

        match_run = match(r"^r(\d+)_", item)
        match_run === nothing && continue

        push!(numbers, parse(Int, match_run.captures[1]))
    end

    return numbers
end

function firstAvailableRunNumber(usedNumbers)::Int
    runNumber = 1

    while runNumber in usedNumbers
        runNumber += 1
    end

    return runNumber
end

function plannedCampaignPaths(runModes::AbstractVector{Symbol}; root::String = ".")
    planned = NamedTuple[]
    usedNumbers = Set(existingRunNumbers(root))

    for runMode in runModes
        isSimulationRunMode(runMode) || continue

        runNumber = firstAvailableRunNumber(usedNumbers)
        push!(planned, (runMode = runMode, path = campaignPath(runNumber, runMode)))
        push!(usedNumbers, runNumber)
    end

    return planned
end

function plannedCampaignPath(planned, runMode::Symbol)::Union{Nothing, String}
    for campaign in planned
        campaign.runMode == runMode && return campaign.path
    end

    return nothing
end

function latestCampaignPath(runMode::Symbol; root::String = ".")::String
    suffix = "_" * campaignName(Val(runMode))
    candidates = NamedTuple[]

    for item in readdir(root)
        isdir(joinpath(root, item)) || continue
        endswith(item, suffix) || continue

        match_run = match(r"^r(\d+)_", item)
        match_run === nothing && continue

        push!(candidates, (number = parse(Int, match_run.captures[1]), path = item))
    end

    isempty(candidates) && error("Nessuna campagna esistente trovata per $(runMode)")

    return sort(candidates, by = candidate -> candidate.number)[end].path
end

function analysisCampaignPath(planned, analysisRunMode::Symbol)::String
    plannedPath = plannedCampaignPath(planned, analysisRunMode)
    plannedPath !== nothing && return plannedPath

    return latestCampaignPath(analysisRunMode)
end

function isCombinedAnalysisPath(path::String)::Bool
    isdir(path) || return false

    for item in readdir(path)
        isdir(joinpath(path, item)) || continue
        match(r"^queue_\d+__slack_[0-9]+(?:\.[0-9]+)?$", item) !== nothing && return true
    end

    return false
end

function requiredAnovaOutput(path::String)::String
    if isCombinedAnalysisPath(path)
        return joinpath(path, "00.combined_grid_summary.csv")
    end

    return joinpath(path, "00.anova_policy_summary.csv")
end

function ensureAnovaForEvaluation!(path::String)
    requiredOutput = requiredAnovaOutput(path)
    isfile(requiredOutput) && return

    println("##### ANOVA summary missing for evaluation: $(requiredOutput) #####")
    println("##### running ANOVA first on $(path) #####")

    Main.showanova.performAnova(path)
end

function normalizeRunModes(runModes)::Vector{Symbol}
    return Symbol.(collect(runModes))
end

function runCampaign(
    runModesInput,
    analysisRunModesInput,
    exPostRunModesInput = analysisRunModesInput,
)
    runModes = normalizeRunModes(runModesInput)
    analysisRunModes = normalizeRunModes(analysisRunModesInput)
    exPostRunModes = normalizeRunModes(exPostRunModesInput)

    plannedPaths = plannedCampaignPaths(runModes)

    analysisPaths = [
        (runMode = analysisRunMode, path = analysisCampaignPath(plannedPaths, analysisRunMode))
        for analysisRunMode in analysisRunModes
    ]

    exPostPathsPlanned = [
        (runMode = exPostRunMode, path = analysisCampaignPath(plannedPaths, exPostRunMode))
        for exPostRunMode in exPostRunModes
    ]

    for runMode in runModes
        if runMode == :adaptive_spt
            Main.simEmul.simemAdaptiveSPT(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :adaptive_slack
            Main.simEmul.simemAdaptiveSlack(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :adaptive_combined_spt_first
            Main.simEmul.simemAdaptiveCombinedSPTFirst(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :adaptive_combined_slack_first
            Main.simEmul.simemAdaptiveCombinedSlackFirst(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :static
            Main.simEmul.simem(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :anova
            for analysis in analysisPaths
                Main.showanova.performAnova(analysis.path)
            end

        elseif runMode == :figures
            for analysis in analysisPaths
                Main.showdash.savefigs(analysis.path)
            end

        elseif runMode == :evaluation
            for analysis in analysisPaths
                ensureAnovaForEvaluation!(analysis.path)
                Main.showevaluation.performEvaluation(
                    input_dir = analysis.path,
                    output_dir = string(analysis.path) * "_evaluation",
                )
            end

        elseif runMode == :ex_post
            exPostPaths = Dict{Symbol, String}()

            for analysis in exPostPathsPlanned
                ensureAnovaForEvaluation!(analysis.path)
                exPostPaths[analysis.runMode] = analysis.path
            end

            Main.showexpost.performExPostEvaluation(
                input_dirs = exPostPaths,
                output_dir = "r_ex_post_evaluation",
            )

        else
            error("Unknown runMode: $(runMode)")
        end
    end
end

end