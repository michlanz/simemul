module showexpost

using CSV
using DataFrames
ENV["GKSwstype"] = "100"

using Plots
using StatsPlots
using Statistics
using LinearAlgebra

using Main.showevaluation: pareto_tolerance_percent,
                           global_pareto_table,
                           pareto_tolerance_table,
                           markdown_table,
                           reset_output_dir
using Main.configdata: exPostOutputDir,
                       exPostRunRange


function folder_name(folder::AbstractString)
    return basename(folder)
end

export performExPostEvaluation,
       performRangeExPostEvaluation

const EX_POST_OUTPUT_DIR = "r_ex_post_evaluation"

function exPostRangeOutputDir(run_range, configuredOutputDir)::String
    configuredOutputDir !== nothing && return String(configuredOutputDir)
    collected = Int.(collect(run_range))
    isempty(collected) && error("exPostRunRange e vuoto")
    return "r$(minimum(collected))_$(maximum(collected))_ex_post"
end

const EX_POST_KPI_SPECS = [
    (column = :simtime, title = "Total Makespan", higher_is_better = false),
    (column = :throughput, title = "Throughput", higher_is_better = true),
    (column = :mean_saturation, title = "Mean Saturation", higher_is_better = true),
    (column = :mean_lateness, title = "Mean Lateness", higher_is_better = false),
    (column = :mean_tardiness, title = "Mean Tardiness", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_wip_queue, title = "Mean Queue WIP", higher_is_better = false),
    (column = :mean_queuetime, title = "Mean Queue Time", higher_is_better = false),
    (column = :mean_queue_length, title = "Mean Queue Length", higher_is_better = false),
    (column = :mean_makespan, title = "Mean Makespan", higher_is_better = false),
    (column = :mean_processing_ratio, title = "Mean Processing Ratio", higher_is_better = true),
]

const EX_POST_PARETO_SPECS = [
    (column = :simtime, title = "Total Makespan", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_processing_ratio, title = "Mean Processing Ratio", higher_is_better = true),
]

const EX_POST_BOXPLOT_COLORS = (
    best = :green3,
    worst = :crimson,
    mid = :deepskyblue3,
)

const EX_POST_CUT_PAIRS = [
    (:simtime, :ontime_share),
    (:simtime, :mean_processing_ratio),
    (:ontime_share, :mean_processing_ratio),
]

const EX_POST_STATIC_BASELINE_COUNT = 2
const EX_POST_CURVATURE_POINTS_PER_CUT = 2
const EX_POST_CUT_QUANTILES = [0.25, 0.50, 0.75]

function ex_post_mode_label(run_mode::Symbol)::String
    run_mode == :static && return "static"
    run_mode == :adaptive && return "adaptive"
    run_mode == :combined_first && return "combined_first"
    run_mode == :combined_second && return "combined_second"
    run_mode == :adaptive_spt && return "adaptive_queue"
    run_mode == :adaptive_slack && return "adaptive_slack"
    run_mode == :adaptive_combined_spt_first && return "combined_queue_first"
    run_mode == :adaptive_combined_slack_first && return "combined_slack_first"
    return String(run_mode)
end

function ex_post_sort_key(label)::Tuple
    text = String(label)
    key = Any[]

    for token in eachmatch(r"\d+(?:\.\d+)?|[^\d]+", text)
        part = token.match
        if occursin(r"^\d+(?:\.\d+)?$", part)
            push!(key, (0, parse(Float64, part)))
        else
            push!(key, (1, lowercase(part)))
        end
    end

    return Tuple(key)
end

function short_ex_post_label(label)::String
    text = String(label)
    text = replace(text, "adaptive_queue__" => "aq/")
    text = replace(text, "adaptive_slack__" => "as/")
    text = replace(text, "combined_queue_first__" => "cq/")
    text = replace(text, "combined_slack_first__" => "cs/")
    text = replace(text, "static__" => "st/")
    text = replace(text, "queue_" => "q")
    text = replace(text, "__slack_" => "/s")
    return text
end

function candidate_evaluation_dirs(input_dir::String)::Vector{String}
    base = basename(input_dir)
    parent = dirname(input_dir)

    dirs = [
        string(input_dir, "_evaluation"),
        joinpath(parent, string(base, "_evaluation")),
        joinpath(parent, string(base, "_eval")),
    ]

    return unique(dirs)
end

function find_existing_evaluation_dir(input_dir::String)::String
    for dir in candidate_evaluation_dirs(input_dir)
        isdir(dir) && return dir
    end

    error("Missing evaluation directory for ex-post candidate selection. Checked: $(candidate_evaluation_dirs(input_dir))")
end

function selected_column_from_pareto_table(df::DataFrame)::Symbol
    :alternative in propertynames(df) && return :alternative
    :policy in propertynames(df) && return :policy
    :source_policy in propertynames(df) && return :source_policy
    error("Cannot identify alternative column in Pareto table. Available columns: $(propertynames(df))")
end

function select_candidates_from_within_tolerance_file(filepath::String)::Set{String}
    df = CSV.read(filepath, DataFrame)
    source_col = selected_column_from_pareto_table(df)

    if :within_pareto_tolerance in propertynames(df)
        selected = df[df.within_pareto_tolerance .== true, source_col]
        return Set(String.(selected))
    end

    if :pareto_efficient in propertynames(df)
        selected = df[df.pareto_efficient .== true, source_col]
        return Set(String.(selected))
    end

    if :exact_pareto in propertynames(df)
        selected = df[df.exact_pareto .== true, source_col]
        return Set(String.(selected))
    end

    error("Cannot identify Pareto selection flag in $(filepath). Available columns: $(propertynames(df))")
end

function select_candidates_from_exact_file(filepath::String)::Set{String}
    df = CSV.read(filepath, DataFrame)
    source_col = selected_column_from_pareto_table(df)

    if :pareto_efficient in propertynames(df)
        selected = df[df.pareto_efficient .== true, source_col]
        return Set(String.(selected))
    end

    if :exact_pareto in propertynames(df)
        selected = df[df.exact_pareto .== true, source_col]
        return Set(String.(selected))
    end

    error("Cannot identify exact Pareto flag in $(filepath). Available columns: $(propertynames(df))")
end

function selected_source_policies_for_campaign(input_dir::String, run_mode::Symbol)
    if run_mode == :static
        println("  static campaign: all static baselines are loaded, but only selected static baselines survive ex-post reporting")
        return nothing
    end

    evaluation_dir = find_existing_evaluation_dir(input_dir)

    candidate_files = [
        joinpath(evaluation_dir, "combined_pareto_within_tolerance.csv"),
        joinpath(evaluation_dir, "global_pareto_within_tolerance.csv"),
    ]

    for filepath in candidate_files
        if isfile(filepath)
            selected = select_candidates_from_within_tolerance_file(filepath)
            println("  selected from $(filepath): $(length(selected))")
            return selected
        end
    end

    fallback_files = [
        joinpath(evaluation_dir, "combined_pareto_exact.csv"),
        joinpath(evaluation_dir, "global_pareto_exact.csv"),
    ]

    for filepath in fallback_files
        if isfile(filepath)
            selected = select_candidates_from_exact_file(filepath)
            println("  selected from $(filepath): $(length(selected))")
            return selected
        end
    end

    error("No Pareto candidate file found in $(evaluation_dir)")
end

function collect_campaign_anovaref(input_dir::String, run_mode::Symbol)::DataFrame
    rows = DataFrame[]
    mode_label = ex_post_mode_label(run_mode)
    selected_source_policies = selected_source_policies_for_campaign(input_dir, run_mode)

    println("  loading $(mode_label) from $(input_dir)")

    for folder in sort(readdir(input_dir; join = true); by = basename)
        isdir(folder) || continue

        folder_label = folder_name(folder)

        if selected_source_policies !== nothing && !(folder_label in selected_source_policies)
            continue
        end

        filepath = joinpath(folder, "anovaRef.csv")
        isfile(filepath) || continue

        df = CSV.read(filepath, DataFrame)

        if !("policy" in names(df))
            insertcols!(df, 1, :policy => fill(folder_label, nrow(df)))
        end

        :replication_id in propertynames(df) || error("Missing replication_id in $(filepath)")

        selected_for_df = selected_source_policies === nothing ? Set(String.(df.policy)) : selected_source_policies
        df = df[in.(String.(df.policy), Ref(selected_for_df)), :]

        nrow(df) == 0 && continue

        source_policy = String.(df.policy)

        df.campaign_mode = fill(mode_label, nrow(df))
        df.campaign_path = fill(input_dir, nrow(df))
        df.source_policy = source_policy
        df.alternative = ["$(mode_label)__$(policy)" for policy in source_policy]
        df.is_static_baseline = fill(run_mode == :static, nrow(df))

        push!(rows, df)
    end

    isempty(rows) && error("No selected anovaRef.csv found in $(input_dir)")

    out = vcat(rows...; cols = :union)
    sort!(out, [:campaign_mode, :alternative, :replication_id])

    println("    rows loaded: $(nrow(out))")
    println("    alternatives loaded: $(length(unique(out.alternative)))")

    return out
end

function collect_ex_post_raw(input_dirs::Dict{Symbol, String})::DataFrame
    rows = DataFrame[]

    for run_mode in sort(collect(keys(input_dirs)); by = String)
        push!(rows, collect_campaign_anovaref(input_dirs[run_mode], run_mode))
    end

    raw_df = vcat(rows...; cols = :union)

    missing_columns = [spec.column for spec in EX_POST_KPI_SPECS if !(spec.column in propertynames(raw_df))]
    isempty(missing_columns) || error("Missing KPI columns in ex-post raw data: $(missing_columns)")

    println("  total raw rows: $(nrow(raw_df))")
    println("  total alternatives before ex-post Pareto filter: $(length(unique(raw_df.alternative)))")

    return raw_df
end

function build_ex_post_summary(raw_df::DataFrame)::DataFrame
    rows = NamedTuple[]

    for alt_df in groupby(raw_df, [:alternative, :campaign_mode, :source_policy, :is_static_baseline])
        for spec in EX_POST_KPI_SPECS
            values = Float64.(alt_df[!, spec.column])

            push!(rows, (
                alternative = String(alt_df.alternative[1]),
                campaign_mode = String(alt_df.campaign_mode[1]),
                source_policy = String(alt_df.source_policy[1]),
                is_static_baseline = Bool(alt_df.is_static_baseline[1]),
                metric = String(spec.column),
                title = spec.title,
                direction = spec.higher_is_better ? "higher is better" : "lower is better",
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
    end

    out = DataFrame(rows)
    sort!(out, [:campaign_mode, :alternative, :metric])

    println("  summary rows: $(nrow(out))")

    return out
end

function ex_post_summary_to_pareto_source(summary_df::DataFrame)::DataFrame
    rows = NamedTuple[]

    for alt_df in groupby(summary_df, [:alternative, :campaign_mode, :source_policy, :is_static_baseline])
        values = Dict(Symbol(row.metric) => Float64(row.mean) for row in eachrow(alt_df))
        missing_metrics = [spec.column for spec in EX_POST_PARETO_SPECS if !haskey(values, spec.column)]
        isempty(missing_metrics) || error("Missing ex-post Pareto metrics for $(alt_df.alternative[1]): $(missing_metrics)")

        push!(rows, (
            alternative = String(alt_df.alternative[1]),
            campaign_mode = String(alt_df.campaign_mode[1]),
            source_policy = String(alt_df.source_policy[1]),
            is_static_baseline = Bool(alt_df.is_static_baseline[1]),
            simtime = values[:simtime],
            ontime_share = values[:ontime_share],
            mean_processing_ratio = values[:mean_processing_ratio],
        ))
    end

    out = DataFrame(rows)
    sort!(out, :alternative; by = ex_post_sort_key)

    return out
end

function build_all_ex_post_table(pareto_exact::DataFrame, pareto_tolerance::DataFrame)::DataFrame
    tolerance_lookup = Dict(String(row.alternative) => Bool(row.within_pareto_tolerance) for row in eachrow(pareto_tolerance))
    score_lookup = Dict(String(row.alternative) => Float64(row.composite_score) for row in eachrow(pareto_exact))

    rows = NamedTuple[]

    for row in eachrow(pareto_exact)
        alternative = String(row.alternative)

        push!(rows, (
            alternative = alternative,
            campaign_mode = String(row.campaign_mode),
            source_policy = String(row.source_policy),
            is_static_baseline = Bool(row.is_static_baseline),
            exact_pareto = Bool(row.pareto_efficient),
            within_pareto_tolerance = get(tolerance_lookup, alternative, false),
            composite_score = get(score_lookup, alternative, 0.0),
            simtime = Float64(row.simtime),
            ontime_share = Float64(row.ontime_share),
            mean_processing_ratio = Float64(row.mean_processing_ratio),
        ))
    end

    out = DataFrame(rows)
    sort!(out, [:campaign_mode, :source_policy])

    return out
end

function build_selected_table(pareto_exact::DataFrame, pareto_tolerance::DataFrame)::DataFrame
    all_table = build_all_ex_post_table(pareto_exact, pareto_tolerance)
    out = all_table[all_table.exact_pareto .== true, :]
    sort!(out, [:campaign_mode, :source_policy])

    println("  final plotted alternatives: $(nrow(out))")
    println("  final global Pareto: $(count(Bool.(out.exact_pareto)))")
    println("  final static Pareto baselines: $(count(Bool.(out.is_static_baseline)))")
    println("  final adaptive or combined Pareto alternatives: $(count(.!Bool.(out.is_static_baseline)))")

    return out
end

function filter_summary_to_selected(summary_df::DataFrame, selected_table::DataFrame)::DataFrame
    selected = Set(String.(selected_table.alternative))
    out = summary_df[in.(String.(summary_df.alternative), Ref(selected)), :]
    sort!(out, [:campaign_mode, :alternative, :metric])
    return out
end

function filter_raw_to_selected(raw_df::DataFrame, selected_table::DataFrame)::DataFrame
    selected = Set(String.(selected_table.alternative))
    out = raw_df[in.(String.(raw_df.alternative), Ref(selected)), :]
    sort!(out, [:campaign_mode, :alternative, :replication_id])
    return out
end

function build_metric_ranking(summary_df::DataFrame)::DataFrame
    rows = NamedTuple[]

    for spec in EX_POST_KPI_SPECS
        metric_df = summary_df[summary_df.metric .== String(spec.column), :]
        nrow(metric_df) == 0 && continue

        order = sortperm(Float64.(metric_df.mean); rev = spec.higher_is_better)

        for (rank, row_idx) in enumerate(order)
            row = metric_df[row_idx, :]

            push!(rows, (
                metric = String(spec.column),
                title = spec.title,
                direction = spec.higher_is_better ? "higher is better" : "lower is better",
                rank = rank,
                alternative = String(row.alternative),
                campaign_mode = String(row.campaign_mode),
                source_policy = String(row.source_policy),
                is_static_baseline = Bool(row.is_static_baseline),
                mean = Float64(row.mean),
                std = Float64(row.std),
                replications = Int(row.replications),
            ))
        end
    end

    return DataFrame(rows)
end

function build_best_by_kpi(ranking_df::DataFrame)::DataFrame
    rows = NamedTuple[]

    for metric_df in groupby(ranking_df, :metric)
        best = metric_df[metric_df.rank .== 1, :]
        nrow(best) == 0 && continue
        push!(rows, NamedTuple(best[1, :]))
    end

    return DataFrame(rows)
end

function best_index(values::Vector{Float64}; higher_is_better::Bool)::Int
    return higher_is_better ? argmax(values) : argmin(values)
end

function ex_post_metric_spec(column::Symbol)
    matches = [spec for spec in EX_POST_PARETO_SPECS if spec.column == column]
    isempty(matches) && error("Unknown ex-post Pareto metric: $(column)")
    return only(matches)
end

function ex_post_dominates(candidate, target, specs)::Bool
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

function ex_post_cut_pareto_flags(df::DataFrame, xcol::Symbol, ycol::Symbol)::Vector{Bool}
    specs = [ex_post_metric_spec(xcol), ex_post_metric_spec(ycol)]
    flags = trues(nrow(df))

    for target_idx in 1:nrow(df)
        for candidate_idx in 1:nrow(df)
            candidate_idx == target_idx && continue

            if ex_post_dominates(df[candidate_idx, :], df[target_idx, :], specs)
                flags[target_idx] = false
                break
            end
        end
    end

    return flags
end

function label_rows_for_plot(df::DataFrame, xcol::Symbol, ycol::Symbol)::DataFrame
    rows = Int[]

    xspec = ex_post_metric_spec(xcol)
    yspec = ex_post_metric_spec(ycol)

    push!(rows, best_index(Float64.(df[!, xcol]); higher_is_better = xspec.higher_is_better))
    push!(rows, best_index(Float64.(df[!, ycol]); higher_is_better = yspec.higher_is_better))

    if :composite_score in propertynames(df)
        push!(rows, argmax(Float64.(df.composite_score)))
    end

    return df[unique(rows), :]
end

function representative_extreme_rows(df::DataFrame, xcol::Symbol, ycol::Symbol)::Vector{String}
    selected = String[]

    xspec = ex_post_metric_spec(xcol)
    yspec = ex_post_metric_spec(ycol)

    push!(
        selected,
        String(df[best_index(Float64.(df[!, xcol]); higher_is_better = xspec.higher_is_better), :alternative]),
    )

    push!(
        selected,
        String(df[best_index(Float64.(df[!, ycol]); higher_is_better = yspec.higher_is_better), :alternative]),
    )

    return selected
end

function normalized_curve_values(values::Vector{Float64})::Vector{Float64}
    minimum_value = minimum(values)
    maximum_value = maximum(values)

    if isapprox(minimum_value, maximum_value; atol = 1e-12, rtol = 1e-12)
        return fill(0.5, length(values))
    end

    return (values .- minimum_value) ./ (maximum_value - minimum_value)
end

function ordered_cut_table(df::DataFrame, xcol::Symbol, ycol::Symbol)::DataFrame
    out = copy(df)
    sort!(out, [xcol, ycol])
    return out
end

function representative_curvature_rows(df::DataFrame, xcol::Symbol, ycol::Symbol; top_n::Int = EX_POST_CURVATURE_POINTS_PER_CUT)::Vector{String}
    nrow(df) < 3 && return String[]

    sorted_df = ordered_cut_table(df, xcol, ycol)

    x = normalized_curve_values(Float64.(sorted_df[!, xcol]))
    y = normalized_curve_values(Float64.(sorted_df[!, ycol]))

    candidates = NamedTuple[]

    for idx in 2:(nrow(sorted_df) - 1)
        previous_vector = [x[idx] - x[idx - 1], y[idx] - y[idx - 1]]
        next_vector = [x[idx + 1] - x[idx], y[idx + 1] - y[idx]]

        previous_norm = sqrt(sum(previous_vector .^ 2))
        next_norm = sqrt(sum(next_vector .^ 2))

        if previous_norm <= 1e-12 || next_norm <= 1e-12
            continue
        end

        cosine_value = dot(previous_vector, next_vector) / (previous_norm * next_norm)
        cosine_value = clamp(cosine_value, -1.0, 1.0)
        angle = acos(cosine_value)

        push!(
            candidates,
            (
                alternative = String(sorted_df[idx, :alternative]),
                curvature = angle,
            ),
        )
    end

    isempty(candidates) && return String[]

    ranked = sort(candidates; by = candidate -> candidate.curvature, rev = true)
    selected = [candidate.alternative for candidate in ranked[1:min(top_n, length(ranked))]]

    return selected
end

function representative_quantile_rows(df::DataFrame, xcol::Symbol, ycol::Symbol; quantiles::Vector{Float64} = EX_POST_CUT_QUANTILES)::Vector{String}
    nrow(df) == 0 && return String[]

    sorted_df = ordered_cut_table(df, xcol, ycol)
    selected = String[]

    for q in quantiles
        idx = clamp(round(Int, 1 + q * (nrow(sorted_df) - 1)), 1, nrow(sorted_df))
        push!(selected, String(sorted_df[idx, :alternative]))
    end

    return unique(selected)
end

function add_boxplot_alternative!(selection_reasons::Dict{String, Vector{String}}, alternative::String, reason::String)
    if !haskey(selection_reasons, alternative)
        selection_reasons[alternative] = String[]
    end

    push!(selection_reasons[alternative], reason)
end

function is_fifo_policy(row)::Bool
    source_policy = lowercase(String(row.source_policy))
    alternative = lowercase(String(row.alternative))

    return occursin("fifo", source_policy) || occursin("fifo", alternative)
end

function build_boxplot_selection_reasons(all_table::DataFrame, selected_table::DataFrame)::Dict{String, Vector{String}}
    selection_reasons = Dict{String, Vector{String}}()

    fifo_rows = all_table[[is_fifo_policy(row) && Bool(row.is_static_baseline) for row in eachrow(all_table)], :]

    println("  FIFO candidates found for boxplot: $(nrow(fifo_rows))")

    for row in eachrow(fifo_rows)
        add_boxplot_alternative!(selection_reasons, String(row.alternative), "FIFO static baseline")
    end

    static_pareto = selected_table[
        [
            Bool(row.is_static_baseline) && !is_fifo_policy(row)
            for row in eachrow(selected_table)
        ],
        :,
    ]

    for row in eachrow(static_pareto)
        add_boxplot_alternative!(selection_reasons, String(row.alternative), "static Pareto baseline")
    end

    static_nonpareto = all_table[
        [
            Bool(row.is_static_baseline) &&
            !Bool(row.exact_pareto) &&
            !is_fifo_policy(row)
            for row in eachrow(all_table)
        ],
        :,
    ]

    if nrow(static_nonpareto) > 0
        sort!(static_nonpareto, :composite_score; rev = true)

        for row in eachrow(static_nonpareto[1:min(EX_POST_STATIC_BASELINE_COUNT, nrow(static_nonpareto)), :])
            add_boxplot_alternative!(selection_reasons, String(row.alternative), "top static baseline by composite score")
        end
    end

    if nrow(selected_table) > 0
        best_compromise = selected_table[argmax(Float64.(selected_table.composite_score)), :]
        add_boxplot_alternative!(selection_reasons, String(best_compromise.alternative), "global best compromise")
    end

    for (xcol, ycol) in EX_POST_CUT_PAIRS
        cut_name = "$(xcol)_vs_$(ycol)"
        cut_flags = ex_post_cut_pareto_flags(selected_table, xcol, ycol)
        cut_df = selected_table[cut_flags, :]

        nrow(cut_df) == 0 && continue

        for alternative in representative_extreme_rows(cut_df, xcol, ycol)
            add_boxplot_alternative!(selection_reasons, alternative, "cut extreme: $(cut_name)")
        end

        for alternative in representative_curvature_rows(cut_df, xcol, ycol)
            add_boxplot_alternative!(selection_reasons, alternative, "cut curvature: $(cut_name)")
        end

        for alternative in representative_quantile_rows(cut_df, xcol, ycol)
            add_boxplot_alternative!(selection_reasons, alternative, "cut intermediate: $(cut_name)")
        end
    end

    return selection_reasons
end

function build_boxplot_selected_table(all_table::DataFrame, selected_table::DataFrame)::DataFrame
    selection_reasons = build_boxplot_selection_reasons(all_table, selected_table)
    selected_alternatives = Set(keys(selection_reasons))

    out = all_table[in.(String.(all_table.alternative), Ref(selected_alternatives)), :]
    out.selection_reason = [
        join(unique(selection_reasons[String(row.alternative)]), "; ")
        for row in eachrow(out)
    ]

    sort!(out, [:is_static_baseline, :exact_pareto, :campaign_mode, :source_policy]; rev = [true, true, false, false])

    println("  boxplot representative alternatives: $(nrow(out))")
    println("  boxplot static Pareto baselines: $(count((Bool.(out.is_static_baseline)) .& (Bool.(out.exact_pareto))))")
    println("  boxplot static baseline non-Pareto references: $(count((Bool.(out.is_static_baseline)) .& (.!Bool.(out.exact_pareto))))")
    println("  boxplot adaptive or combined Pareto alternatives: $(count((.!Bool.(out.is_static_baseline)) .& (Bool.(out.exact_pareto))))")

    return out
end

function ex_post_pareto_view_plot(df::DataFrame, xcol::Symbol, ycol::Symbol; xlabel::String, ylabel::String, title::String, tolerance_percent::Float64)
    is_global_pareto = Bool.(df.exact_pareto)
    is_static = Bool.(df.is_static_baseline)
    is_adaptive = .!is_static
    is_cut_pareto = ex_post_cut_pareto_flags(df, xcol, ycol)

    global_only_rows = df[is_global_pareto .& (.!is_cut_pareto), :]
    global_cut_rows = df[is_global_pareto .& is_cut_pareto, :]

    static_rows = df[is_static, :]
    adaptive_rows = df[is_adaptive, :]

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

    nrow(global_only_rows) > 0 && scatter!(
        p,
        Float64.(global_only_rows[!, xcol]),
        Float64.(global_only_rows[!, ycol]);
        label = "Global Pareto only",
        markershape = :circle,
        markercolor = :dodgerblue,
        markerstrokecolor = :black,
        markerstrokewidth = 1.0,
        markersize = 7,
    )

    nrow(global_cut_rows) > 0 && scatter!(
        p,
        Float64.(global_cut_rows[!, xcol]),
        Float64.(global_cut_rows[!, ycol]);
        label = "Global and cut Pareto",
        markershape = :circle,
        markercolor = :green3,
        markerstrokecolor = :black,
        markerstrokewidth = 1.0,
        markersize = 8,
    )

    nrow(static_rows) > 0 && scatter!(
        p,
        Float64.(static_rows[!, xcol]),
        Float64.(static_rows[!, ycol]);
        label = "Static Pareto baseline",
        markershape = :x,
        markercolor = :black,
        markerstrokecolor = :black,
        markerstrokewidth = 1.5,
        markersize = 4.8,
    )

    nrow(adaptive_rows) > 0 && scatter!(
        p,
        Float64.(adaptive_rows[!, xcol]),
        Float64.(adaptive_rows[!, ycol]);
        label = "Adaptive or combined Pareto",
        markershape = :circle,
        markercolor = :black,
        markerstrokecolor = :black,
        markersize = 2.8,
    )

    label_df = label_rows_for_plot(df, xcol, ycol)

    for row in eachrow(label_df)
        annotate!(
            p,
            Float64(row[xcol]),
            Float64(row[ycol]),
            text(short_ex_post_label(row.alternative), 8, :left, :black),
        )
    end

    return p
end

function save_ex_post_pareto_plot(selected_table::DataFrame, output_dir::String; tolerance_percent::Float64)
    plots = [
        ex_post_pareto_view_plot(
            selected_table,
            :simtime,
            :ontime_share;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "On-Time Share (%)",
            title = "Makespan vs On-Time",
            tolerance_percent = tolerance_percent,
        ),
        ex_post_pareto_view_plot(
            selected_table,
            :simtime,
            :mean_processing_ratio;
            xlabel = "Total Makespan (lower is better)",
            ylabel = "Mean Processing Ratio",
            title = "Makespan vs Processing Ratio",
            tolerance_percent = tolerance_percent,
        ),
        ex_post_pareto_view_plot(
            selected_table,
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
            plot_title = "Ex-Post Pareto Comparison",
            plot_titlefontsize = 20,
            bottom_margin = 8Plots.mm,
            left_margin = 8Plots.mm,
        ),
        joinpath(output_dir, "ex_post_global_pareto_plot.png"),
    )
end

function ex_post_visual_summary_rows()
    return [
        [:simtime, :throughput, :mean_saturation, nothing],
        [:mean_lateness, :mean_tardiness, :ontime_share, :mean_wip_queue],
        [:mean_queuetime, :mean_queue_length, :mean_makespan, :mean_processing_ratio],
    ]
end

function ex_post_visual_summary_spec(column::Symbol)
    matches = [spec for spec in EX_POST_KPI_SPECS if spec.column == column]
    isempty(matches) && error("Missing ex-post visual summary metric: $(column)")
    return only(matches)
end

function ex_post_boxplot_order(selected_table::DataFrame)::DataFrame
    selected = copy(selected_table)

    selected.is_fifo_baseline = [is_fifo_policy(row) for row in eachrow(selected)]

    sort!(
        selected,
        [:is_fifo_baseline, :is_static_baseline, :exact_pareto, :campaign_mode, :source_policy];
        rev = [true, true, true, false, false],
    )

    return selected
end

function compute_ex_post_highlight_roles(mean_values::Vector{Float64}, higher_is_better::Bool)
    n = length(mean_values)
    roles = fill(:mid, n)
    n == 0 && return roles

    best_order = sortperm(mean_values; rev = higher_is_better)
    worst_order = sortperm(mean_values; rev = !higher_is_better)

    for idx in best_order[1:min(2, n)]
        roles[idx] = :best
    end

    for idx in worst_order[1:min(2, n)]
        roles[idx] == :best && continue
        roles[idx] = :worst
    end

    return roles
end

function ex_post_role_series_data(values_by_alternative::Vector{Vector{Float64}}, roles::Vector{Symbol}, target_role::Symbol)
    x_values = Int[]
    y_values = Float64[]

    for (idx, values) in enumerate(values_by_alternative)
        roles[idx] == target_role || continue
        append!(x_values, fill(idx, length(values)))
        append!(y_values, values)
    end

    return x_values, y_values
end

function empty_ex_post_summary_cell()
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
        left_margin = 0Plots.mm,
        right_margin = 0Plots.mm,
        top_margin = 0Plots.mm,
        bottom_margin = 0Plots.mm,
    )
end

function ex_post_boxplot_metric(raw_df::DataFrame, selected_table::DataFrame, spec)
    selected = ex_post_boxplot_order(selected_table)

    alternatives = String.(selected.alternative)
    labels = [short_ex_post_label(alternative) for alternative in alternatives]

    values_by_alternative = [
        Float64.(raw_df[raw_df.alternative .== alternative, spec.column])
        for alternative in alternatives
    ]

    mean_values = [mean(values) for values in values_by_alternative]
    roles = compute_ex_post_highlight_roles(mean_values, spec.higher_is_better)

    p = plot(
        xlabel = "",
        ylabel = "",
        title = "$(spec.title)\n$(spec.higher_is_better ? "higher is better" : "lower is better")",
        xticks = (1:length(alternatives), labels),
        xrotation = 35,
        label = false,
        titlefont = font(13),
        guidefont = font(10),
        tickfont = font(9),
        legendfont = font(9),
        grid = :y,
        gridalpha = 0.18,
        framestyle = :box,
        top_margin = 5Plots.mm,
        bottom_margin = 12Plots.mm,
        left_margin = 7Plots.mm,
    )

    mid_x, mid_y = ex_post_role_series_data(values_by_alternative, roles, :mid)
    !isempty(mid_x) && boxplot!(
        p,
        mid_x,
        mid_y;
        label = false,
        seriescolor = EX_POST_BOXPLOT_COLORS.mid,
        markercolor = :black,
        markersize = 2.0,
        outliers = true,
    )

    best_x, best_y = ex_post_role_series_data(values_by_alternative, roles, :best)
    !isempty(best_x) && boxplot!(
        p,
        best_x,
        best_y;
        label = false,
        seriescolor = EX_POST_BOXPLOT_COLORS.best,
        markercolor = :black,
        markersize = 2.0,
        outliers = true,
    )

    worst_x, worst_y = ex_post_role_series_data(values_by_alternative, roles, :worst)
    !isempty(worst_x) && boxplot!(
        p,
        worst_x,
        worst_y;
        label = false,
        seriescolor = EX_POST_BOXPLOT_COLORS.worst,
        markercolor = :black,
        markersize = 2.0,
        outliers = true,
    )

    return p
end

function save_ex_post_boxplot_panel(raw_boxplot::DataFrame, boxplot_table::DataFrame, output_dir::String)
    panel_plots = Any[]

    for row in ex_post_visual_summary_rows()
        for column in row
            if column === nothing
                push!(panel_plots, empty_ex_post_summary_cell())
            else
                spec = ex_post_visual_summary_spec(column)
                if spec.column in propertynames(raw_boxplot)
                    push!(panel_plots, ex_post_boxplot_metric(raw_boxplot, boxplot_table, spec))
                else
                    push!(panel_plots, empty_ex_post_summary_cell())
                end
            end
        end
    end

    savefig(
        plot(
            panel_plots...;
            layout = (3, 4),
            size = (4200, 2400),
            plot_title = "Ex-Post Visual Summary - Representative Boxplots",
            plot_titlefont = font(24),
            left_margin = 10Plots.mm,
            bottom_margin = 12Plots.mm,
        ),
        joinpath(output_dir, "ex_post_boxplot_panel.png"),
    )
end

function build_ex_post_report(
    output_path::String,
    input_dirs::Dict{Symbol, String},
    selected_table::DataFrame,
    boxplot_table::DataFrame,
    best_by_kpi::DataFrame;
    tolerance_percent::Float64,
)
    io = IOBuffer()

    println(io, "# Ex-Post Evaluation Report")
    println(io)

    println(io, "## Compared Campaigns")
    for run_mode in sort(collect(keys(input_dirs)); by = String)
        println(io, "- `$(run_mode)`: `$(input_dirs[run_mode])`")
    end
    println(io)

    println(io, "## Selection Rule")
    println(io, "- adaptive and combined alternatives are loaded only if they were already selected as exact Pareto or within Pareto tolerance in their original evaluation")
    println(io, "- original static baselines are loaded for comparison")
    println(io, "- the Pareto plot keeps only global Pareto alternatives after ex-post recalculation")
    println(io, "- the boxplot panel keeps a richer representative set: static Pareto baselines, top static non-Pareto baselines, cut extremes, top curvature points, intermediate cut points, and best compromise")
    println(io, "- equivalence band around exact Pareto: `$(tolerance_percent)%`")
    println(io)

    println(io, "## Selected Alternatives For Pareto Plot")
    println(io, markdown_table(selected_table; max_rows = min(nrow(selected_table), 80)))
    println(io)

    println(io, "## Representative Alternatives For Boxplots")
    println(io, markdown_table(boxplot_table; max_rows = min(nrow(boxplot_table), 100)))
    println(io)

    println(io, "## Best By KPI Within Selected Pareto Alternatives")
    println(io, markdown_table(best_by_kpi; max_rows = nrow(best_by_kpi)))
    println(io)

    println(io, "## Reading Notes")
    println(io, "- this ex-post evaluation uses the three global Pareto KPIs for Pareto filtering: total makespan, on-time share, and mean processing ratio")
    println(io, "- the boxplot panel uses all 11 ANOVA KPI columns available in `EX_POST_KPI_SPECS`")
    println(io, "- green boxplots indicate the two best alternatives for each KPI")
    println(io, "- red boxplots indicate the two worst alternatives for each KPI")
    println(io, "- blue boxplots indicate the remaining alternatives")
    println(io, "- blue circles are global Pareto alternatives that are not Pareto in the current 2D cut")
    println(io, "- green circles are both global Pareto and Pareto in the current 2D cut")
    println(io, "- black crosses indicate static Pareto baselines")
    println(io, "- black dots indicate adaptive or combined Pareto policies")
    println(io, "- labels show only best X, best Y, and best compromise")
    println(io, "- `ex_post_boxplot_panel.png` shows boxplots over replications for representative alternatives")
    println(io, "- the boxplot panel is an export visualization only; it does not rerun statistical ANOVA")

    write(output_path, String(take!(io)))
end

function performExPostEvaluation(; input_dirs::Dict{Symbol, String}, output_dir::String = EX_POST_OUTPUT_DIR)
    println("##### starting ex-post evaluation #########################")

    tolerance_percent = pareto_tolerance_percent()

    println("### collecting selected raw data")
    raw_loaded = collect_ex_post_raw(input_dirs)

    println("### building loaded summary")
    summary_loaded = build_ex_post_summary(raw_loaded)

    println("### building ex-post Pareto source")
    pareto_source = ex_post_summary_to_pareto_source(summary_loaded)

    println("### computing exact global Pareto on reduced ex-post set")
    pareto_exact = global_pareto_table(pareto_source)
    println("  exact global Pareto alternatives: $(count(Bool.(pareto_exact.pareto_efficient)))")

    println("### computing Pareto tolerance on reduced ex-post set")
    pareto_tolerance = pareto_tolerance_table(
        pareto_source,
        pareto_exact;
        tolerance_percent = tolerance_percent,
    )

    println("### building all ex-post alternatives table")
    all_table = build_all_ex_post_table(pareto_exact, pareto_tolerance)

    println("### building final Pareto selected table")
    selected_table = build_selected_table(pareto_exact, pareto_tolerance)

    println("### building representative boxplot table")
    boxplot_table = build_boxplot_selected_table(all_table, selected_table)

    println("### filtering raw and summary")
    raw_selected = filter_raw_to_selected(raw_loaded, selected_table)
    raw_boxplot = filter_raw_to_selected(raw_loaded, boxplot_table)
    summary_selected = filter_summary_to_selected(summary_loaded, selected_table)

    println("### building selected rankings")
    ranking_selected = build_metric_ranking(summary_selected)
    best_by_kpi = build_best_by_kpi(ranking_selected)

    println("### saving outputs")
    reset_output_dir(output_dir)

    CSV.write(joinpath(output_dir, "ex_post_selected_alternatives.csv"), selected_table)
    CSV.write(joinpath(output_dir, "ex_post_boxplot_alternatives.csv"), boxplot_table)
    CSV.write(joinpath(output_dir, "ex_post_summary_selected.csv"), summary_selected)
    CSV.write(joinpath(output_dir, "ex_post_best_by_kpi_selected.csv"), best_by_kpi)

    println("### saving Pareto plot")
    save_ex_post_pareto_plot(selected_table, output_dir; tolerance_percent = tolerance_percent)

    println("### saving representative ex-post boxplot panel")
    save_ex_post_boxplot_panel(raw_boxplot, boxplot_table, output_dir)

    println("### saving report")
    build_ex_post_report(
        joinpath(output_dir, "report.md"),
        input_dirs,
        selected_table,
        boxplot_table,
        best_by_kpi;
        tolerance_percent = tolerance_percent,
    )

    println("##### ex-post evaluation outputs saved in $(output_dir) #####")
end

function exPostRunNumber(path::String)::Union{Nothing, Int}
    m = match(r"^r(\d+)_", basename(path))
    m === nothing && return nothing
    return parse(Int, m.captures[1])
end

function exPostInputDirsFromRange(run_range; root::String = ".")::Dict{Symbol, String}
    wanted = Set(Int.(collect(run_range)))
    inputDirs = Dict{Symbol, String}()

    for item in readdir(root)
        fullPath = joinpath(root, item)
        isdir(fullPath) || continue
        endswith(item, "_evaluation") && continue

        number = exPostRunNumber(item)
        number === nothing && continue
        number in wanted || continue

        if occursin("_static", item)
            inputDirs[:static] = item

        elseif occursin("_adaptive_", item)
            if occursin("_spt", item)
                inputDirs[:adaptive_first] = item
            elseif occursin("_edd", item)
                inputDirs[:adaptive_second] = item
            else
                inputDirs[Symbol("adaptive_", number)] = item
            end

        elseif occursin("_combined_", item)
            if occursin("_spt_first_edd", item)
                inputDirs[:combined_first] = item
            elseif occursin("_edd_first_spt", item)
                inputDirs[:combined_second] = item
            else
                inputDirs[Symbol("combined_", number)] = item
            end
        end
    end

    isempty(inputDirs) && error("No ex-post input directories found for run range $(collect(run_range))")

    return inputDirs
end

function ensureExPostAnovaForRange!(inputDirs::Dict{Symbol, String})
    for path in values(inputDirs)
        requiredOutput = Main.orchestration.requiredAnovaOutput(path)
        isfile(requiredOutput) && continue
        println("##### ANOVA summary missing for ex-post: $(requiredOutput) #####")
        println("##### running ANOVA first on $(path) #####")
        Main.showanova.performAnova(path)
    end
end


function performRangeExPostEvaluation(;
    run_range = exPostRunRange,
    output_dir = exPostOutputDir,
)
    resolvedOutputDir = exPostRangeOutputDir(run_range, output_dir)

    println("##### starting range ex-post evaluation ################")
    println("  run range: $(minimum(Int.(collect(run_range)))):$(maximum(Int.(collect(run_range))))")
    println("  output dir: $(resolvedOutputDir)")

    inputDirs = exPostInputDirsFromRange(run_range)

    println("### ensuring ANOVA summaries for ex-post input campaigns")
    ensureExPostAnovaForRange!(inputDirs)

    println("### running full ex-post evaluation with plots")
    performExPostEvaluation(
        input_dirs = inputDirs,
        output_dir = resolvedOutputDir,
    )

    println("### identifying best policies inside ex-post output")
    final = Main.findbest.identifyBestPoliciesFromRuns(
        run_range;
        output_dir = resolvedOutputDir,
        prefix = "ex_post",
    )

    println("##### range ex-post evaluation saved in $(resolvedOutputDir) #####")

    return final
end

end
