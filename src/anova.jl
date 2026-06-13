module showanova

using CSV
using DataFrames
using Statistics
ENV["GKSwstype"] = "100" # Save plots without opening GR windows.
using StatsPlots
using Plots
using Distributions

using Main.configdata: anovaEffectColors

export performAnova, saveVisualSummary

const anovaHighlightColors = (
    best = :green3,
    worst = :crimson,
)

function naturalSortKey(label)::Tuple
    text = String(label)
    prefix = match(r"^[^\d]*", text).match          # tutto prima del primo numero
    numMatch = match(r"(\d+(?:\.\d+)?)", text)      # primo numero, anche decimale
    numVal = numMatch === nothing ? typemax(Float64) : parse(Float64, numMatch.captures[1])
    return (prefix, numVal, text)
end

function orderedPolicies(labels)
    return sort(unique(String.(labels)), by = naturalSortKey)  # usa naturalSortKey!
end

function parseCombinedScenario(label)
    match_scenario = match(r"^queue_(\d+)__slack_([0-9]+(?:\.[0-9]+)?)$", String(label))
    match_scenario === nothing && return nothing
    return (
        queue_threshold = parse(Int, match_scenario.captures[1]),
        slack_threshold = parse(Float64, match_scenario.captures[2]),
    )
end

function isCombinedAnovaCampaign(df::DataFrame)::Bool
    labels = unique(String.(df.policy))
    !isempty(labels) && all(label -> parseCombinedScenario(label) !== nothing, labels)
end

function metricSpecs()
    return [
        (column = :simtime, title = "Total Makespan", higherIsBetter = false),
        (column = :throughput, title = "Throughput", higherIsBetter = true),
        (column = :mean_wip_queue, title = "Mean Queue WIP", higherIsBetter = false),
        (column = :mean_queue_length, title = "Mean Queue Length", higherIsBetter = false),
        (column = :mean_saturation, title = "Mean Saturation", higherIsBetter = true),
        (column = :mean_makespan, title = "Mean Makespan", higherIsBetter = false),
        (column = :mean_lateness, title = "Mean Lateness", higherIsBetter = false),
        (column = :mean_tardiness, title = "Mean Tardiness", higherIsBetter = false),
        (column = :ontime_share, title = "On-Time Share", higherIsBetter = true),
        (column = :mean_queuetime, title = "Mean Queue Time", higherIsBetter = false),
        (column = :mean_processing_ratio, title = "Mean Processing Ratio", higherIsBetter = true),
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

function addCombinedScenarioColumns!(df::DataFrame)
    parsed = [parseCombinedScenario(label) for label in df.policy]
    any(isnothing, parsed) && error("Campagna combinata non valida: alcune policy non sono queue_XXX__slack_Y.Y")
    df.queue_threshold = [item.queue_threshold for item in parsed]
    df.slack_threshold = [item.slack_threshold for item in parsed]
    return df
end

function safeFTest(effectSS::Float64, effectDf::Int, residualSS::Float64, residualDf::Int)
    if effectDf <= 0 || residualDf <= 0
        return (f_statistic = NaN, p_value = NaN)
    end

    msEffect = effectSS / effectDf
    msResidual = residualSS / residualDf
    if iszero(msResidual)
        fStatistic = iszero(msEffect) ? 0.0 : Inf
        pValue = iszero(msEffect) ? 1.0 : 0.0
    else
        fStatistic = msEffect / msResidual
        pValue = 1.0 - cdf(FDist(effectDf, residualDf), fStatistic)
    end
    return (f_statistic = fStatistic, p_value = pValue)
end

function groupedEffectSS(df::DataFrame, metric::Symbol, groupcols, grandMean::Float64)::Float64
    total = 0.0
    for subdf in groupby(df, groupcols)
        values = Float64.(subdf[!, metric])
        total += length(values) * (mean(values) - grandMean)^2
    end
    return total
end

function residualSSByCell(df::DataFrame, metric::Symbol)::Float64
    total = 0.0
    for subdf in groupby(df, [:queue_threshold, :slack_threshold])
        values = Float64.(subdf[!, metric])
        cellMean = mean(values)
        total += sum((value - cellMean)^2 for value in values)
    end
    return total
end

function buildCombinedGridSummary(df::DataFrame, specs)::DataFrame
    rows = NamedTuple[]
    for spec in specs
        spec.column in propertynames(df) || continue
        for subdf in groupby(df, [:queue_threshold, :slack_threshold])
            values = Float64.(subdf[!, spec.column])
            push!(rows, (
                metric = String(spec.column),
                title = spec.title,
                queue_threshold = Int(subdf.queue_threshold[1]),
                slack_threshold = Float64(subdf.slack_threshold[1]),
                mean = mean(values),
                std = length(values) > 1 ? std(values) : 0.0,
                min = minimum(values),
                max = maximum(values),
                replications = length(values),
            ))
        end
    end
    out = DataFrame(rows)
    !isempty(out) && sort!(out, [:metric, :queue_threshold, :slack_threshold])
    return out
end

function buildCombinedAnovaOverview(df::DataFrame, specs)::DataFrame
    rows = NamedTuple[]
    queueLevels = length(unique(df.queue_threshold))
    slackLevels = length(unique(df.slack_threshold))
    cellCount = nrow(unique(df[:, [:queue_threshold, :slack_threshold]]))

    for spec in specs
        spec.column in propertynames(df) || continue
        values = Float64.(df[!, spec.column])
        totalCount = length(values)
        grandMean = mean(values)
        ssTotal = sum((value - grandMean)^2 for value in values)
        ssQueue = groupedEffectSS(df, spec.column, :queue_threshold, grandMean)
        ssSlack = groupedEffectSS(df, spec.column, :slack_threshold, grandMean)
        ssCell = groupedEffectSS(df, spec.column, [:queue_threshold, :slack_threshold], grandMean)
        ssInteraction = max(ssCell - ssQueue - ssSlack, 0.0)
        ssResidual = residualSSByCell(df, spec.column)

        dfQueue = queueLevels - 1
        dfSlack = slackLevels - 1
        dfInteraction = dfQueue * dfSlack
        dfResidual = totalCount - cellCount

        queueTest = safeFTest(ssQueue, dfQueue, ssResidual, dfResidual)
        slackTest = safeFTest(ssSlack, dfSlack, ssResidual, dfResidual)
        interactionTest = safeFTest(ssInteraction, dfInteraction, ssResidual, dfResidual)

        denominator = ssTotal > 0.0 ? ssTotal : 1.0
        push!(rows, (
            metric = String(spec.column),
            title = spec.title,
            queue_f_statistic = queueTest.f_statistic,
            queue_p_value = queueTest.p_value,
            queue_eta_squared = ssQueue / denominator,
            slack_f_statistic = slackTest.f_statistic,
            slack_p_value = slackTest.p_value,
            slack_eta_squared = ssSlack / denominator,
            interaction_f_statistic = interactionTest.f_statistic,
            interaction_p_value = interactionTest.p_value,
            interaction_eta_squared = ssInteraction / denominator,
            residual_eta_squared = ssResidual / denominator,
            queue_levels = queueLevels,
            slack_levels = slackLevels,
            grid_points = cellCount,
            replication_count = totalCount,
            residual_df = dfResidual,
        ))
    end
    return DataFrame(rows)
end

function pValueStrength(pValue::Float64)::Float64
    isnan(pValue) && return 0.0
    pValue <= 0.0 && return 16.0
    return min(-log10(pValue), 16.0)
end

function saveCombinedAnovaEffectPlot(outpath::String, overview::DataFrame)
    titles = String.(overview.title)
    effects = hcat(
        Float64.(overview.queue_eta_squared),
        Float64.(overview.slack_eta_squared),
        Float64.(overview.interaction_eta_squared),
        Float64.(overview.residual_eta_squared),
    )

    p = groupedbar(
        titles,
        effects;
        bar_position = :stack,
        label = ["Queue threshold" "Slack threshold" "Queue x Slack" "Residual"],
        color = [
            anovaEffectColors.queue anovaEffectColors.slack anovaEffectColors.interaction anovaEffectColors.residual
        ],
        ylabel = "Eta squared share",
        title = "Combined Adaptive ANOVA - Effect Shares",
        xrotation = 35,
        legend = :outertopright,
        size = (1900, 950),
        titlefontsize = 18,
        guidefontsize = 12,
        tickfontsize = 9,
        legendfontsize = 10,
        margins = 8 * Plots.mm,
    )
    savefig(p, joinpath(outpath, "00.combined_anova_effects.png"))
end

function saveCombinedAnovaPValuePlot(outpath::String, overview::DataFrame)
    titles = String.(overview.title)
    effects = ["Queue threshold", "Slack threshold", "Queue x Slack"]
    strengths = hcat(
        pValueStrength.(Float64.(overview.queue_p_value)),
        pValueStrength.(Float64.(overview.slack_p_value)),
        pValueStrength.(Float64.(overview.interaction_p_value)),
    )'

    p = heatmap(
        strengths;
        xticks = (1:length(titles), titles),
        yticks = (1:length(effects), effects),
        xrotation = 35,
        color = :viridis,
        clims = (0.0, maximum(strengths) > 0.0 ? maximum(strengths) : 1.0),
        colorbar_title = "-log10(p-value)",
        title = "Combined Adaptive ANOVA - Effect Significance",
        xlabel = "KPI",
        ylabel = "Effect",
        size = (1900, 750),
        titlefontsize = 18,
        guidefontsize = 12,
        tickfontsize = 9,
        colorbar_tickfontsize = 10,
        colorbar_titlefontsize = 11,
        margins = 8 * Plots.mm,
    )
    savefig(p, joinpath(outpath, "00.combined_anova_pvalues.png"))
end

function saveCombinedAnovaVisuals(outpath::String, overview::DataFrame)
    isempty(overview) && return
    println("##### salvando grafici ANOVA combinata #####")
    saveCombinedAnovaEffectPlot(outpath, overview)
    saveCombinedAnovaPValuePlot(outpath, overview)
end

function isOneWayAdaptiveScenario(df::DataFrame)::Bool
    labels = unique(String.(df.policy))
    !isempty(labels) && all(label -> startswith(label, "queue_") || startswith(label, "slack_"), labels)
end

function oneWayFactorInfo(df::DataFrame)
    if isOneWayAdaptiveScenario(df)
        return (
            label = "Scenario effect",
            title = "ANOVA - Scenario Explained Variation By KPI",
            effect_file = "00.anova_scenario_effects.png",
            pvalue_file = "00.anova_scenario_pvalues.png",
        )
    end

    return (
        label = "Policy effect",
        title = "ANOVA - Policy Explained Variation By KPI",
        effect_file = "00.anova_policy_effects.png",
        pvalue_file = "00.anova_policy_pvalues.png",
    )
end

function saveOneWayAnovaEffectPlot(outpath::String, overview::DataFrame, factorInfo)
    titles = String.(overview.title)
    explained = Float64.(overview.eta_squared)
    residual = 1.0 .- explained
    residual = max.(residual, 0.0)
    effects = hcat(explained, residual)

    p = groupedbar(
        titles,
        effects;
        bar_position = :stack,
        label = [factorInfo.label "Residual"],
        color = [:steelblue3 anovaEffectColors.residual],
        ylabel = "Eta squared share",
        title = factorInfo.title,
        xrotation = 35,
        legend = :outertopright,
        size = (1900, 950),
        titlefontsize = 18,
        guidefontsize = 12,
        tickfontsize = 9,
        legendfontsize = 10,
        margins = 8 * Plots.mm,
    )
    savefig(p, joinpath(outpath, factorInfo.effect_file))
end

function saveOneWayAnovaPValuePlot(outpath::String, overview::DataFrame, factorInfo)
    titles = String.(overview.title)
    strengths = reshape(pValueStrength.(Float64.(overview.p_value)), 1, :)

    p = heatmap(
        strengths;
        xticks = (1:length(titles), titles),
        yticks = (1:1, [factorInfo.label]),
        xrotation = 35,
        color = :viridis,
        clims = (0.0, maximum(strengths) > 0.0 ? maximum(strengths) : 1.0),
        colorbar_title = "-log10(p-value)",
        title = "$(factorInfo.label) Significance",
        xlabel = "KPI",
        ylabel = "Effect",
        size = (1900, 520),
        titlefontsize = 18,
        guidefontsize = 12,
        tickfontsize = 9,
        colorbar_tickfontsize = 10,
        colorbar_titlefontsize = 11,
        margins = 8 * Plots.mm,
    )
    savefig(p, joinpath(outpath, factorInfo.pvalue_file))
end

function saveOneWayAnovaVisuals(outpath::String, df::DataFrame, overview::DataFrame)
    isempty(overview) && return
    println("##### salvando grafici ANOVA standard #####")
    factorInfo = oneWayFactorInfo(df)
    saveOneWayAnovaEffectPlot(outpath, overview, factorInfo)
    saveOneWayAnovaPValuePlot(outpath, overview, factorInfo)
end

function performCombinedAnova(outpath::String, df::DataFrame, specs)
    println("##### campagna combinata rilevata: uso analisi DOE/surface #####")
    addCombinedScenarioColumns!(df)
    gridSummary = buildCombinedGridSummary(df, specs)
    overview = buildCombinedAnovaOverview(df, specs)

    CSV.write(joinpath(outpath, "00.combined_grid_summary.csv"), gridSummary)
    CSV.write(joinpath(outpath, "00.combined_anova_overview.csv"), overview)
    saveCombinedAnovaVisuals(outpath, overview)
    println("##### combined ANOVA summary completato ####")
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

function removeStaleAnovaParetoFiles(outpath::String)
    staleFiles = [
        "00.anova_pareto_policies.csv",
        "00.combined_pareto_scenarios.csv",
        "00.combined_pareto_grid.png",
    ]
    for filename in staleFiles
        rm(joinpath(outpath, filename); force = true)
    end
end

function performAnova(outpath::String)
    println("##### iniziando ANOVA summary ##############")
    df = collectAnovaRefs(outpath)
    specs = metricSpecs()
    removeStaleAnovaParetoFiles(outpath)
    if isCombinedAnovaCampaign(df)
        performCombinedAnova(outpath, df, specs)
        return
    end

    dfOverview = buildAnovaOverview(df, specs)
    dfPolicySummary = buildPolicySummary(df, specs)
    overviewLookup = buildAnovaOverviewLookup(dfOverview)

    CSV.write(joinpath(outpath, "00.anova_overview.csv"), dfOverview)
    CSV.write(joinpath(outpath, "00.anova_policy_summary.csv"), dfPolicySummary)
    saveOneWayAnovaVisuals(outpath, df, dfOverview)
    saveVisualSummary(outpath, df, specs, overviewLookup)
    println("##### ANOVA summary completato #############")
end

end
