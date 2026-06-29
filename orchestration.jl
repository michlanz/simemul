module orchestration

using Main.adaptivemetadata: combinedAxisColumnsFromLabels

export runCampaign

const SIMULATION_RUN_MODES = (
    :static,
    :best,
    :adaptive_first,
    :adaptive_second,
    :combined_first,
    :combined_second,
)

campaignName(::Val{:static}) = "static"
campaignName(::Val{:best}) = "best"

function policySlug(policy::Symbol)::String
    return lowercase(String(policy))
end

function configuredAdaptivePolicies()
    policies = collect(Main.configdata.adaptivePolicies)
    isempty(policies) && error("adaptivePolicies e vuoto")
    return policies
end

function campaignName(::Val{:adaptive_first})
    policies = configuredAdaptivePolicies()
    length(policies) >= 1 || error("adaptivePolicies deve contenere almeno una policy per :adaptive_first")
    return "adaptive_$(policySlug(Main.configdata.adaptiveBasePolicy))_$(policySlug(policies[1]))"
end

function campaignName(::Val{:adaptive_second})
    policies = configuredAdaptivePolicies()
    length(policies) >= 2 || error("adaptivePolicies deve contenere almeno due policy per :adaptive_second")
    return "adaptive_$(policySlug(Main.configdata.adaptiveBasePolicy))_$(policySlug(policies[2]))"
end

function campaignName(::Val{:combined_first})
    policies = configuredAdaptivePolicies()
    length(policies) >= 2 || error("adaptivePolicies deve contenere almeno due policy per :combined_first")
    return "combined_$(policySlug(Main.configdata.adaptiveBasePolicy))_$(policySlug(policies[1]))_first_$(policySlug(policies[2]))"
end

function campaignName(::Val{:combined_second})
    policies = configuredAdaptivePolicies()
    length(policies) >= 2 || error("adaptivePolicies deve contenere almeno due policy per :combined_second")
    return "combined_$(policySlug(Main.configdata.adaptiveBasePolicy))_$(policySlug(policies[2]))_first_$(policySlug(policies[1]))"
end

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

    labels = String[]
    for item in readdir(path)
        isdir(joinpath(path, item)) || continue
        isfile(joinpath(path, item, "anovaRef.csv")) || continue
        push!(labels, item)
    end

    return !isempty(labels) && combinedAxisColumnsFromLabels(labels) !== nothing
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
)
    runModes = normalizeRunModes(runModesInput)
    analysisRunModes = normalizeRunModes(analysisRunModesInput)

    plannedPaths = plannedCampaignPaths(runModes)

    analysisPaths = [
        (runMode = analysisRunMode, path = analysisCampaignPath(plannedPaths, analysisRunMode))
        for analysisRunMode in analysisRunModes
    ]

    for runMode in runModes

        if runMode == :adaptive_first
            policies = configuredAdaptivePolicies()
            length(policies) >= 1 || error("adaptivePolicies deve contenere almeno una policy per :adaptive_first")
            Main.simEmul.simemAdaptiveSingle(
                plannedCampaignPath(plannedPaths, runMode),
                policies[1],
            )

        elseif runMode == :adaptive_second
            policies = configuredAdaptivePolicies()
            length(policies) >= 2 || error("adaptivePolicies deve contenere almeno due policy per :adaptive_second")
            Main.simEmul.simemAdaptiveSingle(
                plannedCampaignPath(plannedPaths, runMode),
                policies[2],
            )

        elseif runMode == :combined_first
            Main.simEmul.simemCombinedFirst(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :combined_second
            Main.simEmul.simemCombinedSecond(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :static
            Main.simEmul.simem(plannedCampaignPath(plannedPaths, runMode))

        elseif runMode == :best
            Main.simEmul.simemBest(plannedCampaignPath(plannedPaths, runMode))

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

        elseif runMode == :find_best
            Main.findbest.performFindBest()

        elseif runMode == :ex_post
            Main.showexpost.performRangeExPostEvaluation()

        else
            error("Unknown runMode: $(runMode)")
        end
    end
end

end
