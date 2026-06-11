using CSV
using DataFrames
ENV["GKSwstype"] = "100" # Save plots without opening GR windows.
using Plots
using Statistics

const INPUT_RESULTS_DIR = "results1"
const OUTPUT_EVALUATION_DIR = string(INPUT_RESULTS_DIR) * "_evaluation"

const KPI_SPECS = [
    (column = :mean_makespan, title = "Makespan", higher_is_better = false),
    (column = :ontime_share, title = "On-Time Share", higher_is_better = true),
    (column = :mean_waiting_time, title = "Waiting Time", higher_is_better = false),
    (column = :processing_ratio, title = "Processing Ratio", higher_is_better = true),
    (column = :mean_tardiness, title = "Tardiness", higher_is_better = false),
]

function policy_rule_name(policy_label::AbstractString)
    parts = split(String(policy_label), "."; limit = 2)
    return length(parts) == 2 ? parts[2] : String(policy_label)
end

function natural_label_key(label)::Tuple
    text = String(label)
    match_digits = match(r"(\d+)", text)
    number = match_digits === nothing ? typemax(Int) : parse(Int, match_digits.captures[1])
    return (replace(text, r"\d+" => ""), number, text)
end

function numeric_prefix_key(label)::Tuple
    text = String(label)
    match_digits = match(r"^(\d+)", text)
    number = match_digits === nothing ? typemax(Int) : parse(Int, match_digits.captures[1])
    return (number, text)
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
    sort!(infos, by = info -> numeric_prefix_key(info.policy))
    return infos
end

function sort_policy_code!(df::DataFrame)
    policy_order = Dict(policy => idx for (idx, policy) in enumerate(sort(unique(String.(df.policy)); by = numeric_prefix_key)))
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
    policies = sort(unique(String.(df.policy)); by = numeric_prefix_key)
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
    colors = higher_is_better ? [:firebrick, :white, :forestgreen] : [:forestgreen, :white, :firebrick]
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

    savefig(p, joinpath(output_dir, filename))
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
    policy_order = Dict(policy => idx for (idx, policy) in enumerate(sort(unique(String.(ranking_df.policy)); by = numeric_prefix_key)))
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

function build_report(output_path::String, summary_df::DataFrame, ranking_df::DataFrame, policy_focused_df::DataFrame)
    io = IOBuffer()
    println(io, "# Policy-Code Evaluation Report")
    println(io)
    println(io, "## Summary")
    println(io, "- input directory: `$(INPUT_RESULTS_DIR)`")
    println(io, "- output directory: `$(OUTPUT_EVALUATION_DIR)`")
    println(io, "- policies evaluated: `$(join(sort(unique(String.(summary_df.policy)); by = numeric_prefix_key), ", "))`")
    println(io, "- heatmaps are code-centric: each column asks which policy treats that code better or worse")
    println(io, "- code-focused dashboard: `dash_code.png`")
    println(io, "- policy-focused dashboard: `dash_policy.png`")
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
    println(io, "## Reading Notes")
    println(io, "- `codecentric` heatmaps answer: given a code, which policy treats it better or worse than that code average?")
    println(io, "- `policyfocused` heatmaps answer: given a policy, which codes are favored or penalized relative to that policy average?")
    println(io, "- Heatmap values are `code average under policy / code average * 100`; `100%` means equal to the code average.")
    println(io, "- Policy-focused heatmap values are `code average under policy / policy average * 100`; `100%` means equal to that policy average across codes.")
    println(io, "- Higher-is-better metrics use green above `100%`; lower-is-better metrics use green below `100%`.")
    write(output_path, String(take!(io)))
end

function reset_output_dir(output_dir::String)
    rm(output_dir; recursive = true, force = true)
    mkpath(output_dir)
end

function save_outputs(output_dir::String, summary_df::DataFrame, ranking_df::DataFrame, pareto_df::DataFrame, policy_focused_df::DataFrame)
    CSV.write(joinpath(output_dir, "policy_code_kpi_summary.csv"), summary_df)
    CSV.write(joinpath(output_dir, "policy_code_ranking.csv"), ranking_df)
    CSV.write(joinpath(output_dir, "policy_code_pareto.csv"), pareto_df)
    CSV.write(joinpath(output_dir, "policy_focused_code_ranking.csv"), policy_focused_df)
end

function main(; input_dir::String = INPUT_RESULTS_DIR, output_dir::String = OUTPUT_EVALUATION_DIR)
    println("##### starting policy-code evaluation #####################")
    infos = policy_infos(input_dir)
    summary_df = build_policy_code_kpis(infos)
    ranking_df, pareto_df = build_rankings(summary_df)
    policy_focused_df = build_policy_focused_rankings(summary_df)

    reset_output_dir(output_dir)
    save_outputs(output_dir, summary_df, ranking_df, pareto_df, policy_focused_df)

    for spec in KPI_SPECS
        save_heatmap(summary_df, spec.column, output_dir)
        save_heatmap(summary_df, spec.column, output_dir; focus = :policyfocused)
    end
    save_dashboard(summary_df, output_dir)
    save_dashboard(summary_df, output_dir; focus = :policyfocused)

    build_report(joinpath(output_dir, "report.md"), summary_df, ranking_df, policy_focused_df)
    println("##### evaluation outputs saved in $(output_dir) #####")
end

main()
