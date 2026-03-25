module postprocess

using ..DataFrames
using ..Statistics
using ..DataFrames: sort!
using ..structures: Dash, AdvancementLog

export postprocessDF,
       buildQueuelen,
       buildSaturation

function postprocessDF(dashvector::Vector{Dash}, seeds::Vector{UInt32}, policyName::String, stationsnames::Vector{String}, stationscapacities::Vector{Int64})
    length(dashvector) == length(seeds) || error("dashvector e seeds devono avere la stessa lunghezza")

    bucketSize = 8.0

    queuelen_box = emptyQueuelenBox()
    clientStationLog = emptyClientStationLog()
    punctuality_box = emptyPunctualityBox()
    wipSystemBucketRuns, wipStationBucketRuns = emptyBucketWipFrames()
    saturationRuns = emptySaturationLog()
    anovaRef = emptyAnovaRef()

    for (replicationId, dash) in enumerate(dashvector)
        seed = seeds[replicationId]
        simtime = dash.simEndTime
        dfQueueLog = DataFrame(dash.queueLenLog)
        dfQueueIntervals = buildQueueIntervals(dfQueueLog, simtime)

        dfQueuelen = buildQueuelen(dfQueueIntervals)
        dfWipSystemBucket, dfWipStationBucket = buildQueueBucketWip(dfQueueIntervals, simtime, bucketSize)
        dfClientStation = buildClientStationLog(dash.clientLogs)
        dfPunctuality = buildPunctualityBox(dash.clientLogs)
        dfSaturation = buildSaturation(dfClientStation, simtime, stationsnames, stationscapacities)

        dfQueuelen.percent = simtime > 0.0 ? 100 .* dfQueuelen.total_duration ./ simtime : zeros(nrow(dfQueuelen))
        sort!(dfQueuelen, [:station, :queue_length])

        append!(queuelen_box, dfQueuelen)
        append!(clientStationLog, dfClientStation)
        append!(punctuality_box, dfPunctuality)
        append!(wipSystemBucketRuns, dfWipSystemBucket)
        append!(wipStationBucketRuns, dfWipStationBucket)
        append!(saturationRuns, dfSaturation)
        push!(anovaRef, buildAnovaRow(
            policyName,
            replicationId,
            seed,
            simtime,
            dfQueueIntervals,
            dfClientStation,
            dfPunctuality,
            dfSaturation,
            length(stationsnames),
        ))
    end

    queuetime_box = select(clientStationLog, :client_id, :client_code, :station, :waiting_time)
    sort!(queuetime_box, [:station, :client_code, :client_id])

    saturation = combine(
        groupby(saturationRuns, :machine),
        [:total_processing_time, :capacity, :processing_percent, :idle_percent] .=> mean;
        renamecols = false,
    )
    sort!(saturation, :machine)

    return (
        anovaRef = anovaRef,
        wip_system_buckets = aggregateBucketMeans(
            wipSystemBucketRuns,
            [:bucket_id, :bucket_start, :bucket_end, :bucket_label],
            [:bucket_id],
        ),
        wip_station_buckets = aggregateBucketMeans(
            wipStationBucketRuns,
            [:station, :bucket_id, :bucket_start, :bucket_end, :bucket_label],
            [:station, :bucket_id],
        ),
        punctuality_box = punctuality_box,
        makespan_composition = buildMakespanComposition(clientStationLog, punctuality_box, stationsnames),
        ontime_share = buildOntimeShare(punctuality_box),
        punctuality_summary = buildPunctualitySummary(punctuality_box),
        saturation = saturation,
        queuetime_box = queuetime_box,
        queuelen_box = queuelen_box,
    )
end

function emptyQueuelenBox()
    return DataFrame(
        station = String[],
        queue_length = Int64[],
        total_duration = Float64[],
        percent = Float64[],
    )
end

function emptyClientStationLog()
    return DataFrame(
        client_id = Int64[],
        client_code = String[],
        station = String[],
        waiting_time = Float64[],
        processing_time = Float64[],
    )
end

function emptyPunctualityBox()
    return DataFrame(
        client_id = Int64[],
        client_code = String[],
        systemarrival = Float64[],
        systemexit = Float64[],
        due_date = Float64[],
        makespan = Float64[],
        lateness = Float64[],
        tardiness = Float64[],
    )
end

function emptySaturationLog()
    return DataFrame(
        machine = String[],
        total_processing_time = Float64[],
        capacity = Float64[],
        processing_percent = Float64[],
        idle_percent = Float64[],
    )
end

function emptyAnovaRef()
    return DataFrame(
        policy = String[],
        replication_id = Int64[],
        seed = Int64[],
        simtime = Float64[],
        mean_makespan = Float64[],
        mean_lateness = Float64[],
        mean_tardiness = Float64[],
        mean_queuetime = Float64[],
        mean_saturation = Float64[],
        ontime_share = Float64[],
        throughput = Float64[],
        mean_wip_queue = Float64[],
        mean_processing_ratio = Float64[],
        p10_makespan = Float64[],
        p90_makespan = Float64[],
        p10_lateness = Float64[],
        p90_lateness = Float64[],
        p10_tardiness = Float64[],
        p90_tardiness = Float64[],
        p10_queuetime = Float64[],
        p90_queuetime = Float64[],
        mean_queue_length = Float64[],
        saturation_std = Float64[],
        bottleneck_time_share = Float64[],
    )
end

function buildAnovaRow(policyName::String, replicationId::Int64, seed::UInt32, simtime::Float64, dfQueueIntervals::DataFrame, dfClientStation::DataFrame, dfPunctuality::DataFrame, dfSaturation::DataFrame, stationCount::Int64)
    totalQueueArea = isempty(dfQueueIntervals) ? 0.0 : sum(dfQueueIntervals.queue_length .* dfQueueIntervals.duration)
    meanQueueWip = simtime > 0.0 ? totalQueueArea / simtime : 0.0
    meanQueueLength = simtime > 0.0 && stationCount > 0 ? totalQueueArea / (simtime * stationCount) : 0.0
    throughput = simtime > 0.0 ? nrow(dfPunctuality) / simtime : 0.0

    processingByClient = isempty(dfClientStation) ? DataFrame(client_id = Int64[], total_processing_time = Float64[]) :
        combine(groupby(dfClientStation, :client_id), :processing_time => sum => :total_processing_time)
    dfRatios = leftjoin(select(dfPunctuality, :client_id, :makespan), processingByClient, on = :client_id)
    dfRatios.total_processing_time = coalesce.(dfRatios.total_processing_time, 0.0)
    validMakespan = dfRatios.makespan .> 0.0
    meanProcessingRatio = any(validMakespan) ? mean(dfRatios.total_processing_time[validMakespan] ./ dfRatios.makespan[validMakespan]) : 0.0

    stationWaiting = isempty(dfClientStation) ? DataFrame(total_waiting_time = Float64[]) :
        combine(groupby(dfClientStation, :station), :waiting_time => sum => :total_waiting_time)
    totalWaitingTime = isempty(stationWaiting) ? 0.0 : sum(stationWaiting.total_waiting_time)
    bottleneckTimeShare = totalWaitingTime > 0.0 ? 100.0 * maximum(stationWaiting.total_waiting_time) / totalWaitingTime : 0.0

    return (
        policy = policyName,
        replication_id = replicationId,
        seed = Int64(seed),
        simtime = simtime,
        mean_makespan = safeMean(dfPunctuality.makespan),
        mean_lateness = safeMean(dfPunctuality.lateness),
        mean_tardiness = safeMean(dfPunctuality.tardiness),
        mean_queuetime = safeMean(dfClientStation.waiting_time),
        mean_saturation = safeMean(dfSaturation.processing_percent),
        ontime_share = isempty(dfPunctuality) ? 0.0 : 100.0 * mean(dfPunctuality.lateness .<= 0.0),
        throughput = throughput,
        mean_wip_queue = meanQueueWip,
        mean_processing_ratio = meanProcessingRatio,
        p10_makespan = quantileOrZero(dfPunctuality.makespan, 0.10),
        p90_makespan = quantileOrZero(dfPunctuality.makespan, 0.90),
        p10_lateness = quantileOrZero(dfPunctuality.lateness, 0.10),
        p90_lateness = quantileOrZero(dfPunctuality.lateness, 0.90),
        p10_tardiness = quantileOrZero(dfPunctuality.tardiness, 0.10),
        p90_tardiness = quantileOrZero(dfPunctuality.tardiness, 0.90),
        p10_queuetime = quantileOrZero(dfClientStation.waiting_time, 0.10),
        p90_queuetime = quantileOrZero(dfClientStation.waiting_time, 0.90),
        mean_queue_length = meanQueueLength,
        saturation_std = nrow(dfSaturation) > 1 ? std(dfSaturation.processing_percent) : 0.0,
        bottleneck_time_share = bottleneckTimeShare,
    )
end

function safeMean(values)
    isempty(values) && return 0.0
    return mean(values)
end

function quantileOrZero(values, probability::Float64)
    isempty(values) && return 0.0
    return quantile(values, probability)
end

function buildPunctualityBox(clientLogs::Vector{AdvancementLog})
    rows = NamedTuple[]

    for log in clientLogs
        makespan = log.systemExit - log.systemArrival
        lateness = log.systemExit - log.dueDate

        push!(rows, (
            client_id = log.client_id,
            client_code = log.clientCode,
            systemarrival = log.systemArrival,
            systemexit = log.systemExit,
            due_date = log.dueDate,
            makespan = makespan,
            lateness = lateness,
            tardiness = max(0.0, lateness),
        ))
    end

    isempty(rows) && return emptyPunctualityBox()

    df = DataFrame(rows)
    sort!(df, [:client_code, :client_id])
    return df
end

function buildClientStationLog(clientLogs::Vector{AdvancementLog})
    rows = NamedTuple[]

    for log in clientLogs
        for idx in eachindex(log.stations)
            push!(rows, (
                client_id = log.client_id,
                client_code = log.clientCode,
                station = log.stations[idx],
                waiting_time = log.exitQueue[idx] - log.enterQueue[idx],
                processing_time = log.finishProcess[idx] - log.startProcess[idx],
            ))
        end
    end

    isempty(rows) && return emptyClientStationLog()

    df = DataFrame(rows)
    sort!(df, [:station, :client_code, :client_id])
    return df
end

function aggregateBucketMeans(df_bucket::DataFrame, group_cols, sort_cols)
    df_bucket.weighted_area = df_bucket.mean_queue_wip .* df_bucket.observed_duration
    df_agg = combine(
        groupby(df_bucket, group_cols),
        :weighted_area => sum => :weighted_area,
        :observed_duration => sum => :observed_duration,
    )
    df_agg.mean_queue_wip = df_agg.weighted_area ./ df_agg.observed_duration
    select!(df_agg, Not(:weighted_area))
    sort!(df_agg, sort_cols)
    return df_agg
end

function buildQueuelen(df_queue_intervals::DataFrame)
    return combine(groupby(df_queue_intervals, [:station, :queue_length]), :duration => sum => :total_duration)
end

function buildSaturation(df_client_station::DataFrame, sim_time::Float64, stationsnames::Vector{String}, stationscapacities::Vector{Int64})
    df_saturation = DataFrame(
        machine = stationsnames,
        capacity = Float64.(stationscapacities),
    )

    if !isempty(df_client_station)
        df_processing = combine(groupby(df_client_station, :station), :processing_time => sum => :total_processing_time)
        rename!(df_processing, :station => :machine)
        df_saturation = leftjoin(df_saturation, df_processing, on = :machine)
    end

    if !hasproperty(df_saturation, :total_processing_time)
        df_saturation.total_processing_time = zeros(nrow(df_saturation))
    else
        df_saturation.total_processing_time = coalesce.(df_saturation.total_processing_time, 0.0)
    end

    if sim_time > 0.0
        df_saturation.processing_percent = 100 .* df_saturation.total_processing_time ./ (sim_time .* df_saturation.capacity)
    else
        df_saturation.processing_percent = zeros(nrow(df_saturation))
    end
    df_saturation.idle_percent = 100 .- df_saturation.processing_percent

    sort!(df_saturation, :machine)
    return df_saturation
end

function buildQueueBucketWip(df_queue_intervals::DataFrame, sim_time::Float64, bucket_size::Float64)
    sim_time <= 0.0 && return emptyBucketWipFrames()

    bucket_count = ceil(Int, sim_time / bucket_size)
    bucket_starts = [(i - 1) * bucket_size for i in 1:bucket_count]
    bucket_ends = [i * bucket_size for i in 1:bucket_count]
    bucket_labels = [formatBucketLabel(bucket_starts[i], bucket_ends[i]) for i in 1:bucket_count]
    bucket_durations = [min(bucket_ends[i], sim_time) - bucket_starts[i] for i in 1:bucket_count]
    station_bucket_rows = NamedTuple[]

    for station_group in groupby(df_queue_intervals, :station)
        areas = zeros(bucket_count)

        for row in eachrow(station_group)
            cursor = row.start_time
            while cursor < row.end_time
                bucket_id = floor(Int, cursor / bucket_size) + 1
                overlap_end = min(row.end_time, bucket_ends[bucket_id])
                areas[bucket_id] += row.queue_length * (overlap_end - cursor)
                cursor = overlap_end
            end
        end

        for bucket_id in 1:bucket_count
            push!(station_bucket_rows, (
                station = first(station_group.station),
                bucket_id = bucket_id,
                bucket_start = bucket_starts[bucket_id],
                bucket_end = bucket_ends[bucket_id],
                bucket_label = bucket_labels[bucket_id],
                observed_duration = bucket_durations[bucket_id],
                mean_queue_wip = areas[bucket_id] / bucket_durations[bucket_id],
            ))
        end
    end

    df_station = DataFrame(station_bucket_rows)
    df_system = combine(
        groupby(df_station, [:bucket_id, :bucket_start, :bucket_end, :bucket_label, :observed_duration]),
        :mean_queue_wip => sum => :mean_queue_wip,
    )

    sort!(df_station, [:station, :bucket_id])
    sort!(df_system, :bucket_id)
    return df_system, df_station
end

function buildQueueIntervals(df_queue_log::DataFrame, sim_time::Float64)
    sort!(df_queue_log, [:station, :timestamp])

    interval_rows = NamedTuple[]
    for station_group in groupby(df_queue_log, :station)
        station = first(station_group.station)
        timestamps = station_group.timestamp
        queueLengths = station_group.queueLength

        for idx in eachindex(timestamps)
            start_time = timestamps[idx]
            end_time = idx < length(timestamps) ? timestamps[idx + 1] : sim_time
            push!(interval_rows, (
                station = station,
                start_time = start_time,
                end_time = end_time,
                duration = end_time - start_time,
                queue_length = queueLengths[idx],
            ))
        end
    end

    return DataFrame(interval_rows)
end

function emptyBucketWipFrames()
    empty_system = DataFrame(
        bucket_id = Int64[],
        bucket_start = Float64[],
        bucket_end = Float64[],
        bucket_label = String[],
        observed_duration = Float64[],
        mean_queue_wip = Float64[],
    )
    empty_station = DataFrame(
        station = String[],
        bucket_id = Int64[],
        bucket_start = Float64[],
        bucket_end = Float64[],
        bucket_label = String[],
        observed_duration = Float64[],
        mean_queue_wip = Float64[],
    )
    return empty_system, empty_station
end

function buildMakespanComposition(df_client_station::DataFrame, df_punctuality::DataFrame, stationsnames::Vector{String})
    job_count = combine(groupby(df_punctuality, :client_code), nrow => :job_count)
    wait_components = buildWaitComponents(df_client_station, job_count)
    processing_components = buildProcessingComponents(df_client_station, job_count)

    df_components = vcat(wait_components, processing_components)
    sortMakespanComponents!(df_components, stationsnames)

    return df_components
end

function buildWaitComponents(df_client_station::DataFrame, job_count::DataFrame)
    df_wait = combine(groupby(df_client_station, [:client_code, :station]), :waiting_time => sum => :total_time)
    df_wait = leftjoin(df_wait, job_count, on = :client_code)
    df_wait.component = "WAIT|" .* df_wait.station
    df_wait.mean_time = df_wait.total_time ./ df_wait.job_count
    return select(df_wait, :client_code, :component, :mean_time)
end

function buildProcessingComponents(df_client_station::DataFrame, job_count::DataFrame)
    df_processing = combine(groupby(df_client_station, :client_code), :processing_time => sum => :total_time)
    df_processing = leftjoin(df_processing, job_count, on = :client_code)
    df_processing.component = fill("PROCESSING", nrow(df_processing))
    df_processing.mean_time = df_processing.total_time ./ df_processing.job_count
    return select(df_processing, :client_code, :component, :mean_time)
end

function sortMakespanComponents!(df_components::DataFrame, stationsnames::Vector{String})
    ordered_components = vcat(["WAIT|$(station)" for station in stationsnames], ["PROCESSING"])
    component_order = Dict(component => idx for (idx, component) in enumerate(ordered_components))
    df_components.component_order = [get(component_order, component, typemax(Int)) for component in df_components.component]
    sort!(df_components, [:client_code, :component_order])
    select!(df_components, Not(:component_order))
    return df_components
end

function buildOntimeShare(df_punctuality::DataFrame)
    df = combine(groupby(df_punctuality, :client_code), :lateness => (x -> 100.0 * mean(x .<= 0.0)) => :ontime_percent)
    df.tardy_percent = 100.0 .- df.ontime_percent
    sort!(df, :client_code)
    return df
end

function buildPunctualitySummary(df_punctuality::DataFrame)
    df = combine(
        groupby(df_punctuality, :client_code),
        :lateness => mean => :mean_lateness,
        :tardiness => mean => :mean_tardiness,
        :makespan => mean => :mean_makespan,
    )
    sort!(df, :client_code)
    return df
end

function formatBucketLabel(bucket_start::Float64, bucket_end::Float64)
    return "$(Int(round(bucket_start)))-$(Int(round(bucket_end)))h"
end

end
