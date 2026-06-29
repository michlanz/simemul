module showevaluation

using CSV
using DataFrames
ENV["GKSwstype"] = "100" # Save plots without opening GR windows.
using Plots
using Statistics

using Main.configdata: SimConfig, relativeHeatmapColors, surfacePlotColors, validateConfig
using Main.adaptivemetadata: METADATA_COLUMNS,
                             addAdaptiveMetadataColumns!,
                             combinedAxisColumnsFromLabels,
                             combinedAxisColumnsFromFrame,
                             scenarioAxisColumns,
                             scenarioMetadataTuple,
                             thresholdDisplayName

export performEvaluation

const INPUT_RESULTS_DIR = "results1"
const OUTPUT_EVALUATION_DIR = string(INPUT_RESULTS_DIR) * "_evaluation"

const KPI_SPECS = [
    (column = :mean_makespan, title = "Makespan", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_waiting_time, title = "Waiting Time", higher_is_better = false),
    (column = :processing_ratio, title = "Processing Ratio", higher_is_better = true),
    (column = :mean_tardiness, title = "Tardiness", higher_is_better = false),
]

const COMBINED_KPI_SPECS = [
    (column = :simtime, title = "Total Makespan", higher_is_better = false),
    (column = :mean_makespan, title = "Mean Makespan", higher_is_better = false),
    (column = :mean_tardiness, title = "Mean Tardiness", higher_is_better = false),
    (column = :mean_queuetime, title = "Mean Queue Time", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_processing_ratio, title = "Mean Processing Ratio", higher_is_better = true),
]

const GLOBAL_PARETO_SPECS = [
    (column = :simtime, title = "Total Makespan", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_processing_ratio, title = "Mean Processing Ratio", higher_is_better = true),
]

function pareto_tolerance_percent(cfg::SimConfig = SimConfig())::Float64
    return validateConfig(cfg).paretoTolerancePercent
end

function short_alternative_label(value)::String
    text = String(value)
    if occursin("__", text)
        return replace(text, "queue_" => "q", "__slack_" => "/s")
    end
    parts = split(text, "."; limit = 2)
    return length(parts) == 2 ? parts[2] : text
end

function policy_rule_name(policy_label::AbstractString)
    parts = split(String(policy_label), "."; limit = 2)
    return length(parts) == 2 ? parts[2] : String(policy_label)
end

function natural_label_key(label)::Tuple
    text = String(label)
    key = Any[]
    for match_token in eachmatch(r"\d+(?:\.\d+)?|[^\d]+", text)
        part = match_token.match
        if occursin(r"^\d+(?:\.\d+)?$", part)
            push!(key, (0, parse(Float64, part)))
        else
            push!(key, (1, lowercase(part)))
        end
    end
    return Tuple(key)
end

function numeric_prefix_key(label)::Tuple
    text = String(label)
    match_digits = match(r"^(\d+)", text)
    number = match_digits === nothing ? typemax(Int) : parse(Int, match_digits.captures[1])
    return (number, natural_label_key(text), text)
end

function policy_label_key(label)::Tuple
    text = String(label)
    match_digits = match(r"^(\d+)", text)
    if match_digits !== nothing
        return (0, numeric_prefix_key(text))
    end
    return (1, natural_label_key(text), text)
end

function safe_mean(values)::Float64
    isempty(values) && return 0.0
    return mean(values)
end

function round_seconds(seconds::Float64)::Float64
    return round(seconds; digits = 3)
end

function parse_timing_seconds(value)::Float64
    if value isa Number
        return round_seconds(Float64(value))
    end

    text = strip(String(value))
    isempty(text) && return 0.0
    text == "-" && return 0.0

    matched = match(r"^([0-9]+(?:\.[0-9]+)?)\s*(ms|s|min|h)?$", text)
    matched === nothing && error("Cannot parse timing value: $(value)")

    amount = parse(Float64, matched.captures[1])
    unit = matched.captures[2]
    seconds =
        unit === nothing || unit == "s" ? amount :
        unit == "ms" ? amount / 1000.0 :
        unit == "min" ? amount * 60.0 :
        unit == "h" ? amount * 3600.0 :
        error("Unsupported timing unit: $(unit)")
    return round_seconds(seconds)
end

function parse_int_value(value)::Int
    value isa Number && return Int(value)
    return parse(Int, strip(String(value)))
end

function normalize_timing_columns!(df::DataFrame)::DataFrame
    for col in [:timeSimulation, :timeSaving, :timeTotal]
        col in propertynames(df) || continue
        df[!, col] = [parse_timing_seconds(value) for value in df[!, col]]
    end
    return df
end

function normalize_minmax(values::Vector{Float64}; higher_is_better::Bool = false)::Vector{Float64}
    isempty(values) && return Float64[]
    min_value = minimum(values)
    max_value = maximum(values)
    if isapprox(min_value, max_value; atol = 1e-12, rtol = 1e-12)
        return fill(0.5, length(values))
    end

    normalized = [(value - min_value) / (max_value - min_value) for value in values]
    return higher_is_better ? normalized : [1.0 - value for value in normalized]
end

function sanitize_filename(name::AbstractString)::String
    return lowercase(replace(String(name), r"[^A-Za-z0-9]+" => "_"))
end

function load_campaign_timing(input_dir::String)::DataFrame
    campaign_file = joinpath(input_dir, "time_simulation.csv")
    if isfile(campaign_file)
        return normalize_timing_columns!(CSV.read(campaign_file, DataFrame))
    end

    rows = DataFrame[]
    for folder in readdir(input_dir; join = true)
        isdir(folder) || continue
        timing_file = joinpath(folder, "time_simulation.csv")
        isfile(timing_file) || continue
        df = CSV.read(timing_file, DataFrame)
        if !(:scenario in propertynames(df))
            insertcols!(df, 1, :scenario => fill(basename(folder), nrow(df)))
        end
        if !(:type in propertynames(df))
            insertcols!(df, 2, :type => fill("scenario", nrow(df)))
        end
        push!(rows, normalize_timing_columns!(df))
    end

    isempty(rows) && return DataFrame()
    return vcat(rows...; cols = :union)
end

function build_timing_overview(input_dir::String)::DataFrame
    df = load_campaign_timing(input_dir)
    if isempty(df)
        return DataFrame(
            scope = String[],
            scenario_count = Int64[],
            simulation_count = Int64[],
            total_simulation_seconds = Float64[],
            total_saving_seconds = Float64[],
            total_wall_seconds = Float64[],
            mean_seconds_per_simulation = Float64[],
            simulation_to_saving_ratio = Union{Missing, Float64}[],
        )
    end

    has_type = :type in propertynames(df)
    campaign_rows = has_type ? findall(String.(df.type) .== "campaign_total") : Int[]
    detail_rows = has_type ? findall(String.(df.type) .!= "campaign_total") : collect(1:nrow(df))
    isempty(detail_rows) && (detail_rows = collect(1:nrow(df)))

    total_simulation = round_seconds(sum(Float64.(df[detail_rows, :timeSimulation])))
    total_saving = round_seconds(sum(Float64.(df[detail_rows, :timeSaving])))
    total_wall = if !isempty(campaign_rows)
        round_seconds(Float64(df[campaign_rows[1], :timeTotal]))
    else
        round_seconds(sum(Float64.(df[detail_rows, :timeTotal])))
    end
    simulation_count = if !isempty(campaign_rows) && :simCount in propertynames(df)
        parse_int_value(df[campaign_rows[1], :simCount])
    elseif :simCount in propertynames(df)
        sum(parse_int_value.(df[detail_rows, :simCount]))
    else
        length(detail_rows)
    end

    return DataFrame(
        scope = [basename(input_dir)],
        scenario_count = [length(detail_rows)],
        simulation_count = [simulation_count],
        total_simulation_seconds = [total_simulation],
        total_saving_seconds = [total_saving],
        total_wall_seconds = [total_wall],
        mean_seconds_per_simulation = [simulation_count > 0 ? round_seconds(total_wall / simulation_count) : 0.0],
        simulation_to_saving_ratio = [total_saving > 0.0 ? round_seconds(total_simulation / total_saving) : missing],
    )
end

function save_timing_overview(input_dir::String, output_dir::String)
    CSV.write(joinpath(output_dir, "timing_overview.csv"), build_timing_overview(input_dir))
end

function combined_scenario_infos(results_dir::String)
    infos = NamedTuple[]
    for folder in readdir(results_dir; join = true)
        !isdir(folder) && continue
        label = basename(folder)
        axisColumns = scenarioAxisColumns(label)
        length(axisColumns) == 2 || continue
        isfile(joinpath(folder, "anovaRef.csv")) || continue
        push!(infos, (
            scenario = label,
            axis_columns = axisColumns,
            path = folder,
        ))
    end
    sort!(infos, by = info -> begin
        metadata = scenarioMetadataTuple(info.scenario)
        Tuple(Float64(getproperty(metadata, column)) for column in info.axis_columns)
    end)
    return infos
end

function is_combined_campaign(results_dir::String)::Bool
    labels = String[]
    for folder in readdir(results_dir; join = true)
        !isdir(folder) && continue
        isfile(joinpath(folder, "anovaRef.csv")) || continue
        push!(labels, basename(folder))
    end
    return !isempty(labels) && combinedAxisColumnsFromLabels(labels) !== nothing
end

function required_anova_summary_file(input_dir::String)::String
    if is_combined_campaign(input_dir)
        return joinpath(input_dir, "00.combined_grid_summary.csv")
    end
    return joinpath(input_dir, "00.anova_policy_summary.csv")
end

function require_anova_summary(input_dir::String)::String
    filepath = required_anova_summary_file(input_dir)
    isfile(filepath) && return filepath
    error("Evaluation requires ANOVA summary first. Missing file: $(filepath)")
end

function policy_infos(results_dir::String)
    infos = NamedTuple[]
    for folder in readdir(results_dir; join = true)
        !isdir(folder) && continue
        label = basename(folder)
        startswith(label, ".") && continue
        startswith(label, "_") && continue
        isfile(joinpath(folder, "punctuality_summary.csv")) || continue
        isfile(joinpath(folder, "punctuality_box.csv")) || continue
        isfile(joinpath(folder, "makespan_composition.csv")) || continue
        push!(infos, (policy = label, policy_rule = policy_rule_name(label), path = folder))
    end

    isempty(infos) && error("No valid policy folder found in $(results_dir)")
    sort!(infos, by = info -> policy_label_key(info.policy))
    return infos
end

function load_combined_anova_refs(infos)::DataFrame
    rows = DataFrame[]
    for info in infos
        df = CSV.read(joinpath(info.path, "anovaRef.csv"), DataFrame)
        if !("policy" in names(df))
            insertcols!(df, 1, :policy => fill(info.scenario, nrow(df)))
        end
        df.scenario = fill(info.scenario, nrow(df))
        addAdaptiveMetadataColumns!(df, :policy)
        push!(rows, df)
    end

    isempty(rows) && error("No valid combined scenario folder found")
    df = vcat(rows...)
    axisColumns = combinedAxisColumnsFromFrame(df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati")
    sort!(df, vcat(axisColumns, [:replication_id]))
    return df
end

function firstValue(subdf::SubDataFrame, column::Symbol)
    column in propertynames(subdf) || return missing
    return subdf[1, column]
end

function dataframeFromDictRows(rows::Vector{Dict{Symbol, Any}})::DataFrame
    df = DataFrame()
    for row in rows
        columns = collect(keys(row))
        values = Tuple(row[column] for column in columns)
        push!(df, NamedTuple{Tuple(columns)}(values); cols = :union)
    end
    return df
end

function combined_surface_summary(df::DataFrame)::DataFrame
    axisColumns = combinedAxisColumnsFromFrame(df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per surface summary")

    rows = Dict{Symbol, Any}[]
    for spec in COMBINED_KPI_SPECS
        spec.column in propertynames(df) || continue
        for subdf in groupby(df, axisColumns)
            values = Float64.(subdf[!, spec.column])
            alternative = :scenario in propertynames(subdf) ?
                String(firstValue(subdf, :scenario)) :
                join(["$(column)=$(firstValue(subdf, column))" for column in axisColumns], "__")
            row = Dict{Symbol, Any}(
                :metric => String(spec.column),
                :title => spec.title,
                :direction => spec.higher_is_better ? "higher is better" : "lower is better",
                :alternative => alternative,
                :mean => mean(values),
                :std => length(values) > 1 ? std(values) : 0.0,
                :min => minimum(values),
                :max => maximum(values),
                :replications => length(values),
            )
            for column in METADATA_COLUMNS
                row[column] = firstValue(subdf, column)
            end
            push!(rows, row)
        end
    end

    out = dataframeFromDictRows(rows)
    !isempty(out) && sort!(out, vcat([:metric], axisColumns))
    return out
end

function combined_best_by_kpi(summary_df::DataFrame)::DataFrame
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per best by KPI")

    rows = Dict{Symbol, Any}[]
    for spec in COMBINED_KPI_SPECS
        metric_df = summary_df[summary_df.metric .== String(spec.column), :]
        nrow(metric_df) == 0 && continue
        order = sortperm(Float64.(metric_df.mean); rev = spec.higher_is_better)
        best = metric_df[order[1], :]
        row = Dict{Symbol, Any}(
            :metric => String(spec.column),
            :title => spec.title,
            :direction => spec.higher_is_better ? "higher is better" : "lower is better",
            :alternative => String(best.alternative),
            :mean => Float64(best.mean),
            :std => Float64(best.std),
            :replications => Int(best.replications),
        )
        for column in METADATA_COLUMNS
            row[column] = column in propertynames(summary_df) ? best[column] : missing
        end
        push!(rows, row)
    end
    return dataframeFromDictRows(rows)
end

function legacyCombinedAlternative(row)::String
    queue = Int(round(Float64(row[:spt_queue_threshold])))
    slack = Float64(row[:minslack_slack_threshold])
    return "queue_$(lpad(queue, 3, '0'))__slack_$(slack)"
end

function ensure_combined_summary_metadata!(summary_df::DataFrame)::DataFrame
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati nel summary")

    if !(:alternative in propertynames(summary_df))
        if axisColumns == [:spt_queue_threshold, :minslack_slack_threshold]
            summary_df[!, :alternative] = [legacyCombinedAlternative(row) for row in eachrow(summary_df)]
        else
            summary_df[!, :alternative] = [
                join(["$(column)=$(row[column])" for column in axisColumns], "__")
                for row in eachrow(summary_df)
            ]
        end
    end

    metadataRows = [scenarioMetadataTuple(String(label)) for label in summary_df.alternative]
    for column in METADATA_COLUMNS
        values = [getproperty(row, column) for row in metadataRows]
        if column in propertynames(summary_df)
            current = summary_df[!, column]
            summary_df[!, column] = [
                ismissing(current[idx]) ? values[idx] : current[idx]
                for idx in eachindex(values)
            ]
        else
            summary_df[!, column] = values
        end
    end

    legacyColumns = [:queue_threshold, :slack_threshold]
    keepColumns = [column for column in propertynames(summary_df) if !(column in legacyColumns)]
    select!(summary_df, keepColumns)
    return summary_df
end

function combined_grid_matrix(summary_df::DataFrame, metric::Symbol)
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per grid matrix")
    yColumn, xColumn = axisColumns
    metric_df = summary_df[summary_df.metric .== String(metric), :]
    yValues = sort(unique(Float64.(metric_df[!, yColumn])))
    xValues = sort(unique(Float64.(metric_df[!, xColumn])))
    matrix = fill(NaN, length(yValues), length(xValues))
    yIdx = Dict(value => idx for (idx, value) in enumerate(yValues))
    xIdx = Dict(value => idx for (idx, value) in enumerate(xValues))

    for row in eachrow(metric_df)
        yValue = Float64(row[yColumn])
        xValue = Float64(row[xColumn])
        matrix[yIdx[yValue], xIdx[xValue]] = Float64(row.mean)
    end
    return yValues, xValues, matrix, yColumn, xColumn
end

function surface_color_scale(higher_is_better::Bool)
    colors = higher_is_better ?
        [surfacePlotColors.worse, surfacePlotColors.neutral, surfacePlotColors.better] :
        [surfacePlotColors.better, surfacePlotColors.neutral, surfacePlotColors.worse]
    return cgrad(colors)
end

function save_combined_surface_plot(summary_df::DataFrame, spec, output_dir::String)
    yValues, xValues, matrix, yColumn, xColumn = combined_grid_matrix(summary_df, spec.column)
    p = surface(
        xValues,
        yValues,
        matrix;
        xlabel = thresholdDisplayName(xColumn),
        ylabel = thresholdDisplayName(yColumn),
        zlabel = spec.title,
        title = "$(spec.title) Surface",
        color = surface_color_scale(spec.higher_is_better),
        colorbar_title = spec.title,
        camera = (78, 22),
        size = (1300, 900),
        titlefontsize = 18,
        guidefontsize = 13,
        tickfontsize = 10,
        colorbar_tickfontsize = 10,
    )
    savefig(p, joinpath(output_dir, "surface_$(sanitize_filename(String(spec.column))).png"))
end

function combined_contour_plot(summary_df::DataFrame, spec; compact::Bool = false)
    yValues, xValues, matrix, yColumn, xColumn = combined_grid_matrix(summary_df, spec.column)
    return heatmap(
        xValues,
        yValues,
        matrix;
        xlabel = compact ? "" : thresholdDisplayName(xColumn),
        ylabel = compact ? "" : thresholdDisplayName(yColumn),
        title = compact ? spec.title : "$(spec.title): Mean By $(thresholdDisplayName(yColumn)) And $(thresholdDisplayName(xColumn))",
        color = surface_color_scale(spec.higher_is_better),
        colorbar_title = compact ? "" : spec.title,
        size = compact ? (1100, 800) : (1200, 820),
        titlefontsize = compact ? 17 : 16,
        guidefontsize = compact ? 13 : 12,
        tickfontsize = compact ? 11 : 10,
        colorbar_tickfontsize = compact ? 12 : 10,
        colorbar_titlefontsize = compact ? 12 : 10,
        margins = compact ? 8Plots.mm : 6Plots.mm,
    )
end

function save_combined_contour_plot(summary_df::DataFrame, spec, output_dir::String)
    p = combined_contour_plot(summary_df, spec)
    heatmap_dir = joinpath(output_dir, "heatmaps")
    mkpath(heatmap_dir)
    savefig(p, joinpath(heatmap_dir, "contour_$(sanitize_filename(String(spec.column))).png"))
end

function combined_dashboard_note_plot(summary_df::DataFrame)
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per dashboard")
    yColumn, xColumn = axisColumns
    p = plot(
        xlims = (0, 1),
        ylims = (0, 1),
        framestyle = :none,
        legend = false,
        grid = false,
        ticks = false,
        background_color = :white,
    )
    annotate!(p, 0.5, 0.58, text("Legend", 24, :center, :black))
    annotate!(p, 0.5, 0.46, text("Each cell is the mean over replications", 20, :center, :black))
    annotate!(p, 0.5, 0.36, text("X = $(thresholdDisplayName(xColumn)), Y = $(thresholdDisplayName(yColumn))", 20, :center, :black))
    annotate!(p, 0.5, 0.26, text("Green = better for that KPI", 20, :center, :black))
    annotate!(p, 0.5, 0.16, text("Red = worse for that KPI", 20, :center, :black))
    return p
end

function save_combined_dashboard(summary_df::DataFrame, output_dir::String)
    plots = [combined_contour_plot(summary_df, spec; compact = true) for spec in COMBINED_KPI_SPECS if String(spec.column) in unique(String.(summary_df.metric))]
    push!(plots, combined_dashboard_note_plot(summary_df))
    dashboard = plot(
        plots...;
        layout = (3, 3),
        size = (3600, 2800),
        plot_title = "Combined Adaptive Grid Dashboard",
        plot_titlefontsize = 30,
        background_color = :white,
    )
    savefig(dashboard, joinpath(output_dir, "dash_combined_surface.png"))
end

function build_combined_report(output_path::String, input_dir::String, output_dir::String, summary_df::DataFrame, best_df::DataFrame, pareto_exact::DataFrame, pareto_tolerance::DataFrame, pareto_cuts::DataFrame; tolerance_percent::Float64)
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisText = axisColumns === nothing ?
        "adaptive threshold columns" :
        join(thresholdDisplayName.(axisColumns), " and ")
    io = IOBuffer()
    println(io, "# Combined Adaptive Surface Report")
    println(io)
    println(io, "## Summary")
    println(io, "- input directory: `$(input_dir)`")
    println(io, "- output directory: `$(output_dir)`")
    println(io, "- scenarios are parsed through policy-specific axes: $(axisText)")
    println(io, "- this report evaluates this campaign only; it does not compare SPT-first against SLACK-first")
    println(io, "- dashboard: `dash_combined_surface.png`")
    println(io, "- contour heatmaps are saved in `heatmaps/`")
    println(io, "- exact Pareto is computed without tolerance")
    println(io, "- equivalence band around exact Pareto: `$(tolerance_percent)%`")
    println(io)
    println(io, "## Best Grid Point By KPI")
    println(io, markdown_table(best_df; max_rows = nrow(best_df)))
    println(io)
    println(io, "## Global Exact Pareto")
    pareto_rows = pareto_exact[pareto_exact.pareto_efficient .== true, :]
    println(io, markdown_table(pareto_rows; max_rows = min(nrow(pareto_rows), 20)))
    println(io)
    println(io, "## Within Pareto Tolerance")
    tolerance_rows = pareto_tolerance[pareto_tolerance.within_pareto_tolerance .== true, :]
    println(io, markdown_table(tolerance_rows; max_rows = min(nrow(tolerance_rows), 20)))
    println(io)
    println(io, "## Pareto By 2D Cut")
    cut_summary = DataFrame(
        cut = ["simtime_ontime", "simtime_processing", "ontime_processing", "any_cut", "all_cuts"],
        pareto_count = [
            count(pareto_cuts.pareto_simtime_ontime),
            count(pareto_cuts.pareto_simtime_processing),
            count(pareto_cuts.pareto_ontime_processing),
            count(pareto_cuts.pareto_any_cut),
            count(pareto_cuts.pareto_all_cuts),
        ],
    )
    println(io, markdown_table(cut_summary; max_rows = nrow(cut_summary)))
    println(io)
    println(io, "## Reading Notes")
    println(io, "- Surface plots show the average KPI over replications for every adaptive threshold pair.")
    println(io, "- Contour heatmaps are the readable control view for the same surfaces.")
    println(io, "- `combined_global_pareto_plot.png` shows global 3D Pareto points and highlights the Pareto points for each 2D cut.")
    println(io, "- `combined_pareto_grid.png` marks exact global 3D Pareto grid points in green and post-Pareto within-tolerance alternatives in yellow.")
    println(io, "- Green always means better for that KPI; red means worse.")
    println(io, "- Lower-is-better KPIs: total makespan, mean makespan, tardiness, and queue time.")
    println(io, "- Higher-is-better KPIs: on-time share and processing ratio.")
    write(output_path, String(take!(io)))
end

function perform_combined_evaluation(; input_dir::String, output_dir::String)
    println("##### starting combined adaptive evaluation ################")
    tolerance_percent = pareto_tolerance_percent()
    anova_summary_file = require_anova_summary(input_dir)
    summary_df = CSV.read(anova_summary_file, DataFrame)
    ensure_combined_summary_metadata!(summary_df)
    best_df = combined_best_by_kpi(summary_df)
    pareto_source = combined_summary_to_global_pareto_source(summary_df)
    pareto_exact = global_pareto_table(pareto_source)
    pareto_tolerance = pareto_tolerance_table(
        pareto_source,
        pareto_exact;
        tolerance_percent = tolerance_percent,
    )
    pareto_cuts = combined_pareto_cuts_table(pareto_source)
    pareto_tolerance_cuts = combined_within_tolerance_cuts_table(pareto_tolerance)
    add_within_tolerance_cut_flags!(pareto_tolerance, pareto_tolerance_cuts)

    reset_output_dir(output_dir)
    save_timing_overview(input_dir, output_dir)
    CSV.write(joinpath(output_dir, "combined_surface_summary.csv"), summary_df)
    CSV.write(joinpath(output_dir, "combined_best_by_kpi.csv"), best_df)
    CSV.write(joinpath(output_dir, "combined_pareto_exact.csv"), pareto_exact)
    CSV.write(joinpath(output_dir, "combined_pareto_within_tolerance.csv"), pareto_tolerance)
    CSV.write(joinpath(output_dir, "combined_pareto_cuts.csv"), pareto_cuts)
    CSV.write(joinpath(output_dir, "combined_pareto_within_tolerance_cuts.csv"), pareto_tolerance_cuts)

    for spec in COMBINED_KPI_SPECS
        String(spec.column) in unique(String.(summary_df.metric)) || continue
        save_combined_surface_plot(summary_df, spec, output_dir)
        save_combined_contour_plot(summary_df, spec, output_dir)
    end
    save_combined_global_pareto_plot(
        pareto_tolerance,
        pareto_cuts,
        output_dir;
        tolerance_percent = tolerance_percent,
        filename = "combined_global_pareto_plot.png",
        plot_title = "Combined Exact Pareto And $(tolerance_percent)% Equivalent Alternatives",
    )
    save_combined_pareto_grid(summary_df, pareto_exact, pareto_tolerance, pareto_cuts, output_dir; tolerance_percent = tolerance_percent)
    save_combined_dashboard(summary_df, output_dir)
    build_combined_report(
        joinpath(output_dir, "report.md"),
        input_dir,
        output_dir,
        summary_df,
        best_df,
        pareto_exact,
        pareto_tolerance,
        pareto_cuts;
        tolerance_percent = tolerance_percent,
    )
    println("##### combined evaluation outputs saved in $(output_dir) #####")
end

function sort_policy_code!(df::DataFrame)
    policy_order = Dict(policy => idx for (idx, policy) in enumerate(sort(unique(String.(df.policy)); by = policy_label_key)))
    code_order = Dict(code => idx for (idx, code) in enumerate(sort(unique(String.(df.client_code)); by = natural_label_key)))
    df.__policy_order = [policy_order[String(policy)] for policy in df.policy]
    df.__code_order = [code_order[String(code)] for code in df.client_code]
    sort!(df, [:__code_order, :__policy_order])
    select!(df, Not([:__policy_order, :__code_order]))
    return df
end

function load_policy_tables(info)
    return (
        punctuality_box = CSV.read(joinpath(info.path, "punctuality_box.csv"), DataFrame),
        punctuality_summary = CSV.read(joinpath(info.path, "punctuality_summary.csv"), DataFrame),
        ontime_share = CSV.read(joinpath(info.path, "ontime_share.csv"), DataFrame),
        queuetime_box = CSV.read(joinpath(info.path, "queuetime_box.csv"), DataFrame),
        makespan_composition = CSV.read(joinpath(info.path, "makespan_composition.csv"), DataFrame),
    )
end

function component_value(components::DataFrame, client_code::String, component::String)::Float64
    subdf = components[(components.client_code .== client_code) .& (components.component .== component), :]
    nrow(subdf) == 0 && return 0.0
    return Float64(subdf.mean_time[1])
end

function build_policy_code_kpis(infos)::DataFrame
    rows = NamedTuple[]

    for info in infos
        tables = load_policy_tables(info)
        codes = sort(unique(String.(tables.punctuality_summary.client_code)); by = natural_label_key)

        for code in codes
            punctuality = tables.punctuality_summary[tables.punctuality_summary.client_code .== code, :]
            ontime = tables.ontime_share[tables.ontime_share.client_code .== code, :]
            queuetime = tables.queuetime_box[tables.queuetime_box.client_code .== code, :]
            punctuality_events = tables.punctuality_box[tables.punctuality_box.client_code .== code, :]

            mean_makespan = Float64(punctuality.mean_makespan[1])
            mean_processing_time = component_value(tables.makespan_composition, code, "PROCESSING")

            push!(rows, (
                policy = info.policy,
                policy_rule = info.policy_rule,
                client_code = code,
                mean_makespan = mean_makespan,
                processing_ratio = mean_makespan > 0.0 ? mean_processing_time / mean_makespan : 0.0,
                ontime_share = nrow(ontime) == 0 ? 0.0 : Float64(ontime.ontime_percent[1]),
                mean_tardiness = Float64(punctuality.mean_tardiness[1]),
                mean_waiting_time = safe_mean(Float64.(queuetime.waiting_time)),
                sample_count = nrow(punctuality_events),
            ))
        end
    end

    df = DataFrame(rows)
    sort_policy_code!(df)
    return df
end

function ratio_denominator(reference::Float64, group_values::Vector{Float64})::Float64
    abs(reference) > 1e-12 && return reference
    fallback = safe_mean(abs.(group_values))
    return fallback > 1e-12 ? fallback : 0.0
end

function policy_code_ratio(value::Float64, reference::Float64, group_values::Vector{Float64})::Float64
    denominator = ratio_denominator(reference, group_values)
    denominator == 0.0 && return 100.0
    return 100.0 * value / denominator
end

function policy_code_ratio_matrix(df::DataFrame, kpi::Symbol; focus::Symbol = :codecentric)
    policies = sort(unique(String.(df.policy)); by = policy_label_key)
    codes = sort(unique(String.(df.client_code)); by = natural_label_key)
    matrix = fill(100.0, length(policies), length(codes))
    spec = only([spec for spec in KPI_SPECS if spec.column == kpi])

    for (policy_idx, policy) in enumerate(policies)
        for (code_idx, code) in enumerate(codes)
            value_row = df[(df.policy .== policy) .& (df.client_code .== code), :]
            nrow(value_row) == 0 && continue
            value = Float64(value_row[1, kpi])

            if focus == :codecentric
                group = df[df.client_code .== code, :]
            elseif focus == :policyfocused
                group = df[df.policy .== policy, :]
            else
                error("Invalid heatmap focus: $(focus)")
            end

            group_values = Float64.(group[!, kpi])
            reference = safe_mean(group_values)
            matrix[policy_idx, code_idx] = policy_code_ratio(value, reference, group_values)
        end
    end

    return policies, codes, matrix, spec
end

function ratio_clims(matrix::Matrix{Float64})
    lower = minimum(matrix)
    upper = maximum(matrix)
    if isapprox(lower, upper; atol = 1e-12, rtol = 1e-12)
        lower -= 1.0
        upper += 1.0
    end
    return (lower, upper)
end

function ratio_color_scale(higher_is_better::Bool, clims::Tuple{Float64, Float64})
    lower, upper = clims
    center = (100.0 - lower) / (upper - lower)
    center = clamp(center, 0.01, 0.99)
    colors = higher_is_better ?
        [relativeHeatmapColors.worse, relativeHeatmapColors.neutral, relativeHeatmapColors.better] :
        [relativeHeatmapColors.better, relativeHeatmapColors.neutral, relativeHeatmapColors.worse]
    return cgrad(colors, [0.0, center, 1.0])
end

function focus_denominator_label(focus::Symbol)::String
    focus == :codecentric && return "code avg."
    focus == :policyfocused && return "policy avg."
    error("Invalid heatmap focus: $(focus)")
end

function focus_title_label(focus::Symbol)::String
    focus == :codecentric && return "Code Average"
    focus == :policyfocused && return "Policy Average"
    error("Invalid heatmap focus: $(focus)")
end

function heatmap_plot(df::DataFrame, kpi::Symbol; compact::Bool = false, focus::Symbol = :codecentric)
    policies, codes, matrix, spec = policy_code_ratio_matrix(df, kpi; focus = focus)
    clims = ratio_clims(matrix)
    color_scale = ratio_color_scale(spec.higher_is_better, clims)
    denominator_label = focus_denominator_label(focus)
    title_denominator = focus_title_label(focus)

    return heatmap(
        matrix;
        xlabel = compact ? "" : "Product Code",
        ylabel = compact ? "" : "Policy",
        title = compact ? spec.title : "$(spec.title): Code Average Under Policy / $(title_denominator)",
        xticks = (1:length(codes), codes),
        yticks = (1:length(policies), policies),
        xrotation = compact ? 45 : 35,
        yflip = true,
        color = color_scale,
        clims = clims,
        colorbar_title = compact ? "" : "Code avg. under policy / $(denominator_label) (%)",
        titlefontsize = compact ? 18 : 14,
        tickfontsize = compact ? 14 : 9,
        guidefontsize = compact ? 15 : 11,
        colorbar_tickfontsize = compact ? 16 : 9,
        colorbar_titlefontsize = compact ? 15 : 11,
        size = compact ? (1250, 860) : (1200, 760),
        margins = compact ? 10Plots.mm : 6Plots.mm,
    )
end

function save_heatmap(df::DataFrame, kpi::Symbol, output_dir::String; focus::Symbol = :codecentric)
    p = heatmap_plot(df, kpi; focus = focus)
    prefix = focus == :codecentric ? "codecentric" : "policyfocused"
    filename = "heatmap_$(prefix)_$(sanitize_filename(String(kpi))).png"
    heatmap_dir = joinpath(output_dir, "heatmaps")
    mkpath(heatmap_dir)

    savefig(p, joinpath(heatmap_dir, filename))
end

function dashboard_note_plot(; focus::Symbol = :codecentric)
    denominator_label = focus == :codecentric ? "code average" : "policy average"
    p = plot(
        xlims = (0, 1),
        ylims = (0, 1),
        framestyle = :none,
        legend = false,
        grid = false,
        ticks = false,
        background_color = :white,
    )
    annotate!(p, 0.5, 0.60, text("Legend", 24, :center, :black))
    annotate!(p, 0.5, 0.48, text("Cell value = code average under policy / $(denominator_label)", 21, :center, :black))
    annotate!(p, 0.5, 0.39, text("100% = $(denominator_label) reference", 21, :center, :black))
    annotate!(p, 0.5, 0.30, text("Green = better for that KPI", 21, :center, :black))
    annotate!(p, 0.5, 0.21, text("Red = worse for that KPI", 21, :center, :black))
    return p
end

function save_dashboard(df::DataFrame, output_dir::String; focus::Symbol = :codecentric)
    plots = [heatmap_plot(df, spec.column; compact = true, focus = focus) for spec in KPI_SPECS]
    push!(plots, dashboard_note_plot(; focus = focus))
    filename = focus == :codecentric ? "dash_code.png" : "dash_policy.png"
    title = focus == :codecentric ? "Code-Level Policy Performance Dashboard" : "Policy-Focused Code Preference Dashboard"
    dashboard = plot(
        plots...;
        layout = (3, 2),
        size = (3000, 3300),
        plot_title = title,
        plot_titlefontsize = 30,
        background_color = :white,
    )

    savefig(dashboard, joinpath(output_dir, filename))
end

function metric_spec(column::Symbol)
    matches = [spec for spec in GLOBAL_PARETO_SPECS if spec.column == column]
    isempty(matches) && error("Unknown global Pareto metric: $(column)")
    return only(matches)
end

function policy_summary_to_global_pareto_source(summary_df::DataFrame)::DataFrame
    rows = Dict{Symbol, Any}[]
    for policy_df in groupby(summary_df, :policy)
        policy = String(policy_df.policy[1])
        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(policy_df))
        missing_metrics = [spec.column for spec in GLOBAL_PARETO_SPECS if !haskey(values, spec.column)]
        isempty(missing_metrics) || error("Missing global Pareto metrics for $(policy): $(missing_metrics)")

        firstRow = policy_df[1, :]
        row = Dict{Symbol, Any}(
            :alternative => policy,
            :policy => policy,
            :policy_rule => policy_rule_name(policy),
            :simtime => values[:simtime],
            :ontime_share => values[:ontime_share],
            :mean_processing_ratio => values[:mean_processing_ratio],
        )
        for column in METADATA_COLUMNS
            row[column] = column in propertynames(summary_df) ? firstRow[column] : missing
        end
        push!(rows, row)
    end
    df = dataframeFromDictRows(rows)
    sort!(df, :policy; by = policy_label_key)
    return df
end

function combined_summary_to_global_pareto_source(summary_df::DataFrame)::DataFrame
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per Pareto source")
    keyColumns = :alternative in propertynames(summary_df) ? [:alternative] : axisColumns
    rows = Dict{Symbol, Any}[]
    key_df = unique(summary_df[:, keyColumns])
    sort!(key_df, keyColumns)

    for key in eachrow(key_df)
        mask = trues(nrow(summary_df))
        for column in keyColumns
            mask .&= summary_df[!, column] .== key[column]
        end
        scenario_df = summary_df[mask, :]
        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(scenario_df))
        missing_metrics = [spec.column for spec in GLOBAL_PARETO_SPECS if !haskey(values, spec.column)]
        alternative = if :alternative in propertynames(summary_df)
            String(key.alternative)
        elseif axisColumns == [:spt_queue_threshold, :minslack_slack_threshold]
            queue = Int(round(Float64(key[:spt_queue_threshold])))
            slack = Float64(key[:minslack_slack_threshold])
            "queue_$(lpad(queue, 3, '0'))__slack_$(slack)"
        else
            join(["$(column)=$(key[column])" for column in axisColumns], "__")
        end
        isempty(missing_metrics) || error("Missing global Pareto metrics for $(alternative): $(missing_metrics)")

        firstRow = scenario_df[1, :]
        row = Dict{Symbol, Any}(
            :alternative => alternative,
            :simtime => values[:simtime],
            :ontime_share => values[:ontime_share],
            :mean_processing_ratio => values[:mean_processing_ratio],
        )
        for column in METADATA_COLUMNS
            row[column] = column in propertynames(summary_df) ? firstRow[column] : missing
        end
        push!(rows, row)
    end
    return dataframeFromDictRows(rows)
end

function dominates_alternative(candidate, target, specs)::Bool
    nonworse = true
    better = false

    for spec in specs
        candidate_value = Float64(candidate[spec.column])
        target_value = Float64(target[spec.column])

        if spec.higher_is_better
            nonworse &= candidate_value >= target_value
            better |= candidate_value > target_value
        else
            nonworse &= candidate_value <= target_value
            better |= candidate_value < target_value
        end
    end

    return nonworse && better
end

function pareto_flags(df::DataFrame, specs)::Vector{Bool}
    flags = trues(nrow(df))
    for target_idx in 1:nrow(df)
        for candidate_idx in 1:nrow(df)
            candidate_idx == target_idx && continue
            if dominates_alternative(df[candidate_idx, :], df[target_idx, :], specs)
                flags[target_idx] = false
                break
            end
        end
    end
    return flags
end

function add_global_pareto_score!(df::DataFrame)
    score = zeros(nrow(df))
    for spec in GLOBAL_PARETO_SPECS
        score .+= normalize_minmax(Float64.(df[!, spec.column]); higher_is_better = spec.higher_is_better)
    end
    score ./= length(GLOBAL_PARETO_SPECS)
    df.composite_score = score
    return df
end

function global_pareto_table(source_df::DataFrame)::DataFrame
    df = copy(source_df)
    df.pareto_mode = fill("exact", nrow(df))
    df.tolerance_percent = fill(0.0, nrow(df))
    df.metric_set = fill(join(String.(getfield.(GLOBAL_PARETO_SPECS, :column)), ", "), nrow(df))
    df.pareto_efficient = pareto_flags(df, GLOBAL_PARETO_SPECS)
    add_global_pareto_score!(df)

    sort!(df, [:pareto_efficient, :composite_score]; rev = [true, true])
    ranks = zeros(Int, nrow(df))
    efficient_rows = findall(df.pareto_efficient)
    for (rank, row_idx) in enumerate(efficient_rows)
        ranks[row_idx] = rank
    end
    df.pareto_rank = ranks
    return df
end

function combined_pareto_cuts_table(source_df::DataFrame)::DataFrame
    df = copy(source_df)
    simtime_ontime = pareto_flags(df, [metric_spec(:simtime), metric_spec(:ontime_share)])
    simtime_processing = pareto_flags(df, [metric_spec(:simtime), metric_spec(:mean_processing_ratio)])
    ontime_processing = pareto_flags(df, [metric_spec(:ontime_share), metric_spec(:mean_processing_ratio)])

    out = DataFrame(
        alternative = String.(df.alternative),
        simtime = Float64.(df.simtime),
        ontime_share = Float64.(df.ontime_share),
        mean_processing_ratio = Float64.(df.mean_processing_ratio),
        pareto_simtime_ontime = simtime_ontime,
        pareto_simtime_processing = simtime_processing,
        pareto_ontime_processing = ontime_processing,
        pareto_any_cut = simtime_ontime .| simtime_processing .| ontime_processing,
        pareto_all_cuts = simtime_ontime .& simtime_processing .& ontime_processing,
    )
    for column in METADATA_COLUMNS
        out[!, column] = column in propertynames(df) ? df[!, column] : fill(missing, nrow(df))
    end
    return out
end

function combined_within_tolerance_cuts_table(tolerance_df::DataFrame)::DataFrame
    within_df = tolerance_df[tolerance_df.within_pareto_tolerance .== true, :]

    if nrow(within_df) == 0
        out = DataFrame(
            alternative = String[],
            within_pareto_simtime_ontime = Bool[],
            within_pareto_simtime_processing = Bool[],
            within_pareto_ontime_processing = Bool[],
            within_pareto_any_cut = Bool[],
            within_pareto_all_cuts = Bool[],
        )
        for column in METADATA_COLUMNS
            out[!, column] = Any[]
        end
        return out
    end

    simtime_ontime = pareto_flags(within_df, [metric_spec(:simtime), metric_spec(:ontime_share)])
    simtime_processing = pareto_flags(within_df, [metric_spec(:simtime), metric_spec(:mean_processing_ratio)])
    ontime_processing = pareto_flags(within_df, [metric_spec(:ontime_share), metric_spec(:mean_processing_ratio)])

    out = DataFrame(
        alternative = String.(within_df.alternative),
        within_pareto_simtime_ontime = simtime_ontime,
        within_pareto_simtime_processing = simtime_processing,
        within_pareto_ontime_processing = ontime_processing,
        within_pareto_any_cut = simtime_ontime .| simtime_processing .| ontime_processing,
        within_pareto_all_cuts = simtime_ontime .& simtime_processing .& ontime_processing,
    )
    for column in METADATA_COLUMNS
        out[!, column] = column in propertynames(within_df) ? within_df[!, column] : fill(missing, nrow(within_df))
    end
    return out
end

function add_within_tolerance_cut_flags!(tolerance_df::DataFrame, tolerance_cuts_df::DataFrame)::DataFrame
    all_cuts_lookup = Dict(String(row.alternative) => Bool(row.within_pareto_all_cuts) for row in eachrow(tolerance_cuts_df))
    any_cut_lookup = Dict(String(row.alternative) => Bool(row.within_pareto_any_cut) for row in eachrow(tolerance_cuts_df))

    tolerance_df.within_pareto_any_cut = [
        get(any_cut_lookup, String(row.alternative), false)
        for row in eachrow(tolerance_df)
    ]

    tolerance_df.within_pareto_all_cuts = [
        get(all_cuts_lookup, String(row.alternative), false)
        for row in eachrow(tolerance_df)
    ]

    return tolerance_df
end

function pareto_gap_percent(candidate, reference, spec)::Float64
    candidate_value = Float64(candidate[spec.column])
    reference_value = Float64(reference[spec.column])
    denominator = max(abs(reference_value), 1e-12)

    if spec.higher_is_better
        candidate_value >= reference_value && return 0.0
        return 100.0 * (reference_value - candidate_value) / denominator
    end

    candidate_value <= reference_value && return 0.0
    return 100.0 * (candidate_value - reference_value) / denominator
end

function pareto_tolerance_table(source_df::DataFrame, exact_df::DataFrame; tolerance_percent::Float64)::DataFrame
    df = copy(source_df)
    exact_lookup = Dict(String(row.alternative) => Bool(row.pareto_efficient) for row in eachrow(exact_df))
    exact_front = exact_df[exact_df.pareto_efficient .== true, :]
    nrow(exact_front) > 0 || error("No exact Pareto alternatives found")

    nearest = String[]
    max_gaps = Float64[]
    within = Bool[]
    exact_flags = Bool[]

    for candidate in eachrow(df)
        best_reference = ""
        best_gap = Inf

        for reference in eachrow(exact_front)
            gaps = [pareto_gap_percent(candidate, reference, spec) for spec in GLOBAL_PARETO_SPECS]
            max_gap = maximum(gaps)
            if max_gap < best_gap
                best_gap = max_gap
                best_reference = String(reference.alternative)
            end
        end

        is_exact = get(exact_lookup, String(candidate.alternative), false)
        push!(nearest, best_reference)
        push!(max_gaps, best_gap)
        push!(within, is_exact || best_gap <= tolerance_percent)
        push!(exact_flags, is_exact)
    end

    df.pareto_mode = fill("within_tolerance", nrow(df))
    df.tolerance_percent = fill(tolerance_percent, nrow(df))
    df.metric_set = fill(join(String.(getfield.(GLOBAL_PARETO_SPECS, :column)), ", "), nrow(df))
    df.exact_pareto = exact_flags
    df.within_pareto_tolerance = within
    df.nearest_pareto_alternative = nearest
    df.max_gap_from_nearest_pareto_percent = max_gaps
    add_global_pareto_score!(df)

    sort!(df, [:within_pareto_tolerance, :exact_pareto, :max_gap_from_nearest_pareto_percent, :composite_score]; rev = [true, true, false, true])
    ranks = zeros(Int, nrow(df))
    selected_rows = findall(df.within_pareto_tolerance)
    for (rank, row_idx) in enumerate(selected_rows)
        ranks[row_idx] = rank
    end
    df.tolerance_rank = ranks
    return df
end

function visible_frontier_2d(df::DataFrame, xcol::Symbol, ycol::Symbol)::DataFrame
    nrow(df) <= 1 && return copy(df)

    frontier = df[pareto_flags(df, [metric_spec(xcol), metric_spec(ycol)]), :]
    sort!(frontier, [xcol, ycol])
    return frontier
end

function best_metric_row_index(df::DataFrame, column::Symbol)::Int
    spec = metric_spec(column)
    values = Float64.(df[!, column])
    return spec.higher_is_better ? argmax(values) : argmin(values)
end

function informative_label_rows(df::DataFrame, xcol::Symbol, ycol::Symbol)::DataFrame
    nrow(df) == 0 && return df[[], :]

    selected_idxs = Int[]
    push!(selected_idxs, best_metric_row_index(df, xcol))
    push!(selected_idxs, best_metric_row_index(df, ycol))

    if :composite_score in propertynames(df)
        compromise_pool = :within_pareto_tolerance in propertynames(df) ?
            findall(Bool.(df.within_pareto_tolerance)) :
            collect(1:nrow(df))
        isempty(compromise_pool) && (compromise_pool = collect(1:nrow(df)))
        pool_scores = Float64.(df[compromise_pool, :composite_score])
        push!(selected_idxs, compromise_pool[argmax(pool_scores)])
    end

    unique_idxs = Int[]
    seen = Set{String}()
    for idx in selected_idxs
        alternative = String(df[idx, :alternative])
        alternative in seen && continue
        push!(unique_idxs, idx)
        push!(seen, alternative)
    end

    return df[unique_idxs, :]
end

function pareto_view_plot(df::DataFrame, xcol::Symbol, ycol::Symbol; xlabel::String, ylabel::String, title::String, tolerance_percent::Float64)
    cut_flags = pareto_flags(df, [metric_spec(xcol), metric_spec(ycol)])
    is_global_pareto = Bool.(df.exact_pareto)

    has_within_all_cuts = :within_pareto_all_cuts in propertynames(df)
    is_within_all_cuts = has_within_all_cuts ?
        Bool.(df.within_pareto_all_cuts) :
        fill(false, nrow(df))

    outside = df[(df.within_pareto_tolerance .== false) .& (.!cut_flags), :]
    near = df[(df.within_pareto_tolerance .== true) .& (.!cut_flags), :]
    cut_pareto = df[cut_flags, :]
    global_pareto = df[is_global_pareto, :]
    within_all_cuts = df[is_within_all_cuts, :]
    label_rows = informative_label_rows(df, xcol, ycol)

    p = scatter(;
        xlabel = xlabel,
        ylabel = ylabel,
        title = title,
        legend = :outertopright,
        grid = true,
        gridalpha = 0.18,
        framestyle = :box,
        titlefontsize = 14,
        guidefontsize = 10,
        tickfontsize = 8,
        legendfontsize = 8,
    )

    nrow(outside) > 0 && scatter!(
        p,
        Float64.(outside[!, xcol]),
        Float64.(outside[!, ycol]);
        label = "Outside tolerance",
        markercolor = :gray75,
        markerstrokecolor = :gray35,
        markersize = 6,
    )

    nrow(near) > 0 && scatter!(
        p,
        Float64.(near[!, xcol]),
        Float64.(near[!, ycol]);
        label = "Within $(tolerance_percent)% of global Pareto",
        markercolor = :gold,
        markerstrokecolor = :darkorange,
        markersize = 7,
    )

    nrow(cut_pareto) > 0 && scatter!(
        p,
        Float64.(cut_pareto[!, xcol]),
        Float64.(cut_pareto[!, ycol]);
        label = "Cut Pareto",
        markercolor = :green3,
        markerstrokecolor = :green3,
        markersize = 7,
    )

    nrow(global_pareto) > 0 && scatter!(
        p,
        Float64.(global_pareto[!, xcol]),
        Float64.(global_pareto[!, ycol]);
        label = "Global Pareto",
        markershape = :circle,
        markercolor = :black,
        markerstrokecolor = :black,
        markersize = 3,
    )

    nrow(within_all_cuts) > 0 && scatter!(
        p,
        Float64.(within_all_cuts[!, xcol]),
        Float64.(within_all_cuts[!, ycol]);
        label = "Within tolerance all cuts",
        markershape = :star5,
        markercolor = :black,
        markerstrokecolor = :black,
        markerstrokewidth = 1.0,
        markersize = 7,
    )

    for row in eachrow(label_rows)
        annotate!(
            p,
            Float64(row[xcol]),
            Float64(row[ycol]),
            text(short_alternative_label(row.alternative), 8, :left, :black),
        )
    end

    return p
end

function pareto_cut_column(xcol::Symbol, ycol::Symbol)::Symbol
    pair = Set([xcol, ycol])
    pair == Set([:simtime, :ontime_share]) && return :pareto_simtime_ontime
    pair == Set([:simtime, :mean_processing_ratio]) && return :pareto_simtime_processing
    pair == Set([:ontime_share, :mean_processing_ratio]) && return :pareto_ontime_processing
    error("Unsupported Pareto cut: $(xcol), $(ycol)")
end

function combined_pareto_view_plot(df::DataFrame, cuts_df::DataFrame, xcol::Symbol, ycol::Symbol; xlabel::String, ylabel::String, title::String, tolerance_percent::Float64)
    cut_col = pareto_cut_column(xcol, ycol)
    cut_lookup = Dict(String(row.alternative) => Bool(row[cut_col]) for row in eachrow(cuts_df))
    is_cut_pareto = [get(cut_lookup, String(row.alternative), false) for row in eachrow(df)]

    is_global_pareto = Bool.(df.exact_pareto)

    has_within_all_cuts = :within_pareto_all_cuts in propertynames(df)
    is_within_all_cuts = has_within_all_cuts ?
        Bool.(df.within_pareto_all_cuts) :
        fill(false, nrow(df))

    outside = df[(df.within_pareto_tolerance .== false) .& (.!is_cut_pareto), :]
    near = df[(df.within_pareto_tolerance .== true) .& (.!is_cut_pareto), :]
    cut_pareto = df[is_cut_pareto, :]
    global_pareto = df[is_global_pareto, :]
    within_all_cuts = df[is_within_all_cuts, :]
    label_rows = informative_label_rows(df, xcol, ycol)

    p = scatter(;
        xlabel = xlabel,
        ylabel = ylabel,
        title = title,
        legend = :outertopright,
        grid = true,
        gridalpha = 0.18,
        framestyle = :box,
        titlefontsize = 14,
        guidefontsize = 10,
        tickfontsize = 8,
        legendfontsize = 8,
    )

    nrow(outside) > 0 && scatter!(
        p,
        Float64.(outside[!, xcol]),
        Float64.(outside[!, ycol]);
        label = "Outside tolerance",
        markercolor = :gray75,
        markerstrokecolor = :gray35,
        markersize = 6,
    )

    nrow(near) > 0 && scatter!(
        p,
        Float64.(near[!, xcol]),
        Float64.(near[!, ycol]);
        label = "Within $(tolerance_percent)% of global Pareto",
        markercolor = :gold,
        markerstrokecolor = :darkorange,
        markersize = 7,
    )

    nrow(cut_pareto) > 0 && scatter!(
        p,
        Float64.(cut_pareto[!, xcol]),
        Float64.(cut_pareto[!, ycol]);
        label = "Cut Pareto",
        markercolor = :green3,
        markerstrokecolor = :green3,
        markersize = 7,
    )

    nrow(global_pareto) > 0 && scatter!(
        p,
        Float64.(global_pareto[!, xcol]),
        Float64.(global_pareto[!, ycol]);
        label = "Global Pareto",
        markershape = :circle,
        markercolor = :black,
        markerstrokecolor = :black,
        markersize = 3,
    )

    nrow(within_all_cuts) > 0 && scatter!(
        p,
        Float64.(within_all_cuts[!, xcol]),
        Float64.(within_all_cuts[!, ycol]);
        label = "Within tolerance all cuts",
        markershape = :star5,
        markercolor = :black,
        markerstrokecolor = :black,
        markerstrokewidth = 1.0,
        markersize = 7,
    )

    for row in eachrow(label_rows)
        annotate!(
            p,
            Float64(row[xcol]),
            Float64(row[ycol]),
            text(short_alternative_label(row.alternative), 8, :left, :black),
        )
    end

    return p
end

function save_global_pareto_plot(tolerance_df::DataFrame, output_dir::String; tolerance_percent::Float64, filename::String = "global_pareto_plot.png", plot_title::String = "Exact Pareto And $(tolerance_percent)% Equivalent Alternatives")
    plots = [
        pareto_view_plot(
            tolerance_df,
            :simtime,
            :ontime_share;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "On-Time Share (%)",
            title = "Makespan vs On-Time",
            tolerance_percent = tolerance_percent,
        ),
        pareto_view_plot(
            tolerance_df,
            :simtime,
            :mean_processing_ratio;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "Mean Processing Ratio",
            title = "Makespan vs Processing Ratio",
            tolerance_percent = tolerance_percent,
        ),
        pareto_view_plot(
            tolerance_df,
            :ontime_share,
            :mean_processing_ratio;
            xlabel = "On-Time Share (%)",
            ylabel = "Mean Processing Ratio",
            title = "On-Time vs Processing Ratio",
            tolerance_percent = tolerance_percent,
        ),
    ]

    savefig(
        plot(
            plots...;
            layout = (1, 3),
            size = (2400, 760),
            plot_title = plot_title,
            plot_titlefontsize = 20,
            bottom_margin = 8Plots.mm,
            left_margin = 8Plots.mm,
        ),
        joinpath(output_dir, filename),
    )
end

function save_combined_global_pareto_plot(tolerance_df::DataFrame, cuts_df::DataFrame, output_dir::String; tolerance_percent::Float64, filename::String = "combined_global_pareto_plot.png", plot_title::String = "Combined Exact Pareto And $(tolerance_percent)% Equivalent Alternatives")
    plots = [
        combined_pareto_view_plot(
            tolerance_df,
            cuts_df,
            :simtime,
            :ontime_share;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "On-Time Share (%)",
            title = "Makespan vs On-Time",
            tolerance_percent = tolerance_percent,
        ),
        combined_pareto_view_plot(
            tolerance_df,
            cuts_df,
            :simtime,
            :mean_processing_ratio;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "Mean Processing Ratio",
            title = "Makespan vs Processing Ratio",
            tolerance_percent = tolerance_percent,
        ),
        combined_pareto_view_plot(
            tolerance_df,
            cuts_df,
            :ontime_share,
            :mean_processing_ratio;
            xlabel = "On-Time Share (%)",
            ylabel = "Mean Processing Ratio",
            title = "On-Time vs Processing Ratio",
            tolerance_percent = tolerance_percent,
        ),
    ]

    savefig(
        plot(
            plots...;
            layout = (1, 3),
            size = (2400, 760),
            plot_title = plot_title,
            plot_titlefontsize = 20,
            bottom_margin = 8Plots.mm,
            left_margin = 8Plots.mm,
        ),
        joinpath(output_dir, filename),
    )
end

function save_combined_pareto_grid(summary_df::DataFrame, pareto_df::DataFrame, tolerance_df::DataFrame, cuts_df::DataFrame, output_dir::String; tolerance_percent::Float64)
    axisColumns = combinedAxisColumnsFromFrame(summary_df)
    axisColumns === nothing && error("Impossibile rilevare assi adaptive combinati per Pareto grid")
    yColumn, xColumn = axisColumns
    yValues = sort(unique(Float64.(summary_df[!, yColumn])))
    xValues = sort(unique(Float64.(summary_df[!, xColumn])))
    matrix = zeros(Float64, length(yValues), length(xValues))
    yIdx = Dict(value => idx for (idx, value) in enumerate(yValues))
    xIdx = Dict(value => idx for (idx, value) in enumerate(xValues))

    for row in eachrow(tolerance_df[tolerance_df.within_pareto_tolerance .== true, :])
        yValue = Float64(row[yColumn])
        xValue = Float64(row[xColumn])
        haskey(yIdx, yValue) && haskey(xIdx, xValue) || continue
        matrix[yIdx[yValue], xIdx[xValue]] = 1.0
    end

    for row in eachrow(cuts_df[cuts_df.pareto_any_cut .== true, :])
        yValue = Float64(row[yColumn])
        xValue = Float64(row[xColumn])
        haskey(yIdx, yValue) && haskey(xIdx, xValue) || continue
        matrix[yIdx[yValue], xIdx[xValue]] = 2.0
    end

    p = heatmap(
        xValues,
        yValues,
        matrix;
        color = cgrad([:white, :gold, :green3], [0.0, 0.5, 1.0]),
        clims = (0.0, 2.0),
        colorbar = false,
        xlabel = thresholdDisplayName(xColumn),
        ylabel = thresholdDisplayName(yColumn),
        title = "Combined Pareto Decision Grid",
        size = (1800, 1100),
        titlefontsize = 18,
        guidefontsize = 13,
        tickfontsize = 9,
        framestyle = :box,
        margins = 8Plots.mm,
    )

    global_rows = pareto_df[pareto_df.pareto_efficient .== true, :]
    if nrow(global_rows) > 0
        scatter!(
            p,
            Float64.(global_rows[!, xColumn]),
            Float64.(global_rows[!, yColumn]);
            label = "Global Pareto",
            markershape = :circle,
            markercolor = :black,
            markerstrokecolor = :black,
            markersize = 4,
        )
    end

    if :within_pareto_all_cuts in propertynames(tolerance_df)
        star_rows = tolerance_df[tolerance_df.within_pareto_all_cuts .== true, :]
        if nrow(star_rows) > 0
            scatter!(
                p,
                Float64.(star_rows[!, xColumn]),
                Float64.(star_rows[!, yColumn]);
                label = "Within tolerance all cuts",
                markershape = :star5,
                markercolor = :green3,
                markerstrokecolor = :black,
                markerstrokewidth = 2,
                markersize = 10,
            )
        end
    end

    savefig(p, joinpath(output_dir, "combined_pareto_grid.png"))
end

function pareto_flags(values::Matrix{Float64})
    n = size(values, 1)
    flags = trues(n)
    for i in 1:n
        for j in 1:n
            i == j && continue
            dominates = all(values[j, :] .<= values[i, :]) && any(values[j, :] .< values[i, :])
            if dominates
                flags[i] = false
                break
            end
        end
    end
    return flags
end

function build_rankings(df::DataFrame)
    ranking_rows = NamedTuple[]
    pareto_rows = NamedTuple[]

    for code_df in groupby(df, :client_code)
        score = zeros(nrow(code_df))
        for spec in KPI_SPECS
            score .+= normalize_minmax(Float64.(code_df[!, spec.column]); higher_is_better = spec.higher_is_better)
        end
        score ./= length(KPI_SPECS)

        objectives = hcat(
            Float64.(code_df.mean_makespan),
            .-Float64.(code_df.processing_ratio),
            .-Float64.(code_df.ontime_share),
            Float64.(code_df.mean_waiting_time),
            Float64.(code_df.mean_tardiness),
        )
        pareto = pareto_flags(objectives)
        order = sortperm(score; rev = true)
        ranks = zeros(Int, length(score))
        for (rank_idx, row_idx) in enumerate(order)
            ranks[row_idx] = rank_idx
        end

        for idx in 1:nrow(code_df)
            row = merge(
                NamedTuple(code_df[idx, :]),
                (
                    composite_score = score[idx],
                    rank = ranks[idx],
                    pareto_efficient = pareto[idx],
                ),
            )
            push!(ranking_rows, row)
            pareto[idx] && push!(pareto_rows, row)
        end
    end

    ranking_df = DataFrame(ranking_rows)
    code_order = Dict(code => idx for (idx, code) in enumerate(sort(unique(String.(ranking_df.client_code)); by = natural_label_key)))
    ranking_df.__code_order = [code_order[String(code)] for code in ranking_df.client_code]
    sort!(ranking_df, [:__code_order, :rank])
    select!(ranking_df, Not(:__code_order))
    pareto_df = DataFrame(pareto_rows)
    sort_policy_code!(pareto_df)
    return ranking_df, pareto_df
end

function build_policy_focused_rankings(df::DataFrame)
    ranking_rows = NamedTuple[]

    for policy_df in groupby(df, :policy)
        score = zeros(nrow(policy_df))
        favored_count = zeros(Int, nrow(policy_df))

        for spec in KPI_SPECS
            values = Float64.(policy_df[!, spec.column])
            score .+= normalize_minmax(values; higher_is_better = spec.higher_is_better)
            reference = safe_mean(values)

            for idx in 1:nrow(policy_df)
                value = Float64(policy_df[idx, spec.column])
                is_favored = spec.higher_is_better ? value > reference : value < reference
                favored_count[idx] += is_favored ? 1 : 0
            end
        end
        score ./= length(KPI_SPECS)

        order = sortperm(score; rev = true)
        ranks = zeros(Int, length(score))
        for (rank_idx, row_idx) in enumerate(order)
            ranks[row_idx] = rank_idx
        end

        for idx in 1:nrow(policy_df)
            push!(ranking_rows, merge(
                NamedTuple(policy_df[idx, :]),
                (
                    policy_focused_score = score[idx],
                    favored_kpi_count = favored_count[idx],
                    policy_focused_rank = ranks[idx],
                ),
            ))
        end
    end

    ranking_df = DataFrame(ranking_rows)
    policy_order = Dict(policy => idx for (idx, policy) in enumerate(sort(unique(String.(ranking_df.policy)); by = policy_label_key)))
    ranking_df.__policy_order = [policy_order[String(policy)] for policy in ranking_df.policy]
    sort!(ranking_df, [:__policy_order, :policy_focused_rank])
    select!(ranking_df, Not(:__policy_order))
    return ranking_df
end

function markdown_table(df::DataFrame; columns = names(df), max_rows::Int = nrow(df))
    use_rows = min(max_rows, nrow(df))
    selected = df[1:use_rows, columns]
    header = "| " * join(String.(columns), " | ") * " |\n"
    divider = "| " * join(fill("---", length(columns)), " | ") * " |\n"
    body = IOBuffer()
    for row in eachrow(selected)
        values = [string(row[col]) for col in columns]
        print(body, "| ", join(values, " | "), " |\n")
    end
    return header * divider * String(take!(body))
end

function build_report(output_path::String, input_dir::String, output_dir::String, summary_df::DataFrame, ranking_df::DataFrame, policy_focused_df::DataFrame, global_pareto_exact::DataFrame, global_pareto_tolerance::DataFrame; tolerance_percent::Float64)
    io = IOBuffer()
    println(io, "# Policy-Code Evaluation Report")
    println(io)
    println(io, "## Summary")
    println(io, "- input directory: `$(input_dir)`")
    println(io, "- output directory: `$(output_dir)`")
    println(io, "- policies evaluated: `$(join(sort(unique(String.(summary_df.policy)); by = policy_label_key), ", "))`")
    println(io, "- heatmaps are code-centric: each column asks which policy treats that code better or worse")
    println(io, "- code-focused dashboard: `dash_code.png`")
    println(io, "- policy-focused dashboard: `dash_policy.png`")
    println(io, "- individual heatmaps are saved in `heatmaps/`")
    println(io, "- exact Pareto is computed without tolerance")
    println(io, "- equivalence band around exact Pareto: `$(tolerance_percent)%`")
    println(io, "- heatmap colors follow the KPI direction: green means better, red means worse")
    println(io)
    println(io, "## Code-Level KPIs")
    kpi_rows = DataFrame(
        kpi = [String(spec.column) for spec in KPI_SPECS],
        title = [spec.title for spec in KPI_SPECS],
        direction = [spec.higher_is_better ? "higher is better" : "lower is better" for spec in KPI_SPECS],
        heatmap = fill("code average under policy / code average (%)", length(KPI_SPECS)),
    )
    println(io, markdown_table(kpi_rows))
    println(io)
    println(io, "## Best Policy by Code")
    best_rows = ranking_df[ranking_df.rank .== 1, [:client_code, :policy, :policy_rule, :composite_score, :pareto_efficient]]
    println(io, markdown_table(best_rows; max_rows = nrow(best_rows)))
    println(io)
    println(io, "## Most Favored Codes by Policy")
    best_policy_rows = policy_focused_df[policy_focused_df.policy_focused_rank .<= 3, [:policy, :policy_rule, :client_code, :policy_focused_score, :favored_kpi_count, :policy_focused_rank]]
    println(io, markdown_table(best_policy_rows; max_rows = nrow(best_policy_rows)))
    println(io)
    println(io, "## Global Exact Pareto")
    global_pareto_rows = global_pareto_exact[global_pareto_exact.pareto_efficient .== true, :]
    println(io, markdown_table(global_pareto_rows; max_rows = nrow(global_pareto_rows)))
    println(io)
    println(io, "## Within Pareto Tolerance")
    tolerance_rows = global_pareto_tolerance[global_pareto_tolerance.within_pareto_tolerance .== true, :]
    println(io, markdown_table(tolerance_rows; max_rows = nrow(tolerance_rows)))
    println(io)
    println(io, "## Reading Notes")
    println(io, "- `codecentric` heatmaps answer: given a code, which policy treats it better or worse than that code average?")
    println(io, "- `policyfocused` heatmaps answer: given a policy, which codes are favored or penalized relative to that policy average?")
    println(io, "- Global exact Pareto uses total makespan, on-time share, and mean processing ratio from ANOVA summaries.")
    println(io, "- `within_pareto_tolerance` means the alternative is within `$(tolerance_percent)%` of at least one exact Pareto alternative on all Pareto KPIs.")
    println(io, "- Heatmap values are `code average under policy / code average * 100`; `100%` means equal to the code average.")
    println(io, "- Policy-focused heatmap values are `code average under policy / policy average * 100`; `100%` means equal to that policy average across codes.")
    println(io, "- Higher-is-better metrics use green above `100%`; lower-is-better metrics use green below `100%`.")
    write(output_path, String(take!(io)))
end

function reset_output_dir(output_dir::String)
    mkpath(output_dir)
end

function save_outputs(output_dir::String, summary_df::DataFrame, ranking_df::DataFrame, pareto_df::DataFrame, policy_focused_df::DataFrame, global_pareto_exact::DataFrame, global_pareto_tolerance::DataFrame)
    CSV.write(joinpath(output_dir, "policy_code_kpi_summary.csv"), summary_df)
    CSV.write(joinpath(output_dir, "policy_code_ranking.csv"), ranking_df)
    CSV.write(joinpath(output_dir, "policy_code_pareto.csv"), pareto_df)
    CSV.write(joinpath(output_dir, "policy_focused_code_ranking.csv"), policy_focused_df)
    CSV.write(joinpath(output_dir, "global_pareto_exact.csv"), global_pareto_exact)
    CSV.write(joinpath(output_dir, "global_pareto_within_tolerance.csv"), global_pareto_tolerance)
end

function performEvaluation(; input_dir::String = INPUT_RESULTS_DIR, output_dir::String = OUTPUT_EVALUATION_DIR)
    if is_combined_campaign(input_dir)
        perform_combined_evaluation(input_dir = input_dir, output_dir = output_dir)
        return
    end

    println("##### starting policy-code evaluation #####################")
    tolerance_percent = pareto_tolerance_percent()
    anova_summary_file = require_anova_summary(input_dir)
    anova_summary_df = CSV.read(anova_summary_file, DataFrame)
    addAdaptiveMetadataColumns!(anova_summary_df, :policy)
    infos = policy_infos(input_dir)
    summary_df = build_policy_code_kpis(infos)
    ranking_df, pareto_df = build_rankings(summary_df)
    policy_focused_df = build_policy_focused_rankings(summary_df)
    global_pareto_source = policy_summary_to_global_pareto_source(anova_summary_df)
    global_pareto_exact = global_pareto_table(global_pareto_source)
    global_pareto_tolerance = pareto_tolerance_table(
        global_pareto_source,
        global_pareto_exact;
        tolerance_percent = tolerance_percent,
    )

    reset_output_dir(output_dir)
    save_timing_overview(input_dir, output_dir)
    save_outputs(output_dir, summary_df, ranking_df, pareto_df, policy_focused_df, global_pareto_exact, global_pareto_tolerance)

    for spec in KPI_SPECS
        save_heatmap(summary_df, spec.column, output_dir)
        save_heatmap(summary_df, spec.column, output_dir; focus = :policyfocused)
    end
    save_global_pareto_plot(global_pareto_tolerance, output_dir; tolerance_percent = tolerance_percent)
    save_dashboard(summary_df, output_dir)
    save_dashboard(summary_df, output_dir; focus = :policyfocused)

    build_report(
        joinpath(output_dir, "report.md"),
        input_dir,
        output_dir,
        summary_df,
        ranking_df,
        policy_focused_df,
        global_pareto_exact,
        global_pareto_tolerance;
        tolerance_percent = tolerance_percent,
    )
    println("##### evaluation outputs saved in $(output_dir) #####")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    performEvaluation()
end

end
