module postprocess

using ..CSV
using ..DataFrames
#using ..DataFrames: names
using ..Statistics
using ..DataFrames: sort!
using ..structures: Dash, SystemLog, ProcessingTimeLog, QueueLenLog, QueueTimeLog, UnitsInSystemLog, MakespanLog#, Station, Client

export postprocessDF,
       buildQueuelen,
       buildSaturation,
       buildWip

# NOTE: non puoi salvare i logger, tanto le funzioni sono fatte bene

function postprocessDF(dashvector::Vector{Dash}, CLIENTNUM::Int64)
    CROWDLIMIT::Int64 = 8
    MINQ::Float64 = 0.1
    MAXQ::Float64 = 0.9

    vector_simtime::Vector{Float64} = Float64[]
    vector_mean_makespan::Vector{Float64} = Float64[]
    vector_mean_saturation::Vector{Float64} = Float64[]
    vector_mean_queuetime::Vector{Float64} = Float64[]
    vector_wip_total::Vector{Float64} = Float64[]
    vector_wip_accepted::Vector{Float64} = Float64[]
    
    merged_wip::DataFrame = DataFrame()
    merged_wipstation::DataFrame = DataFrame()
    merged_queuelenbox::DataFrame = DataFrame()
    merged_queuetimebox::DataFrame = DataFrame()
    merged_makespanbox::DataFrame = DataFrame()
    concat_saturation::DataFrame = DataFrame()
    

    for dash in dashvector
        simtime = dash.monitor_log[end].timestamp
        push!(vector_simtime, simtime)

        #faccio le allocazioni del df comune per il boxplot e per l'overcrowd
        df_queuelen = buildQueuelen(DataFrame(dash.queue_len_log), simtime)

        df_queuelenbox = deepcopy(df_queuelen)
        df_queuelenbox.percent = 100 .* df_queuelenbox.total_duration ./ simtime
        sort!(df_queuelenbox, [:station, :queue_length])
        append!(merged_queuelenbox, df_queuelenbox)

        df_queuetimebox = sort!(DataFrame(dash.queue_time_log), [:station])
        append!(merged_queuetimebox, df_queuetimebox)
        push!(vector_mean_queuetime, sum(df_queuetimebox.waiting_time) / CLIENTNUM)

        df_makespanbox = sort!(DataFrame(dash.makespan_log), [:client_code])
        append!(merged_makespanbox, df_makespanbox)
        push!(vector_mean_makespan, mean(df_makespanbox.makespan))

        df_saturation = buildSaturation(DataFrame(dash.processing_times_log), simtime)
        append!(concat_saturation, df_saturation)
        push!(vector_mean_saturation, mean(df_saturation.processing_percent))

        df_wip, df_wipstation = buildWip(df_queuelen, simtime, CROWDLIMIT)
        append!(merged_wip, df_wip)
        append!(merged_wipstation, df_wipstation)
        push!(vector_wip_total, df_wip.wip_total[1])
        push!(vector_wip_accepted, df_wip.wip_accepted[1])
        

    end

    # ----------------- 
    df_simtime = DataFrame(simtime = vector_simtime)
    merged_saturation = combine(groupby(concat_saturation, :machine), DataFrames.names(concat_saturation, Number) .=> mean; renamecols=false)

    # ----------- qui il df infoview messo dentro per semplicita
    df_infoview = DataFrame(KPI=String[], Mean=Float64[], StdDevAmongSimulations=Float64[], Percentile10=Float64[], Median=Float64[], Percentile90=Float64[])
    push!(df_infoview, ("Replications", length(dashvector), NaN, NaN, NaN, NaN))
    #push!(df_infoview, ("Lots per Run", CLIENTNUM, NaN, NaN, NaN, NaN)) # CLIENTNUM deve essere accessibile
    push!(df_infoview, ("WIP Total (avg per station)", mean(vector_wip_total), std(vector_wip_total), quantile(vector_wip_total, MINQ), median(vector_wip_total), quantile(vector_wip_total, MAXQ)))
    push!(df_infoview, ("WIP Accepted (avg per station)", mean(vector_wip_accepted), std(vector_wip_accepted), quantile(vector_wip_accepted, MINQ), median(vector_wip_accepted), quantile(vector_wip_accepted, MAXQ)))    
    push!(df_infoview, ("Simulation Time", mean(df_simtime.simtime), std(df_simtime.simtime), quantile(df_simtime.simtime, MINQ), median(df_simtime.simtime), quantile(df_simtime.simtime, MAXQ)))
    push!(df_infoview, ("Machine Saturation (%)", mean(vector_mean_saturation), std(vector_mean_saturation), quantile(vector_mean_saturation, MINQ), median(vector_mean_saturation), quantile(vector_mean_saturation, MAXQ)))
    push!(df_infoview, ("Lot Makespan", mean(vector_mean_makespan), std(vector_mean_makespan), quantile(vector_mean_makespan, MINQ), median(vector_mean_makespan), quantile(vector_mean_makespan, MAXQ)))
    push!(df_infoview, ("Lot Total Queue Time", mean(vector_mean_queuetime), std(vector_mean_queuetime), quantile(vector_mean_queuetime, MINQ), median(vector_mean_queuetime), quantile(vector_mean_queuetime, MAXQ)))

    return (
            infoview = df_infoview,
            wip = merged_wip,
            wipstation = merged_wipstation,
            makespan_box = merged_makespanbox,
            saturation = merged_saturation,
            queuetime_box = merged_queuetimebox,
            queuelen_box = merged_queuelenbox
            )

end


function buildWip(df_queuelen::DataFrame, sim_time::Float64, CROWDLIMIT::Int64)
    df_queuelen.area_total = df_queuelen.queue_length .* df_queuelen.total_duration
    df_queuelen.area_overcrowd = max.(0, df_queuelen.queue_length .- CROWDLIMIT) .* df_queuelen.total_duration
    df_queuelen.area_accepted = df_queuelen.area_total - df_queuelen.area_overcrowd

    df_wipstation = DataFrame(station = unique(df_queuelen.station))
    df_wipstation.wip_total = [sum(df_queuelen[df_queuelen.station .== s, :area_total]) / sim_time for s in df_wipstation.station]
    df_wipstation.wip_accepted = [sum(df_queuelen[df_queuelen.station .== s, :area_accepted]) / sim_time for s in df_wipstation.station]
    df_wipstation.wip_overcrowd = [sum(df_queuelen[df_queuelen.station .== s, :area_overcrowd]) / sim_time for s in df_wipstation.station]

    df_wip = DataFrame()
    div = (nrow(unique(df_queuelen, :station)) * sim_time)
    df_wip.wip_total = [sum(df_queuelen.area_total) / div]
    df_wip.wip_accepted = [sum(df_queuelen.area_accepted) / div]
    df_wip.wip_overcrowd = [sum(df_queuelen.area_overcrowd) / div]

    return df_wip, df_wipstation

end

function buildQueuelen(df_queuelen::DataFrame, sim_time::Float64)
    sort!(df_queuelen, [:station, :timestamp])

    df_queuelen.duration = zeros(nrow(df_queuelen))

    for station_group in groupby(df_queuelen, :station)
        filtering = df_queuelen.station .== first(station_group.station)
        rows = findall(filtering)
        for i in 1:length(rows)-1
            df_queuelen.duration[rows[i]] = df_queuelen.timestamp[rows[i+1]] - df_queuelen.timestamp[rows[i]]
        end
        df_queuelen.duration[rows[end]] = sim_time - df_queuelen.timestamp[rows[end]]
    end

    df_queuelen = combine(groupby(df_queuelen, [:station, :queue_length]), :duration => sum => :total_duration)
    return df_queuelen
end

function buildSaturation(df_saturation::DataFrame, sim_time::Float64)
    df_saturation = combine(groupby(df_saturation, :machine), :processing_time => sum => :total_processing_time)
    sort!(df_saturation, :machine)
 
    df_saturation.processing_percent = 100 .* df_saturation.total_processing_time ./ sim_time

    df_saturation.down_percent = zeros(size(df_saturation, 1))    # placeholder
    df_saturation.repair_percent = zeros(size(df_saturation, 1))  # placeholder
    df_saturation.maint_percent = zeros(size(df_saturation, 1))   # placeholder

    df_saturation.idle_percent = 100 .- df_saturation.processing_percent .- df_saturation.down_percent .- df_saturation.repair_percent .-df_saturation.maint_percent

    return df_saturation
end

end