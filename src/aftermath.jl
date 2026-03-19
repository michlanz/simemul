module showdash

using CSV
using DataFrames
using StatsPlots
using Plots
using PrettyTables#: fmt_printf
using Crayons


export plotresults,
       plot_saturation,
       plot_queuelen_box,
       plot_queuetime_box,
       plot_makespan_box,
       plot_infoview,
       plot_wip,
       closingprint,
       savefigs
       #plot_clients, plot_unitsinsystem, plot_queuelen_time

       
function plotresults(outpath::String)#; monitor::Vector{SystemLog}; clients::Vector{Client})    
    println("##### iniziando a plottare i grafici #######")
    p1 = plot_saturation(outpath)
    #p6 = plot_queuelen_time(outpath)
    p3 = plot_queuelen_box(outpath)
    p4 = plot_queuetime_box(outpath)
    #p5 = plot_unitsinsystem(outpath)
    p2 = plot_makespan_box(outpath)
    #plot_gantt(outpath)
    p5 = plot_infoview(outpath)
    p6 = plot_wip(outpath)
    #savefig(Plots.plot(p1, p2, p3, p4, p5, p6; grid=(2, 3), size=(2600, 1400), left_margin=15*Plots.mm, bottom_margin=15*Plots.mm), joinpath(outpath, "dashfig.png"))
    #pie = plot_clients(outpath)

    savefig(Plots.plot(p5, p6, p1, p2, p3, p4; grid=(2, 3), size=(2600, 1400), left_margin=15*Plots.mm, bottom_margin=15*Plots.mm), joinpath(outpath, "dashfig.png"))
    println("##### grafici salvati ######################")
end

function plot_infoview(outpath::String)
    df_infoview = CSV.read(joinpath(outpath, "infoview.csv"), DataFrame)

    df_top = df_infoview[:, ["KPI", "Mean", "StdDevAmongSimulations"]]
    df_bottom = df_infoview[:, ["KPI", "Percentile10", "Median", "Percentile90"]]

    style = TextTableStyle(
        first_line_column_label = crayon"bold yellow",
    )

    table_str_top = pretty_table(
        String,
        df_top;
        column_labels = ["KPI", "Mean", "Dev.Std"],
        style = style,
        formatters = [fmt__printf("%.2f")],
    )
    
    table_str_bottom = pretty_table(
        String,
        df_bottom;
        column_labels = ["KPI", "P10", "Median", "P90"],
        style = style,
        formatters = [fmt__printf("%.2f")],
    )

    p = plot(framestyle = :none, legend = false, yticks = [], xticks = [])

    annotate!(p, -0.10, 0.70, text(table_str_top, :left, 14, "JuliaMono"))
    annotate!(p, -0.10, 0.20, text(table_str_bottom, :left, 14, "JuliaMono"))

    return p
end

## # function plot_overcrowd(outpath::String)
## #     df_overcrowd = CSV.read(joinpath(outpath, "overcrowd.csv"), DataFrame)
## #     sorted_overcrowd = sort(df_overcrowd.overcrowd_value)
## #     p = plot(sorted_overcrowd, xlabel = "Simulation Run (sorted by outcome)", ylabel = "Overcrowd Value", title = "Overcrowd Distribution", legend = false, linewidth = 2.5)
## #     return p
## # end

function plot_wip(outpath::String)
    df_wip = CSV.read(joinpath(outpath, "wip.csv"), DataFrame)
    sort!(df_wip, :wip_total)
    p = plot(df_wip.wip_accepted, label = "WIP Accepted", color = :blue,linewidth = 2,xlabel = "Simulation Run (sorted by Total WIP)", ylabel = "WIP Value (avg per station)", title = "WIP Distribution and Overcrowd Gap (average per Station)",legend = :topleft)
    plot!(p, df_wip.wip_total, label = "WIP Total", color = :red, linewidth = 1,fillrange = df_wip.wip_accepted, fillcolor = :orange,fillalpha = 0.5)
    return p
end



function plot_saturation(outpath::String)
    df = CSV.read(joinpath(outpath, "saturation.csv"), DataFrame)
    p = groupedbar(
        df.machine,
        [df.idle_percent df.maint_percent df.repair_percent df.down_percent df.processing_percent], xlabel = "Machine", ylabel = "Percent (%)", title = "Resource Usage", label = ["Idle" "Maintenance" "Repair" "Down" "Working"], bar_position = :stack, legend = true, color = [:gray90 :lightskyblue2 :lightgoldenrod1 :tomato2 :palegreen2])
    hline!(p, [100], color=:black, linestyle=:dash, label="100%")
    return p
end

function plot_queuelen_box(outpath::String)
    df = CSV.read(joinpath(outpath, "queuelen_box.csv"), DataFrame)
    p = boxplot( df.station, df.queue_length, xlabel = "WorkStation", ylabel = "Queue Length", title = "Queue Length Distribution per WorkStation")
    return p
end

function plot_queuetime_box(outpath::String)
    df = CSV.read(joinpath(outpath, "queuetime_box.csv"), DataFrame)
    p = boxplot(df.station, df.waiting_time, xlabel = "Machine", ylabel = "Waiting Time", title = "Waiting Time Distribution per WorkStation")
    return p
end

function plot_makespan_box(outpath::String)
    df = CSV.read(joinpath(outpath, "makespan_box.csv"), DataFrame)
    p = boxplot(df.client_code, df.makespan, xlabel = "Client Code", ylabel = "Makespan", title = "Makespan Distribution per Client")
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




