module showanova

using CSV
using DataFrames
using Statistics
using StatsPlots
using Plots
using Distributions

export performAnova, saveVisualSummary

const anovaHighlightColors = (
    best = :green3,
    worst = :crimson,
)

function naturalSortKey(label)::Tuple
    text = String(label)
    prefix = replace(text, r"\d+" => "")
    suffixMatch = match(r"(\d+)(?!.*\d)", text)
    suffixNum = suffixMatch === nothing ? typemax(Int) : parse(Int, suffixMatch.captures[1])
    return (prefix, suffixNum, text)
end

function orderedPolicies(labels)
    return sort(unique(String.(labels)))
end

function metricSpecs()
    return [
        (column = :simtime, title = "Total Makespan", higherIsBetter = false),
        (column = :throughput, title = "Throughput", higherIsBetter = true),
        (column = :mean_wip_queue, title = "Mean Queue WIP", higherIsBetter = false),
        (column = :mean_queue_length, title = "Mean Queue Length", higherIsBetter = false),
        (column = :mean_saturation, title = "Mean Saturation", higherIsBetter = true),
        (column = :saturation_std, title = "Saturation Std", higherIsBetter = false),
        (column = :mean_makespan, title = "Mean Makespan", higherIsBetter = false),
        (column = :mean_lateness, title = "Mean Lateness", higherIsBetter = false),
        (column = :mean_tardiness, title = "Mean Tardiness", higherIsBetter = false),
        (column = :ontime_share, title = "On-Time Share", higherIsBetter = true),
        (column = :mean_queuetime, title = "Mean Queue Time", higherIsBetter = false),
        (column = :mean_processing_ratio, title = "Mean Processing Ratio", higherIsBetter = true),
        (column = :bottleneck_time_share, title = "Bottleneck Time Share", higherIsBetter = false),
    ]
end

function visualSummaryRows()
    return [
        [:simtime, :throughput, :mean_saturation],
        [:mean_lateness, :mean_tardiness, :ontime_share],
        [:mean_queuetime, :mean_queue_length, :mean_makespan, :mean_processing_ratio],
    ]
end

function visualSummarySpecs(specs)
    specByColumn = Dict(spec.column => spec for spec in specs)
    requestedColumns = [column for row in visualSummaryRows() for column in row]
    missingColumns = filter(column -> !haskey(specByColumn, column), requestedColumns)
    isempty(missingColumns) || error("Metriche mancanti nel visual summary: $(missingColumns)")
    return [specByColumn[column] for column in requestedColumns]
end

function standardPlotKwargs()
    return (
        titlefont = font(13),
        guidefont = font(10),
        tickfont = font(9),
        legendfont = font(9),
        grid = :y,
        gridalpha = 0.18,
        framestyle = :box,
        top_margin = 5 * Plots.mm,
    )
end

function significanceLabel(pValue::Float64)
    isnan(pValue) && return "n/a"
    pValue < 0.001 && return "***"
    pValue < 0.01 && return "**"
    pValue < 0.05 && return "*"
    return "ns"
end

function formatPValue(pValue::Float64)
    isnan(pValue) && return "p = n/a"
    pValue < 0.001 && return "p < 0.001"
    return "p = $(round(pValue; digits = 3))"
end

function collectAnovaRefs(outpath::String)
    rows = DataFrame[]

    for folder in sort(readdir(outpath; join = true))
        !isdir(folder) && continue
        filepath = joinpath(folder, "anovaRef.csv")
        !isfile(filepath) && continue

        df = CSV.read(filepath, DataFrame)
        if "policy" ∉ names(df)
            insertcols!(df, 1, :policy => fill(basename(folder), nrow(df)))
        end
        push!(rows, df)
    end

    isempty(rows) && error("Nessun anovaRef.csv trovato in $(outpath)")

    df = vcat(rows...)
    sort!(df, [:policy, :replication_id])
    return df
end

function buildAnovaStats(valuesByPolicy::Vector{Vector{Float64}})
    groupCount = length(valuesByPolicy)
    totalCount = sum(length, valuesByPolicy)

    if groupCount < 2 || totalCount <= groupCount
        return (f_statistic = NaN, p_value = NaN, eta_squared = NaN)
    end

    groupMeans = [mean(values) for values in valuesByPolicy]
    groupSizes = [length(values) for values in valuesByPolicy]
    grandMean = sum(groupMeans[idx] * groupSizes[idx] for idx in eachindex(valuesByPolicy)) / totalCount

    ssBetween = sum(groupSizes[idx] * (groupMeans[idx] - grandMean)^2 for idx in eachindex(valuesByPolicy))
    ssWithin = sum(sum((value - groupMeans[idx])^2 for value in valuesByPolicy[idx]) for idx in eachindex(valuesByPolicy))
    dfBetween = groupCount - 1
    dfWithin = totalCount - groupCount

    if dfWithin <= 0
        return (f_statistic = NaN, p_value = NaN, eta_squared = NaN)
    end

    msBetween = ssBetween / dfBetween
    msWithin = ssWithin / dfWithin

    if iszero(msWithin)
        fStatistic = iszero(msBetween) ? 0.0 : Inf
        pValue = iszero(msBetween) ? 1.0 : 0.0
    else
        fStatistic = msBetween / msWithin
        pValue = 1.0 - cdf(FDist(dfBetween, dfWithin), fStatistic)
    end

    ssTotal = ssBetween + ssWithin
    etaSquared = ssTotal > 0.0 ? ssBetween / ssTotal : 0.0
    return (f_statistic = fStatistic, p_value = pValue, eta_squared = etaSquared)
end

function buildAnovaOverview(df::DataFrame, specs)
    rows = NamedTuple[]
    policies = orderedPolicies(df.policy)

    for spec in specs
        valuesByPolicy = [Float64.(df[df.policy .== policy, spec.column]) for policy in policies]
        stats = buildAnovaStats(valuesByPolicy)
        push!(rows, (
            metric = String(spec.column),
            title = spec.title,
            f_statistic = stats.f_statistic,
            p_value = stats.p_value,
            eta_squared = stats.eta_squared,
            significant_05 = !isnan(stats.p_value) && stats.p_value < 0.05,
            policy_count = length(policies),
            replication_count = sum(length, valuesByPolicy),
        ))
    end

    return DataFrame(rows)
end

function buildAnovaOverviewLookup(dfOverview::DataFrame)
    lookup = Dict{Symbol, NamedTuple}()
    for row in eachrow(dfOverview)
        lookup[Symbol(row.metric)] = (
            p_value = row.p_value,
            f_statistic = row.f_statistic,
            eta_squared = row.eta_squared,
        )
    end
    return lookup
end

function buildPolicySummary(df::DataFrame, specs)
    rows = NamedTuple[]
    policies = orderedPolicies(df.policy)

    for spec in specs
        policyStats = NamedTuple[]
        for policy in policies
            values = Float64.(df[df.policy .== policy, spec.column])
            push!(policyStats, (
                metric = String(spec.column),
                title = spec.title,
                policy = policy,
                mean = mean(values),
                std = length(values) > 1 ? std(values) : 0.0,
                median = median(values),
                p10 = quantile(values, 0.10),
                p90 = quantile(values, 0.90),
                min = minimum(values),
                max = maximum(values),
                replications = length(values),
            ))
        end

        means = [row.mean for row in policyStats]
        highlightRoles = computeHighlightRoles(means, spec.higherIsBetter)

        for (idx, row) in enumerate(policyStats)
            push!(rows, merge(row, (highlight = String(highlightRoles[idx]),)))
        end
    end

    return DataFrame(rows)
end

function metricTitleWithTest(spec, overviewLookup::Dict{Symbol, NamedTuple})
    stats = overviewLookup[spec.column]
    return "$(spec.title)\n$(formatPValue(stats.p_value))  $(significanceLabel(stats.p_value))"
end

function computeHighlightRoles(meanValues::Vector{Float64}, higherIsBetter::Bool)
    n = length(meanValues)
    roles = fill(:mid, n)
    n == 0 && return roles

    bestOrder = sortperm(meanValues; rev = higherIsBetter)
    worstOrder = sortperm(meanValues; rev = !higherIsBetter)

    for idx in bestOrder[1:min(2, n)]
        roles[idx] = :best
    end

    for idx in worstOrder[1:min(2, n)]
        roles[idx] == :best && continue
        roles[idx] = :worst
    end

    return roles
end

function highlightIndices(meanValues::Vector{Float64}, higherIsBetter::Bool)
    roles = computeHighlightRoles(meanValues, higherIsBetter)
    bestIdx = findall(==(:best), roles)
    worstIdx = findall(==(:worst), roles)
    return bestIdx, worstIdx
end

function roleSeriesData(valuesByPolicy::Vector{Vector{Float64}}, roles::Vector{Symbol}, targetRole::Symbol)
    xValues = Int[]
    yValues = Float64[]

    for (idx, values) in enumerate(valuesByPolicy)
        roles[idx] == targetRole || continue
        append!(xValues, fill(idx, length(values)))
        append!(yValues, values)
    end

    return xValues, yValues
end

function plotAnovaMetricBox(df::DataFrame, spec, overviewLookup::Dict{Symbol, NamedTuple})
    policies = orderedPolicies(df.policy)
    valuesByPolicy = [Float64.(df[df.policy .== policy, spec.column]) for policy in policies]
    meanValues = [mean(values) for values in valuesByPolicy]
    roles = computeHighlightRoles(meanValues, spec.higherIsBetter)

    p = plot(;
        title = metricTitleWithTest(spec, overviewLookup),
        xticks = (1:length(policies), policies),
        xrotation = 35,
        label = false,
        standardPlotKwargs()...,
    )

    midX, midY = roleSeriesData(valuesByPolicy, roles, :mid)
    !isempty(midX) && boxplot!(p, midX, midY; label = false)

    bestX, bestY = roleSeriesData(valuesByPolicy, roles, :best)
    !isempty(bestX) && boxplot!(
        p,
        bestX,
        bestY;
        label = false,
        seriescolor = anovaHighlightColors.best,
    )

    worstX, worstY = roleSeriesData(valuesByPolicy, roles, :worst)
    !isempty(worstX) && boxplot!(
        p,
        worstX,
        worstY;
        label = false,
        seriescolor = anovaHighlightColors.worst,
    )

    return p
end

function emptySummaryCell()
    return plot(
        [0.5],
        [0.5];
        seriestype = :scatter,
        markersize = 0,
        markerstrokewidth = 0,
        markercolor = :white,
        color = :white,
        label = false,
        xlims = (0.0, 1.0),
        ylims = (0.0, 1.0),
        showaxis = false,
        framestyle = :none,
        grid = false,
        left_margin = 0 * Plots.mm,
        right_margin = 0 * Plots.mm,
        top_margin = 0 * Plots.mm,
        bottom_margin = 0 * Plots.mm,
    )
end

function saveVisualSummary(outpath::String, df::DataFrame, specs, overviewLookup::Dict{Symbol, NamedTuple})
    println("##### costruendo visual summary ############")
    summarySpecs = visualSummarySpecs(specs)
    summaryPlots = [plotAnovaMetricBox(df, spec, overviewLookup) for spec in summarySpecs]
    blankCell = emptySummaryCell()
    plots = vcat(
        summaryPlots[1:3],
        [blankCell],
        summaryPlots[4:6],
        [blankCell],
        summaryPlots[7:10],
    )

    savefig(
        plot(
            plots...;
            layout = (3, 4),
            size = (4200, 2400),
            plot_title = "ANOVA Visual Summary - Boxplots",
            plot_titlefont = font(24),
            left_margin = 10 * Plots.mm,
            bottom_margin = 12 * Plots.mm,
        ),
        joinpath(outpath, "00.visual_summary.png"),
    )
    println("##### visual summary salvato ###############")
end

function saveVisualSummary(outpath::String)
    df = collectAnovaRefs(outpath)
    specs = metricSpecs()
    overviewLookup = buildAnovaOverviewLookup(buildAnovaOverview(df, specs))
    saveVisualSummary(outpath, df, specs, overviewLookup)
end

function performAnova(outpath::String)
    println("##### iniziando ANOVA summary ##############")
    df = collectAnovaRefs(outpath)
    specs = metricSpecs()
    dfOverview = buildAnovaOverview(df, specs)
    dfPolicySummary = buildPolicySummary(df, specs)
    overviewLookup = buildAnovaOverviewLookup(dfOverview)

    CSV.write(joinpath(outpath, "00.anova_overview.csv"), dfOverview)
    CSV.write(joinpath(outpath, "00.anova_policy_summary.csv"), dfPolicySummary)
    saveVisualSummary(outpath, df, specs, overviewLookup)
    println("##### ANOVA summary completato #############")
end

end
