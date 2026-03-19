module structures

using ..Distributions
using ..ConcurrentSim
using ..StableRNGs


export Dash,
       SystemLog,
       ProcessingTimeLog,
       QueueLenLog,
       QueueTimeLog,
       UnitsInSystemLog,
       MakespanLog,
       WaitingTicket,
       Station,
       Client,
       AdvancementLog,
       buildstations,
       generateClients,
       logging,
       init_dash

struct SystemLog
    timestamp::Float64
    id_client::Int64
    code::String
    event::Symbol
    place::String
end

struct ProcessingTimeLog
    client_code::String
    machine::String
    processing_time::Float64
end

struct QueueLenLog
    timestamp::Float64
    station::String
    queue_length::Int64
end

struct QueueTimeLog
    client_code::String
    station::String
    waiting_time::Float64
end

struct UnitsInSystemLog
    timestamp::Float64
    units_in_system::Int64
end

struct MakespanLog
    client_code::String
    makespan::Float64
end

struct Dash
    monitor_log::Vector{SystemLog}
    processing_times_log::Vector{ProcessingTimeLog}
    queue_len_log::Vector{QueueLenLog}
    queue_time_log::Vector{QueueTimeLog}
    units_in_system_log::Vector{UnitsInSystemLog}
    makespan_log::Vector{MakespanLog}
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
    code::String
    systemarrival::Float64
    systemexit::Float64
    enterqueue::Vector{Float64}
    exitqueue::Vector{Float64}
    startprocess::Vector{Float64}
    finishprocess::Vector{Float64}
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

function AdvancementLog(code::String, n::Int64)::AdvancementLog
    return AdvancementLog(code, NaN, NaN, [NaN for _ in 1:n], [NaN for _ in 1:n], [NaN for _ in 1:n], [NaN for _ in 1:n])
end

function Client(id::Int64, code::String, lotsize::Int64, duedate::Float64, route::Vector{Station}, expected_processing_time::Vector{Float64}, processing_time::Vector{Float64})::Client
    return Client(id, code, lotsize, 0.0, duedate, route, expected_processing_time, processing_time, 1, AdvancementLog(code, length(route)))
end

function generateClients(rng::StableRNG, clientnum::Int64, codesnames::Vector{String}, codesdistribution::Categorical, codesroutestations::Vector{Vector{Station}}, codessizevalues::Vector{Vector{Int64}}, codessizedistributions::Vector{Categorical}, codesprocessingtimes::Vector{Vector{Float64}})
    clients = Vector{Client}()
    for i in 1:clientnum
        sc = rand(rng, codesdistribution) #sampled code
        ss = rand(rng, codessizedistributions[sc]) #sampled dimensions from the code's vector
        lot = codessizevalues[sc][ss] #size of the lot
        expectedtime = codesprocessingtimes[sc].*lot
        sampledtime = [rand(rng, truncated(Normal(λ, 0.1 * λ); lower=0.0)) for λ in expectedtime]
        duedate = Float64(rand(rng, 200:8:320))
        push!(clients, Client(i, codesnames[sc], lot, duedate, codesroutestations[sc], expectedtime, sampledtime))
    end
    return clients
end

function logging(event::Symbol, env::Environment, dash::Dash, client::Client, place::String, units::Int64)
    if event == :systemarrival
        client.log.systemarrival = now(env)
        push!(dash.monitor_log, SystemLog(now(env), client.id, client.code, event, place))
        push!(dash.units_in_system_log, UnitsInSystemLog(now(env), units))
    elseif event == :enterqueue
        client.log.enterqueue[client.current_station] = now(env)
        push!(dash.monitor_log, SystemLog(now(env), client.id, client.code, event, place))
        push!(dash.queue_len_log, QueueLenLog(now(env), place, dash.queue_len_log[findlast(x -> x.station == place, dash.queue_len_log)].queue_length + 1))   
    elseif event == :exitqueue
        client.log.exitqueue[client.current_station] = now(env)
        push!(dash.queue_time_log, QueueTimeLog(client.code, place, client.log.exitqueue[client.current_station]-client.log.enterqueue[client.current_station]))
        push!(dash.queue_len_log, QueueLenLog(now(env), place, dash.queue_len_log[findlast(x -> x.station == place, dash.queue_len_log)].queue_length - 1))
    elseif event == :startprocess
        client.log.startprocess[client.current_station] = now(env)
        push!(dash.monitor_log, SystemLog(now(env), client.id, client.code, event, place))
    elseif event == :finishprocess
        client.log.finishprocess[client.current_station] = now(env)
        push!(dash.monitor_log, SystemLog(now(env), client.id, client.code, event, place))
        push!(dash.processing_times_log, ProcessingTimeLog(client.code, place, client.log.finishprocess[client.current_station]-client.log.startprocess[client.current_station]))
    elseif event == :systemexit
        client.log.systemexit = now(env)
        push!(dash.monitor_log, SystemLog(now(env), client.id, client.code, event, place))
        push!(dash.units_in_system_log, UnitsInSystemLog(now(env), units))
        push!(dash.makespan_log, MakespanLog(client.code, client.log.systemexit-client.log.systemarrival))
    end
end

function init_dash(stations::Vector{Station})
    return Dash(
        SystemLog[],
        ProcessingTimeLog[], # processing_times_log
        [QueueLenLog(0.0, s.name, 0) for s in stations], # queue_len_log (una entry per stazione a t=0)
        QueueTimeLog[], # queue_time_log
        [UnitsInSystemLog(0.0, 0)], # units_in_system_log (stato iniziale)
        MakespanLog[] #makespan_log
    )
end

end #quello del modulo