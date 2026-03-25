module structures

using ..Distributions
using ..ConcurrentSim
using ..StableRNGs
using ..configdata: SimConfig


export Dash,
       QueueLenLog,
       WaitingTicket,
       Station,
       Client,
       AdvancementLog,
       buildstations,
       generateClients,
       logging,
       init_dash

struct QueueLenLog
    timestamp::Float64
    station::String
    queueLength::Int64
end

# =======================================================================tutto il resto

struct WaitingTicket
    client_id::Int64
    ready_event::Event
end

mutable struct Station
    name::String
    capacity::Int64
    busy::Int64
    waiting_queue::Vector{WaitingTicket}
end

mutable struct AdvancementLog
    client_id::Int64
    clientCode::String
    dueDate::Float64
    stations::Vector{String}
    systemArrival::Float64
    systemExit::Float64
    enterQueue::Vector{Float64}
    exitQueue::Vector{Float64}
    startProcess::Vector{Float64}
    finishProcess::Vector{Float64}
end

mutable struct Dash
    queueLenLog::Vector{QueueLenLog}
    clientLogs::Vector{AdvancementLog}
    simEndTime::Float64
end

mutable struct Client
    id::Int64
    code::String
    lotsize::Int64
    release_time::Float64
    due_date::Float64    
    route::Vector{Station}
    expected_processing_time::Vector{Float64}
    processing_time::Vector{Float64}
    current_station::Int64
    log::AdvancementLog
end

# =================================================================== functions =======

function buildstations(stationsnames::Vector{String}, stationscapacities::Vector{Int64})
    stats = Vector{Station}()
    for i in 1:length(stationsnames)
        push!(stats, Station(stationsnames[i], stationscapacities[i], 0, Vector{WaitingTicket}()))
    end
    return stats
end

function AdvancementLog(client_id::Int64, clientCode::String, dueDate::Float64, route::Vector{Station})::AdvancementLog
    stationNames = [station.name for station in route]
    stationCount = length(route)
    return AdvancementLog(
        client_id,
        clientCode,
        dueDate,
        stationNames,
        NaN,
        NaN,
        fill(NaN, stationCount),
        fill(NaN, stationCount),
        fill(NaN, stationCount),
        fill(NaN, stationCount),
    )
end

function Client(id::Int64, code::String, lotsize::Int64, releaseTime::Float64, dueDate::Float64, route::Vector{Station}, expectedProcessingTime::Vector{Float64}, processingTime::Vector{Float64})::Client
    return Client(id, code, lotsize, releaseTime, dueDate, route, expectedProcessingTime, processingTime, 1, AdvancementLog(id, code, dueDate, route))
end

function batchReleaseTime(clientId::Int64, cfg::SimConfig)::Float64
    return Float64(fld(clientId - 1, cfg.releaseBatchSize)) * cfg.releaseBatchSpacing
end

function sampleDueDate(rng::StableRNG, releaseTime::Float64, cfg::SimConfig)::Float64
    return releaseTime + rand(rng, Uniform(cfg.dueDateMinOffset, cfg.dueDateMaxOffset))
end

function sampleProcessingTimes(rng::StableRNG, expectedTimes::Vector{Float64})::Vector{Float64}
    return [
        λ <= 0.0 ? 0.0 : rand(rng, truncated(Normal(λ, 0.1 * λ); lower = 0.0))
        for λ in expectedTimes
    ]
end

function generateClients(rng::StableRNG, cfg::SimConfig, codeNames::Vector{String}, codeDistribution::Categorical, codeRouteStations::Vector{Vector{Station}}, codeSizeValues::Vector{Vector{Int64}}, codeSizeDistributions::Vector{Categorical}, codeProcessingTimes::Vector{Vector{Float64}})
    clients = Vector{Client}()
    for i in 1:cfg.clientNum
        sc = rand(rng, codeDistribution) #sampled code
        ss = rand(rng, codeSizeDistributions[sc]) #sampled dimensions from the code's vector
        lot = codeSizeValues[sc][ss] #size of the lot
        releaseTime = batchReleaseTime(i, cfg)
        expectedTime = codeProcessingTimes[sc] .* lot
        sampledTime = sampleProcessingTimes(rng, expectedTime)
        dueDate = sampleDueDate(rng, releaseTime, cfg)
        push!(clients, Client(i, codeNames[sc], lot, releaseTime, dueDate, codeRouteStations[sc], expectedTime, sampledTime))
    end
    return clients
end

function logging(event::Symbol, env::Environment, dash::Dash, client::Client, place::String, queueLength::Int64 = -1)
    timestamp = now(env)
    currentStation = client.current_station

    if event == :enterqueue
        queueLength >= 0 || error("queueLength richiesto per :enterqueue")
        client.log.enterQueue[currentStation] = timestamp
        push!(dash.queueLenLog, QueueLenLog(timestamp, place, queueLength))
    elseif event == :exitqueue
        queueLength >= 0 || error("queueLength richiesto per :exitqueue")
        client.log.exitQueue[currentStation] = timestamp
        push!(dash.queueLenLog, QueueLenLog(timestamp, place, queueLength))
    elseif event == :startprocess
        client.log.startProcess[currentStation] = timestamp
    elseif event == :finishprocess
        client.log.finishProcess[currentStation] = timestamp
    elseif event == :systemarrival
        client.log.systemArrival = timestamp
    elseif event == :systemexit
        client.log.systemExit = timestamp
        dash.simEndTime = timestamp
        push!(dash.clientLogs, client.log)
    end
end

function init_dash(stations::Vector{Station})
    return Dash(
        [QueueLenLog(0.0, s.name, 0) for s in stations],
        AdvancementLog[],
        0.0,
    )
end

end #quello del modulo
