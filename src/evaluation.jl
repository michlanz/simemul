module showevaluation

using CSV
using DataFrames
ENV["GKSwstype"] = "100" # Save plots without opening GR windows.
using Plots
using Statistics

using Main.configdata: SimConfig, relativeHeatmapColors, surfacePlotColors, validateConfig

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

function parse_combined_scenario(label)
    match_scenario = match(r"^queue_(\d+)__slack_([0-9]+(?:\.[0-9]+)?)$", String(label))
    match_scenario === nothing && return nothing
    return (
        queue_threshold = parse(Int, match_scenario.captures[1]),
        slack_threshold = parse(Float64, match_scenario.captures[2]),
    )
end

function combined_scenario_infos(results_dir::String)
    infos = NamedTuple[]
    for folder in readdir(results_dir; join = true)
        !isdir(folder) && continue
        label = basename(folder)
        parsed = parse_combined_scenario(label)
        parsed === nothing && continue
        isfile(joinpath(folder, "anovaRef.csv")) || continue
        push!(infos, (
            scenario = label,
            queue_threshold = parsed.queue_threshold,
            slack_threshold = parsed.slack_threshold,
            path = folder,
        ))
    end
    sort!(infos, by = info -> (info.queue_threshold, info.slack_threshold))
    return infos
end

function is_combined_campaign(results_dir::String)::Bool
    return !isempty(combined_scenario_infos(results_dir))
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
        if "policy" ∉ names(df)
            insertcols!(df, 1, :policy => fill(info.scenario, nrow(df)))
        end
        df.scenario = fill(info.scenario, nrow(df))
        df.queue_threshold = fill(info.queue_threshold, nrow(df))
        df.slack_threshold = fill(info.slack_threshold, nrow(df))
        push!(rows, df)
    end

    isempty(rows) && error("No valid combined scenario folder found")
    df = vcat(rows...)
    sort!(df, [:queue_threshold, :slack_threshold, :replication_id])
    return df
end

function combined_surface_summary(df::DataFrame)::DataFrame
    rows = NamedTuple[]
    for spec in COMBINED_KPI_SPECS
        spec.column in propertynames(df) || continue
        for subdf in groupby(df, [:queue_threshold, :slack_threshold])
            values = Float64.(subdf[!, spec.column])
            push!(rows, (
                metric = String(spec.column),
                title = spec.title,
                direction = spec.higher_is_better ? "higher is better" : "lower is better",
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

function combined_best_by_kpi(summary_df::DataFrame)::DataFrame
    rows = NamedTuple[]
    for spec in COMBINED_KPI_SPECS
        metric_df = summary_df[summary_df.metric .== String(spec.column), :]
        nrow(metric_df) == 0 && continue
        order = sortperm(Float64.(metric_df.mean); rev = spec.higher_is_better)
        best = metric_df[order[1], :]
        push!(rows, (
            metric = String(spec.column),
            title = spec.title,
            direction = spec.higher_is_better ? "higher is better" : "lower is better",
            queue_threshold = Int(best.queue_threshold),
            slack_threshold = Float64(best.slack_threshold),
            mean = Float64(best.mean),
            std = Float64(best.std),
            replications = Int(best.replications),
        ))
    end
    return DataFrame(rows)
end

function combined_grid_matrix(summary_df::DataFrame, metric::Symbol)
    metric_df = summary_df[summary_df.metric .== String(metric), :]
    queues = sort(unique(Int.(metric_df.queue_threshold)))
    slacks = sort(unique(Float64.(metric_df.slack_threshold)))
    matrix = fill(NaN, length(queues), length(slacks))
    queue_idx = Dict(value => idx for (idx, value) in enumerate(queues))
    slack_idx = Dict(value => idx for (idx, value) in enumerate(slacks))

    for row in eachrow(metric_df)
        matrix[queue_idx[Int(row.queue_threshold)], slack_idx[Float64(row.slack_threshold)]] = Float64(row.mean)
    end
    return queues, slacks, matrix
end

function surface_color_scale(higher_is_better::Bool)
    colors = higher_is_better ?
        [surfacePlotColors.worse, surfacePlotColors.neutral, surfacePlotColors.better] :
        [surfacePlotColors.better, surfacePlotColors.neutral, surfacePlotColors.worse]
    return cgrad(colors)
end

function save_combined_surface_plot(summary_df::DataFrame, spec, output_dir::String)
    queues, slacks, matrix = combined_grid_matrix(summary_df, spec.column)
    p = surface(
        slacks,
        queues,
        matrix;
        xlabel = "Slack Threshold",
        ylabel = "Queue Threshold",
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
    queues, slacks, matrix = combined_grid_matrix(summary_df, spec.column)
    return heatmap(
        slacks,
        queues,
        matrix;
        xlabel = compact ? "" : "Slack Threshold",
        ylabel = compact ? "" : "Queue Threshold",
        title = compact ? spec.title : "$(spec.title): Mean By Queue And Slack Threshold",
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

function combined_dashboard_note_plot()
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
    annotate!(p, 0.5, 0.36, text("X = slack threshold, Y = queue threshold", 20, :center, :black))
    annotate!(p, 0.5, 0.26, text("Green = better for that KPI", 20, :center, :black))
    annotate!(p, 0.5, 0.16, text("Red = worse for that KPI", 20, :center, :black))
    return p
end

function save_combined_dashboard(summary_df::DataFrame, output_dir::String)
    plots = [combined_contour_plot(summary_df, spec; compact = true) for spec in COMBINED_KPI_SPECS if String(spec.column) in unique(String.(summary_df.metric))]
    push!(plots, combined_dashboard_note_plot())
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

function build_combined_report(output_path::String, input_dir::String, output_dir::String, summary_df::DataFrame, best_df::DataFrame, pareto_exact::DataFrame, pareto_tolerance::DataFrame; tolerance_percent::Float64)
    io = IOBuffer()
    println(io, "# Combined Adaptive Surface Report")
    println(io)
    println(io, "## Summary")
    println(io, "- input directory: `$(input_dir)`")
    println(io, "- output directory: `$(output_dir)`")
    println(io, "- scenarios are parsed as `queue_threshold` and `slack_threshold` from folders like `queue_003__slack_10.0`")
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
    println(io, "## Reading Notes")
    println(io, "- Surface plots show the average KPI over replications for every `(queue, slack)` pair.")
    println(io, "- Contour heatmaps are the readable control view for the same surfaces.")
    println(io, "- `combined_pareto_grid.png` marks exact Pareto-efficient grid points in green.")
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
    best_df = combined_best_by_kpi(summary_df)
    pareto_source = combined_summary_to_global_pareto_source(summary_df)
    pareto_exact = global_pareto_table(pareto_source)
    pareto_tolerance = pareto_tolerance_table(
        pareto_source,
        pareto_exact;
        tolerance_percent = tolerance_percent,
    )

    reset_output_dir(output_dir)
    CSV.write(joinpath(output_dir, "combined_surface_summary.csv"), summary_df)
    CSV.write(joinpath(output_dir, "combined_best_by_kpi.csv"), best_df)
    CSV.write(joinpath(output_dir, "combined_pareto_exact.csv"), pareto_exact)
    CSV.write(joinpath(output_dir, "combined_pareto_within_tolerance.csv"), pareto_tolerance)

    for spec in COMBINED_KPI_SPECS
        String(spec.column) in unique(String.(summary_df.metric)) || continue
        save_combined_surface_plot(summary_df, spec, output_dir)
        save_combined_contour_plot(summary_df, spec, output_dir)
    end
    save_combined_pareto_grid(summary_df, pareto_exact, output_dir)
    save_combined_dashboard(summary_df, output_dir)
    build_combined_report(
        joinpath(output_dir, "report.md"),
        input_dir,
        output_dir,
        summary_df,
        best_df,
        pareto_exact,
        pareto_tolerance;
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
    rows = NamedTuple[]
    for policy_df in groupby(summary_df, :policy)
        policy = String(policy_df.policy[1])
        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(policy_df))
        missing_metrics = [spec.column for spec in GLOBAL_PARETO_SPECS if !haskey(values, spec.column)]
        isempty(missing_metrics) || error("Missing global Pareto metrics for $(policy): $(missing_metrics)")

        push!(rows, (
            alternative = policy,
            policy = policy,
            policy_rule = policy_rule_name(policy),
            simtime = values[:simtime],
            ontime_share = values[:ontime_share],
            mean_processing_ratio = values[:mean_processing_ratio],
        ))
    end
    df = DataFrame(rows)
    sort!(df, :policy; by = policy_label_key)
    return df
end

function combined_summary_to_global_pareto_source(summary_df::DataFrame)::DataFrame
    rows = NamedTuple[]
    key_df = unique(summary_df[:, [:queue_threshold, :slack_threshold]])
    sort!(key_df, [:queue_threshold, :slack_threshold])

    for key in eachrow(key_df)
        queue = Int(key.queue_threshold)
        slack = Float64(key.slack_threshold)
        scenario_df = summary_df[(summary_df.queue_threshold .== queue) .& (summary_df.slack_threshold .== slack), :]
        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(scenario_df))
        missing_metrics = [spec.column for spec in GLOBAL_PARETO_SPECS if !haskey(values, spec.column)]
        isempty(missing_metrics) || error("Missing global Pareto metrics for queue=$(queue), slack=$(slack): $(missing_metrics)")

        push!(rows, (
            alternative = "queue_$(lpad(queue, 3, '0'))__slack_$(slack)",
            queue_threshold = queue,
            slack_threshold = slack,
            simtime = values[:simtime],
            ontime_share = values[:ontime_share],
            mean_processing_ratio = values[:mean_processing_ratio],
        ))
    end
    return DataFrame(rows)
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

    ordered = sort(df, [xcol, ycol]; rev = [false, true])
    keep = Bool[]
    best_y = -Inf

    for row in eachrow(ordered)
        y_value = Float64(row[ycol])
        should_keep = y_value > best_y
        push!(keep, should_keep)
        should_keep && (best_y = y_value)
    end

    return ordered[keep, :]
end

function pareto_view_plot(df::DataFrame, xcol::Symbol, ycol::Symbol; xlabel::String, ylabel::String, title::String, tolerance_percent::Float64)
    outside = df[df.within_pareto_tolerance .== false, :]
    near = df[(df.within_pareto_tolerance .== true) .& (df.exact_pareto .== false), :]
    exact = df[df.exact_pareto .== true, :]
    frontier = visible_frontier_2d(exact, xcol, ycol)
    frontier_names = Set(String.(frontier.alternative))
    exact_on_cut = exact[[String(row.alternative) in frontier_names for row in eachrow(exact)], :]
    exact_off_cut = exact[[!(String(row.alternative) in frontier_names) for row in eachrow(exact)], :]

    if nrow(near) > 12
        sort!(near, :tolerance_rank)
        near_labels = near[1:12, :]
    else
        near_labels = near
    end

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

    if nrow(frontier) > 1
        plot!(
            p,
            Float64.(frontier[!, xcol]),
            Float64.(frontier[!, ycol]);
            label = "Cut Pareto frontier",
            color = :green4,
            linestyle = :dash,
            linewidth = 2,
        )
    end

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
        label = "Within $(tolerance_percent)% of exact Pareto",
        markercolor = :gold,
        markerstrokecolor = :darkorange,
        markersize = 7,
    )
    nrow(exact_off_cut) > 0 && scatter!(
        p,
        Float64.(exact_off_cut[!, xcol]),
        Float64.(exact_off_cut[!, ycol]);
        label = "Exact Pareto, not on this cut",
        markercolor = :green3,
        markerstrokecolor = :green3,
        markersize = 7,
    )
    nrow(exact_on_cut) > 0 && scatter!(
        p,
        Float64.(exact_on_cut[!, xcol]),
        Float64.(exact_on_cut[!, ycol]);
        label = "Cut Pareto",
        markercolor = :green3,
        markerstrokecolor = :black,
        markersize = 8,
    )

    for row in eachrow(near_labels)
        annotate!(
            p,
            Float64(row[xcol]),
            Float64(row[ycol]),
            text(short_alternative_label(row.alternative), 8, :left, :black),
        )
    end

    for row in eachrow(exact_on_cut)
        annotate!(
            p,
            Float64(row[xcol]),
            Float64(row[ycol]),
            text(short_alternative_label(row.alternative), 9, :left, :black),
        )
    end
    return p
end

function save_global_pareto_plot(tolerance_df::DataFrame, output_dir::String; tolerance_percent::Float64)
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
            plot_title = "Exact Pareto And $(tolerance_percent)% Equivalent Alternatives",
            plot_titlefontsize = 20,
            bottom_margin = 8Plots.mm,
            left_margin = 8Plots.mm,
        ),
        joinpath(output_dir, "global_pareto_plot.png"),
    )
end

function save_combined_pareto_grid(summary_df::DataFrame, pareto_df::DataFrame, output_dir::String)
    queues = sort(unique(Int.(summary_df.queue_threshold)))
    slacks = sort(unique(Float64.(summary_df.slack_threshold)))
    matrix = zeros(Float64, length(queues), length(slacks))
    queue_idx = Dict(value => idx for (idx, value) in enumerate(queues))
    slack_idx = Dict(value => idx for (idx, value) in enumerate(slacks))

    for row in eachrow(pareto_df[pareto_df.pareto_efficient .== true, :])
        queue = Int(row.queue_threshold)
        slack = Float64(row.slack_threshold)
        haskey(queue_idx, queue) && haskey(slack_idx, slack) || continue
        matrix[queue_idx[queue], slack_idx[slack]] = 1.0
    end

    p = heatmap(
        slacks,
        queues,
        matrix;
        color = cgrad([:white, :green3], [0.0, 1.0]),
        clims = (0.0, 1.0),
        colorbar = false,
        xlabel = "Slack Threshold",
        ylabel = "Queue Threshold",
        title = "Exact Pareto-Efficient Scenarios",
        size = (1800, 1100),
        titlefontsize = 18,
        guidefontsize = 13,
        tickfontsize = 9,
        framestyle = :box,
        margins = 8Plots.mm,
    )
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
    rm(output_dir; recursive = true, force = true)
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
