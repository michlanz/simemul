module findbest

using CSV
using DataFrames
using Statistics

using Main.configdata: findBestOutputDir,
                       findBestParetoMetrics,
                       findBestRunNumbers
using Main.adaptivemetadata: scenarioMetadata

export identifyBestPoliciesFromRuns,
       performFindBest

const HIGHER_IS_BETTER = Dict(
    :simtime => false,
    :ontime_share => true,
    :mean_processing_ratio => true,
)

function runNumber(path::String)::Union{Nothing, Int}
    m = match(r"^r(\d+)_", basename(path))
    m === nothing && return nothing
    return parse(Int, m.captures[1])
end

function runDirsForNumbers(numbers; root::String = ".")::Vector{String}
    dirs = String[]
    wanted = Set(Int.(collect(numbers)))

    for item in readdir(root)
        full = joinpath(root, item)
        isdir(full) || continue
        endswith(item, "_evaluation") && continue
        number = runNumber(item)
        number === nothing && continue
        number in wanted && push!(dirs, item)
    end

    sort!(dirs, by = dir -> runNumber(dir))
    return dirs
end

function sourceMode(runDir::String)::String
    m = match(r"^r\d+_(.+)$", runDir)
    return m === nothing ? runDir : m.captures[1]
end

function rangeOutputDir(numbers; suffix::String = "ex_post")::String
    collected = Int.(collect(numbers))
    isempty(collected) && error("Range run vuoto")
    firstRun = minimum(collected)
    lastRun = maximum(collected)
    return "r$(firstRun)_$(lastRun)_$(suffix)"
end

function isStaticPolicyLabel(label::String)::Bool
    return match(r"^\d+\.[A-Z0-9]+$", label) !== nothing
end

function requiredMetricsPresent(values::Dict{Symbol, Float64})::Bool
    return all(metric -> haskey(values, metric), findBestParetoMetrics)
end

function candidateRow(;
    alternative::String,
    sourceRun::String,
    sourceMode::String,
    sourcePolicy::String,
    candidateType::String,
    simtime::Float64,
    ontimeShare::Float64,
    meanProcessingRatio::Float64,
    sourceParetoRank = missing,
    sourceCompositeScore = missing,
)
    metadata = scenarioMetadata(sourcePolicy, candidateType)
    return (
        alternative = "$(sourceRun)__$(sourcePolicy)",
        source_run = sourceRun,
        source_mode = sourceMode,
        source_policy = sourcePolicy,
        candidate_type = candidateType,
        original_alternative = alternative,
        simtime = simtime,
        ontime_share = ontimeShare,
        mean_processing_ratio = meanProcessingRatio,
        source_pareto_rank = sourceParetoRank,
        source_composite_score = sourceCompositeScore,
        base_policy = metadata[:base_policy],
        adaptive_policy = metadata[:adaptive_policy],
        priority_first_policy = metadata[:priority_first_policy],
        priority_second_policy = metadata[:priority_second_policy],
        spt_queue_threshold = metadata[:spt_queue_threshold],
        edd_due_threshold = metadata[:edd_due_threshold],
        minslack_slack_threshold = metadata[:minslack_slack_threshold],
        criticalratio_ratio_threshold = metadata[:criticalratio_ratio_threshold],
    )
end

function loadStaticCandidates(runDir::String)::Vector{NamedTuple}
    path = joinpath(runDir, "00.anova_policy_summary.csv")
    isfile(path) || return NamedTuple[]

    df = CSV.read(path, DataFrame)
    all(required -> required in propertynames(df), [:policy, :metric, :mean]) || return NamedTuple[]

    rows = NamedTuple[]
    for subdf in groupby(df, :policy)
        policy = String(subdf.policy[1])
        isStaticPolicyLabel(policy) || continue

        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(subdf))
        requiredMetricsPresent(values) || continue

        push!(rows, candidateRow(
            alternative = policy,
            sourceRun = runDir,
            sourceMode = sourceMode(runDir),
            sourcePolicy = policy,
            candidateType = "static",
            simtime = values[:simtime],
            ontimeShare = values[:ontime_share],
            meanProcessingRatio = values[:mean_processing_ratio],
        ))
    end

    return rows
end

function boolValue(value)::Bool
    value isa Bool && return value
    return lowercase(String(value)) == "true"
end

function loadAdaptiveParetoCandidates(runDir::String)::Vector{NamedTuple}
    path = joinpath(runDir * "_evaluation", "global_pareto_exact.csv")
    isfile(path) || return NamedTuple[]

    df = CSV.read(path, DataFrame)
    all(required -> required in propertynames(df), [:alternative, :simtime, :ontime_share, :mean_processing_ratio, :pareto_efficient]) || return NamedTuple[]

    rows = NamedTuple[]
    for row in eachrow(df)
        boolValue(row.pareto_efficient) || continue
        policy = String(row.alternative)
        isStaticPolicyLabel(policy) && continue

        push!(rows, candidateRow(
            alternative = policy,
            sourceRun = runDir,
            sourceMode = sourceMode(runDir),
            sourcePolicy = policy,
            candidateType = "adaptive_pareto",
            simtime = Float64(row.simtime),
            ontimeShare = Float64(row.ontime_share),
            meanProcessingRatio = Float64(row.mean_processing_ratio),
            sourceParetoRank = :pareto_rank in propertynames(df) ? row.pareto_rank : missing,
            sourceCompositeScore = :composite_score in propertynames(df) ? row.composite_score : missing,
        ))
    end

    return rows
end

function combinedPrefix(runDir::String)::String
    text = lowercase(runDir)
    occursin("slackfirst", text) && return "combined_slack_first"
    occursin("slack_first", text) && return "combined_slack_first"
    return "combined_queue_first"
end

function loadCombinedParetoCandidates(runDir::String)::Vector{NamedTuple}
    path = joinpath(runDir * "_evaluation", "combined_pareto_exact.csv")
    isfile(path) || return NamedTuple[]

    df = CSV.read(path, DataFrame)
    all(required -> required in propertynames(df), [:alternative, :simtime, :ontime_share, :mean_processing_ratio, :pareto_efficient]) || return NamedTuple[]

    rows = NamedTuple[]
    prefix = combinedPrefix(runDir)

    for row in eachrow(df)
        boolValue(row.pareto_efficient) || continue
        alternative = String(row.alternative)
        policy = startswith(alternative, "combined_") ? alternative : "$(prefix)__$(alternative)"

        push!(rows, candidateRow(
            alternative = alternative,
            sourceRun = runDir,
            sourceMode = sourceMode(runDir),
            sourcePolicy = policy,
            candidateType = "combined_pareto",
            simtime = Float64(row.simtime),
            ontimeShare = Float64(row.ontime_share),
            meanProcessingRatio = Float64(row.mean_processing_ratio),
            sourceParetoRank = :pareto_rank in propertynames(df) ? row.pareto_rank : missing,
            sourceCompositeScore = :composite_score in propertynames(df) ? row.composite_score : missing,
        ))
    end

    return rows
end

function finalBestByKpi(finalDf::DataFrame)::DataFrame
    rows = NamedTuple[]

    for metric in findBestParetoMetrics
        metric in propertynames(finalDf) || continue
        values = Float64.(finalDf[!, metric])
        higher = HIGHER_IS_BETTER[metric]
        idx = higher ? argmax(values) : argmin(values)
        row = finalDf[idx, :]

        push!(rows, (
            metric = String(metric),
            direction = higher ? "higher is better" : "lower is better",
            source_policy = String(row.source_policy),
            source_run = String(row.source_run),
            value = Float64(row[metric]),
            simtime = Float64(row.simtime),
            ontime_share = Float64(row.ontime_share),
            mean_processing_ratio = Float64(row.mean_processing_ratio),
        ))
    end

    return DataFrame(rows)
end

function writePolicySnippet(path::String, finalDf::DataFrame)
    labels = unique(String.(finalDf.source_policy))

    open(path, "w") do io
        println(io, "const bestPolicyLabels = [")
        for label in labels
            println(io, "    \"$(label)\",")
        end
        println(io, "]")
    end
end

function selectBestPolicies(run_numbers)
    runDirs = runDirsForNumbers(run_numbers)
    isempty(runDirs) && error("Nessun run trovato per findBestRunNumbers=$(collect(run_numbers))")

    candidateRows = NamedTuple[]
    staticCount = 0
    adaptiveCount = 0
    combinedCount = 0

    for runDir in runDirs
        staticRows = loadStaticCandidates(runDir)
        adaptiveRows = loadAdaptiveParetoCandidates(runDir)
        combinedRows = loadCombinedParetoCandidates(runDir)

        staticCount += length(staticRows)
        adaptiveCount += length(adaptiveRows)
        combinedCount += length(combinedRows)

        append!(candidateRows, staticRows)
        append!(candidateRows, adaptiveRows)
        append!(candidateRows, combinedRows)
    end

    isempty(candidateRows) && error("FindBest non ha trovato candidati nei run $(join(runDirs, ", "))")

    candidates = DataFrame(candidateRows)
    pareto = Main.showevaluation.global_pareto_table(candidates)
    final = pareto[pareto.pareto_efficient .== true, :]
    sort!(final, [:pareto_rank, :source_run, :source_policy])
    byKpi = finalBestByKpi(final)

    return (
        run_dirs = runDirs,
        candidates = candidates,
        final = final,
        by_kpi = byKpi,
        static_count = staticCount,
        adaptive_count = adaptiveCount,
        combined_count = combinedCount,
    )
end

function writeBestIdentification(result, output_dir::String; prefix::String = "find_best")
    mkpath(output_dir)

    candidatesFile = prefix == "find_best" ? "find_best_candidates_all.csv" : "$(prefix)_candidates_all.csv"
    paretoFile = prefix == "find_best" ? "find_best_global_pareto.csv" : "$(prefix)_global_pareto.csv"
    byKpiFile = prefix == "find_best" ? "find_best_by_kpi.csv" : "$(prefix)_by_kpi.csv"
    configFile = prefix == "find_best" ? "find_best_policy_labels.jl" : "best_identified_config.jl"
    identifiedFile = prefix == "find_best" ? "find_best_identified.csv" : "best_identified.csv"

    CSV.write(joinpath(output_dir, candidatesFile), result.candidates)
    CSV.write(joinpath(output_dir, paretoFile), result.final)
    CSV.write(joinpath(output_dir, byKpiFile), result.by_kpi)
    CSV.write(joinpath(output_dir, identifiedFile), result.final)
    writePolicySnippet(joinpath(output_dir, configFile), result.final)

    return result.final
end

function printIdentificationSummary(result; title::String = "FindBest")
    println("##### $(title) completato ###################")
    println("  run caricati: $(join(result.run_dirs, ", "))")
    println("  statiche caricate: $(result.static_count)")
    println("  adaptive singole Pareto caricate: $(result.adaptive_count)")
    println("  adaptive combinate Pareto caricate: $(result.combined_count)")
    println("  candidati totali: $(nrow(result.candidates))")
    println("  Pareto globale finale: $(nrow(result.final))")
    println()
    show(result.final[:, [:source_policy, :source_run, :candidate_type, :simtime, :ontime_share, :mean_processing_ratio, :pareto_rank]]; allrows = true, allcols = true)
    println()
end

function identifyBestPoliciesFromRuns(run_numbers; output_dir::String, prefix::String = "ex_post")
    result = selectBestPolicies(run_numbers)
    final = writeBestIdentification(result, output_dir; prefix = prefix)
    printIdentificationSummary(result; title = prefix == "find_best" ? "FindBest" : "ExPost best identification")
    return final
end

function performFindBest(; run_numbers = findBestRunNumbers, output_dir::String = findBestOutputDir)
    return identifyBestPoliciesFromRuns(run_numbers; output_dir = output_dir, prefix = "find_best")
end

end
