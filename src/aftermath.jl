module showdash

using CSV
using DataFrames
using StatsPlots
using Plots

using Main.simEmul.configdata: DashboardColors, makespanComponentColors, seriesColors

export plotresults,
       plot_wip_system_buckets,
       plot_wip_station_buckets,
       plot_saturation,
       plot_queuelen_box,
       plot_queuetime_box,
       plot_makespan_box,
       plot_makespan_composition,
       plot_ontime_share,
       plotPunctualitySummary,
       closingprint,
       savefigs
       #plot_clients, plot_unitsinsystem, plot_queuelen_time


function natural_sort_key(label)::Tuple
    text = String(label)
    prefix = replace(text, r"\d+" => "")
    suffix_match = match(r"(\d+)(?!.*\d)", text)
    suffix_num = suffix_match === nothing ? typemax(Int) : parse(Int, suffix_match.captures[1])
    return (prefix, suffix_num, text)
end

function ordered_labels(labels)
    return sort(unique(String.(labels)); by = natural_sort_key)
end

function label_positions(labels, ordered)
    return [findfirst(==(String(label)), ordered) for label in labels]
end

function ordered_components(components)
    return sort(unique(String.(components)); by = component_sort_key)
end

function component_sort_key(component)::Tuple
    text = String(component)
    if text == "PROCESSING"
        return (1, typemax(Int), text)
    end
    station = replace(text, "WAIT|" => "")
    return (0, natural_sort_key(station)[2], station)
end

function standard_plot_kwargs()
    return (
        titlefont = font(14),
        guidefont = font(10),
        tickfont = font(10),
        legendfont = font(10),
        grid = :y,
        gridalpha = 0.18,
        framestyle = :box,
    )
end

function dashfigTitle(policyName::String)
    return "Dashboard Policy: $(policyName)"
end

function dashfigTitlePlot(policyName::String)
    return plot(
        [0.5],
        [0.5];
        seriestype = :scatter,
        markersize = 0,
        markerstrokewidth = 0,
        markercolor = :white,
        color = :white,
        label = false,
        annotations = [(0.5, 0.5, Plots.text(dashfigTitle(policyName), 36, :black, :center))],
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

function plotresults(outpath::String)#; monitor::Vector{SystemLog}; clients::Vector{Client})    
    println("##### iniziando a plottare i grafici #######")
    policyName = basename(normpath(outpath))
    p0 = dashfigTitlePlot(policyName)
    p1 = plot_wip_system_buckets(outpath)
    p2 = plot_wip_station_buckets(outpath)
    p3 = plot_saturation(outpath)
    p4 = plot_queuelen_box(outpath)
    p5 = plot_queuetime_box(outpath)
    p6 = plot_makespan_box(outpath)
    p7 = plot_makespan_composition(outpath)
    p8 = plot_ontime_share(outpath)
    p9 = plotPunctualitySummary(outpath)

    savefig(
        Plots.plot(
            p0, p1, p2, p3, p4, p5, p6, p7, p8, p9;
            layout = Plots.@layout([title{0.08h}; grid(3, 3)]),
            size = (3600, 2200),
            left_margin = 10 * Plots.mm,
            bottom_margin = 12 * Plots.mm,
        ),
        joinpath(outpath, "dashfig.png"),
    )
    println("##### grafici salvati ######################")
end

## # function plot_overcrowd(outpath::String)
## #     df_overcrowd = CSV.read(joinpath(outpath, "overcrowd.csv"), DataFrame)
## #     sorted_overcrowd = sort(df_overcrowd.overcrowd_value)
## #     p = plot(sorted_overcrowd, xlabel = "Simulation Run (sorted by outcome)", ylabel = "Overcrowd Value", title = "Overcrowd Distribution", legend = false, linewidth = 2.5)
## #     return p
## # end

function plot_wip_system_buckets(outpath::String)
    df = CSV.read(joinpath(outpath, "wip_system_buckets.csv"), DataFrame)
    sort!(df, :bucket_id)
    xticks = (df.bucket_id, df.bucket_label)
    p = bar(
        df.bucket_id,
        df.mean_queue_wip;
        xlabel = "Time Bucket",
        ylabel = "Average Queue WIP",
        title = "System Queue WIP by 8h Bucket",
        label = false,
        xticks = xticks,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    return p
end

function plot_wip_station_buckets(outpath::String)
    df = CSV.read(joinpath(outpath, "wip_station_buckets.csv"), DataFrame)
    sort!(df, [:station, :bucket_id])
    stations = ordered_labels(df.station)
    bucket_ticks = combine(groupby(df, :bucket_id), :bucket_label => first => :bucket_label)
    sort!(bucket_ticks, :bucket_id)
    show_legend = length(stations) <= 8
    station_colors = seriesColors(Plots.palette, length(stations))

    p = plot(;
        xlabel = "Time Bucket",
        ylabel = "Average Queue WIP",
        title = "Station Queue WIP by 8h Bucket",
        legend = show_legend ? :outertopright : false,
        xticks = (bucket_ticks.bucket_id, bucket_ticks.bucket_label),
        xrotation = 35,
        standard_plot_kwargs()...,
    )

    for (idx, station) in enumerate(stations)
        subdf = df[df.station .== station, :]
        plot!(
            p,
            subdf.bucket_id,
            subdf.mean_queue_wip;
            label = station,
            linewidth = 4,
            marker = :circle,
            markersize = 6,
            markercolor = station_colors[idx],
            markerstrokecolor = station_colors[idx],
            color = station_colors[idx],
        )
    end

    return p
end


function plot_saturation(outpath::String)
    df = CSV.read(joinpath(outpath, "saturation.csv"), DataFrame)
    machines = ordered_labels(df.machine)
    sortperm_machines = sortperm(String.(df.machine); by = natural_sort_key)
    df = df[sortperm_machines, :]
    p = groupedbar(
        1:length(machines),
        [df.idle_percent df.processing_percent];
        xlabel = "Machine",
        ylabel = "Percent (%)",
        title = "Mean Machine Saturation",
        xticks = (1:length(machines), machines),
        label = ["Idle" "Working"],
        bar_position = :stack,
        legend = :outertopright,
        color = [DashboardColors.neutral DashboardColors.positive],
        standard_plot_kwargs()...,
    )
    hline!(p, [100], color=:black, linestyle=:dash, label="100%")
    return p
end

function plot_queuelen_box(outpath::String)
    df = CSV.read(joinpath(outpath, "queuelen_box.csv"), DataFrame)
    stations = ordered_labels(df.station)
    positions = label_positions(df.station, stations)
    p = boxplot(
        positions,
        df.queue_length;
        xlabel = "WorkStation",
        ylabel = "Queue Length",
        title = "Queue Length Distribution per WorkStation",
        xticks = (1:length(stations), stations),
        label = false,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    return p
end

function plot_queuetime_box(outpath::String)
    df = CSV.read(joinpath(outpath, "queuetime_box.csv"), DataFrame)
    stations = ordered_labels(df.station)
    positions = label_positions(df.station, stations)
    p = boxplot(
        positions,
        df.waiting_time;
        xlabel = "Machine",
        ylabel = "Waiting Time",
        title = "Waiting Time Distribution per WorkStation",
        xticks = (1:length(stations), stations),
        label = false,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    return p
end

function plot_makespan_box(outpath::String)
    df = CSV.read(joinpath(outpath, "punctuality_box.csv"), DataFrame)
    client_codes = ordered_labels(df.client_code)
    positions = label_positions(df.client_code, client_codes)
    p = boxplot(
        positions,
        df.makespan;
        xlabel = "Client Code",
        ylabel = "Makespan",
        title = "Makespan Distribution per Client Code",
        xticks = (1:length(client_codes), client_codes),
        label = false,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    return p
end

function plot_makespan_composition(outpath::String)
    df = CSV.read(joinpath(outpath, "makespan_composition.csv"), DataFrame)
    client_codes = ordered_labels(df.client_code)
    waiting_components = ordered_components(filter(!=("PROCESSING"), df.component))
    components = vcat(waiting_components, ["PROCESSING"])
    component_colors = makespanComponentColors(Plots.palette, length(waiting_components))

    values = zeros(length(client_codes), length(components))
    for (i, client_code) in enumerate(client_codes)
        for (j, component) in enumerate(components)
            subdf = df[(df.client_code .== client_code) .& (df.component .== component), :]
            values[i, j] = isempty(subdf) ? 0.0 : subdf.mean_time[1]
        end
    end

    labels = [component == "PROCESSING" ? "Processing" : replace(component, "WAIT|" => "Wait ") for component in components]
    p = groupedbar(
        client_codes,
        values;
        xlabel = "Client Code",
        ylabel = "Mean Time",
        title = "Mean Makespan Composition by Client Code",
        bar_position = :stack,
        color = permutedims(component_colors),
        label = permutedims(labels),
        legend = :outertopright,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    return p
end

function plot_ontime_share(outpath::String)
    df = CSV.read(joinpath(outpath, "ontime_share.csv"), DataFrame)
    client_codes = ordered_labels(df.client_code)
    sortperm_codes = sortperm(String.(df.client_code); by = natural_sort_key)
    df = df[sortperm_codes, :]
    p = groupedbar(
        1:length(client_codes),
        [df.ontime_percent df.tardy_percent];
        xlabel = "Client Code",
        ylabel = "Share (%)",
        title = "On-Time Share by Client Code",
        xticks = (1:length(client_codes), client_codes),
        bar_position = :stack,
        label = ["On Time" "Late"],
        color = [DashboardColors.positive DashboardColors.negative],
        legend = :outertopright,
        ylims = (0.0, 100.0),
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    hline!(p, [100.0], color = :black, linestyle = :dash, label = false)
    return p
end

function plotPunctualitySummary(outpath::String)
    df = CSV.read(joinpath(outpath, "punctuality_summary.csv"), DataFrame)
    client_codes = ordered_labels(df.client_code)
    sortperm_codes = sortperm(String.(df.client_code); by = natural_sort_key)
    df = df[sortperm_codes, :]
    p = groupedbar(
        1:length(client_codes),
        [df.mean_lateness df.mean_tardiness];
        xlabel = "Client Code",
        ylabel = "Mean Time",
        title = "Punctuality Summary by Client Code",
        xticks = (1:length(client_codes), client_codes),
        bar_position = :dodge,
        label = ["Lateness" "Tardiness"],
        color = [DashboardColors.caution DashboardColors.negative],
        legend = :outertopright,
        xrotation = 35,
        standard_plot_kwargs()...,
    )
    hline!(p, [0.0], color = :black, linestyle = :dash, label = false)
    return p
end

function nonvogliocancellareicommenti2()

    ## # function plot_queuelen_time(outpath::String)
    ## #     df = CSV.read(joinpath(outpath, "queuelen_time.csv"), DataFrame)
    ## #     stations = unique(df.station)
    ## #     plt = Plots.plot(title = "Queue Length Over Time", xlabel = "Time", ylabel = "Queue Length")
    ## #     show_legend = length(stations) < 20
    ## #     for m in stations
    ## #         subdf = df[df.station .== m, :]
    ## #         Plots.plot!(plt, subdf.timestamp, subdf.queue_length, label = show_legend ? m : false, seriestype=:steppost, linewidth = 2.5)
    ## #     end
    ## #     return plt
    ## # end
    ## # 
    ## # function plot_unitsinsystem(outpath::String)
    ## #     df = CSV.read(joinpath(outpath, "unitsinsystem_time.csv"), DataFrame)
    ## #     p = Plots.plot(df.timestamp, df.units_in_system, xlabel = "Time", ylabel = "Units in System", title = "Units in System Over Time", legend = false, seriestype=:steppost, linewidth = 2.5)
    ## #     return p
    ## # end

    # ## function plot_gantt(outpath::String)
    # ##     df = CSV.read(joinpath(outpath, "monitor.csv"), DataFrame)
    # ##     sort!(df, [:place, :timestamp])
    # ## 
    # ##     # intervalli startfinish per ogni macchina
    # ##     intervals = DataFrame(machine=String[], client=Int[], code=String[], start=Float64[], finish=Float64[])
    # ##     for m in unique(df.place)
    # ##         df_m = df[(df.place .== m) .& ((df.event .== "startprocess") .| (df.event .== "finishprocess")), :]
    # ##         i = 1
    # ##         while i <= nrow(df_m) - 1
    # ##             if df_m.event[i] == "startprocess" && df_m.event[i+1] == "finishprocess"
    # ##                 push!(intervals, (m, df_m.id_client[i], df_m.code[i], df_m.timestamp[i], df_m.timestamp[i+1]))
    # ##                 i += 2
    # ##             else
    # ##                 i += 1
    # ##             end
    # ##         end
    # ##     end
    # ## 
    # ##     # ordine clienti per primo ingresso nel sistema
    # ##     arr = df[df.event .== "systemarrival", [:id_client, :timestamp]]
    # ##     clients_order = unique(sort(arr, :timestamp).id_client)
    # ## 
    # ##     # palette e mapping colori (mantengo :cool)
    # ##     base_palette = Plots.palette(:cool, length(clients_order))
    # ##     colors = [base_palette[findfirst(==(r.client), clients_order)] for r in eachrow(intervals)]
    # ## 
    # ##     # dimensioni adattive
    # ##     sim_time = maximum(df.timestamp)
    # ##     machines = unique(intervals.machine)
    # ##     nmachines = length(machines)
    # ##     fig_w = round(37 * sim_time)
    # ##     fig_h = round(70 * nmachines)
    # ##     tfs  = round(2 * nmachines) # title font size
    # ##     gfs  = round(1 * nmachines) # axes labels font size
    # ##     lfs  = round(0.02 * nmachines) # label dentro i box
    # ## 
    # ##     # rettangoli
    # ##     rect(w,h,x,y) = Shape(x .+ [0,w,w,0], y .+ [0,0,h,h])
    # ##     shapes = [rect(r.finish - r.start, 0.8, r.start, findfirst(==(r.machine), machines) - 0.4) for r in eachrow(intervals)]
    # ## 
    # ##     p = plot(shapes, c=permutedims(colors), legend=false,
    # ##              yticks=(1:nmachines, machines),
    # ##              xlabel="Time", ylabel="Machines", title="Client Processing Timeline",
    # ##              size=(fig_w, fig_h),
    # ##              titlefontsize=tfs, guidefontsize=gfs, tickfontsize=gfs)
    # ## 
    # ##     for r in eachrow(intervals)
    # ##         y = findfirst(==(r.machine), machines)
    # ##         annotate!((r.start + r.finish) / 2, y, text("$(r.code).$(r.client)", lfs, :black, :center))
    # ##     end
    # ## 
    # ##     savefig(p, joinpath(outpath, "ganttfig.png"))
    # ##     return p
    # ## end
    # ## 
    # ## 
    # ## function plot_clients(outpath::String)
    # ##     df = CSV.read(joinpath(outpath, "clients.csv"), DataFrame)
    # ##     freq = combine(groupby(df, :code), nrow => :count)
    # ##     sort!(freq, :count, rev=true)
    # ## 
    # ##     codes   = String.(freq.code)
    # ##     counts  = freq.count
    # ##     labels  = ["$(codes[i]): $(counts[i])" for i in eachindex(codes)]
    # ##     colors  = Plots.palette(:hawaii, length(codes))
    # ## 
    # ##     p = StatsPlots.pie(labels, counts; color=colors, legend=:outerright,
    # ##                        title="Clients per Code", size=(900, 700), legendfontsize=10)
    # ## 
    # ##     return p
    # ## end
end

function closingprint()
    println()
    println("############################################")
    println("########                            ########")
    println("########    Esperienza terminata    ########")
    println("########                            ########")
    println("############################################")
    println()
end


function savefigs(outpath::String)
    println("##### figure per simus in $outpath #####")
    subfolders = sort(readdir(outpath; join=true))
    for folder in subfolders
        if isdir(folder)
            println("###### salvo figure in $(basename(folder)) #############")
            plotresults(folder)
        end
    end
    println("##### salvataggio figure completato ########")
end

end
