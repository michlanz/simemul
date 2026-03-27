module selectionrules

using ..StableRNGs
using ..ConcurrentSim
using ..structures

export selectNext,
       selectionRules
      
function selectNext(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG, priorityRule)::Int
    @assert !isempty(station.waiting_queue) "selectNext chiamata con waiting_queue vuota"
    selectedQueuePos = priorityRule(env, station, clients, rng)
    return selectedQueuePos
end

function fifoRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    return firstindex(station.waiting_queue)
end

function lifoRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    return lastindex(station.waiting_queue)
end

function siroRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    return rand(rng, eachindex(station.waiting_queue))
end

function sptRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    shortestTime = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]

        if client.expected_processing_time[client.current_station] < shortestTime
            selectedNext = pos
            shortestTime = client.expected_processing_time[client.current_station]
        end
    end
    return selectedNext
end

function lptRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    shortestTime = 0

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]

        if client.expected_processing_time[client.current_station] > shortestTime
            selectedNext = pos
            shortestTime = client.expected_processing_time[client.current_station]
        end
    end
    return selectedNext
end

function eddRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    earliestDueDate = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]

        if client.due_date < earliestDueDate
            selectedNext = pos
            earliestDueDate = client.due_date
        end
    end
    return selectedNext
end

function minSlackRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    leastSlack = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        slack = client.due_date - now(env) - sum(client.expected_processing_time[client.current_station:end])

        if slack < leastSlack
            selectedNext = pos
            leastSlack = slack
        end
    end
    return selectedNext
end

#(tempo residuo alla due date) / (lavoro residuo): piu e basso, piu il job e critico.
function criticalRatioRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    lowestRatio = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        ratio = (client.due_date - now(env)) / sum(client.expected_processing_time[client.current_station:end])

        if ratio < lowestRatio
            selectedNext = pos
            lowestRatio = ratio
        end
    end
    return selectedNext
end

# Fewest Operations Remaining: priorita al job con meno operazioni da fare.
function fopnrRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    fewestOps = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        remaining_ops = length(client.route) - client.current_station + 1

        if remaining_ops < fewestOps
            selectedNext = pos
            fewestOps = remaining_ops
        end
    end
    return selectedNext
end

# Most Operations Remaining: priorita al job con piu operazioni da fare.
function mopnrRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    mostOps = 0

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        remaining_ops = length(client.route) - client.current_station + 1

        if remaining_ops > mostOps
            selectedNext = pos
            mostOps = remaining_ops
        end
    end
    return selectedNext
end

# Least Work Remaining: priorita al job con meno tempo di lavoro residuo.
function lwrkRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    leastWork = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        remaining_work = sum(client.processing_time[client.current_station:end])

        if remaining_work < leastWork
            selectedNext = pos
            leastWork = remaining_work
        end
    end
    return selectedNext
end

# Most Work Remaining: priorita al job con piu tempo di lavoro residuo.
function mwrkRule(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::Int
    selectedNext = 0
    mostWork = 0

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        remaining_work = sum(client.processing_time[client.current_station:end])

        if remaining_work > mostWork
            selectedNext = pos
            mostWork = remaining_work
        end
    end
    return selectedNext
end



selectionRules = [
    (name = "01.SIRO",  rule = siroRule),    
    (name = "02.FIFO", rule = fifoRule),
    (name = "03.LIFO", rule = lifoRule),
    (name = "04.SPT",  rule = sptRule),
    (name = "05.LPT",  rule = lptRule),
    (name = "06.EDD",  rule = eddRule),
    (name = "07.MINSLACK", rule = minSlackRule),
    (name = "08.CRITICALRATIO", rule = criticalRatioRule),
    (name = "09.FOPNR", rule = fopnrRule),
    (name = "10.MOPNR", rule = mopnrRule),
    (name = "11.LWRK", rule = lwrkRule),
    (name = "12.MWRK", rule = mwrkRule)
]


end #quello del modulo
