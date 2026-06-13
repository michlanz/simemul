module selectionrules

using ..StableRNGs
using ..ConcurrentSim
using ..structures

export selectNext,
       adaptiveRule,
       SelectionPolicy,
       SelectionDecision,
       selectionRules

struct SelectionPolicy
    id::Symbol
    label::String
    rule
end

struct SelectionDecision
    queue_position::Int64
    effective_policy::Union{Nothing, Symbol}
end

struct AdaptiveSelectionRule
    queueThreshold::Union{Nothing, Int64}
    slackThreshold::Union{Nothing, Float64}
    adaptivePriorityOrder::Tuple{Symbol, Symbol}
end
      
function selectNext(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG, priorityRule)::SelectionDecision
    @assert !isempty(station.waiting_queue) "selectNext chiamata con waiting_queue vuota"
    decision = priorityRule(env, station, clients, rng)
    decision isa SelectionDecision && return decision
    return SelectionDecision(Int64(decision), nothing)
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

function queueMinSlack(env::Environment, station::Station, clients::Vector{Client})::Float64
    leastSlack = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        slack = client.due_date - now(env) - sum(client.expected_processing_time[client.current_station:end])
        leastSlack = min(leastSlack, slack)
    end

    return leastSlack
end

function selectWithAdaptivePriority(priority::Symbol, env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::SelectionDecision
    priority == :SIRO && return SelectionDecision(siroRule(env, station, clients, rng), :SIRO)
    priority == :FIFO && return SelectionDecision(fifoRule(env, station, clients, rng), :FIFO)
    priority == :LIFO && return SelectionDecision(lifoRule(env, station, clients, rng), :LIFO)
    priority == :SPT && return SelectionDecision(sptRule(env, station, clients, rng), :SPT)
    priority == :LPT && return SelectionDecision(lptRule(env, station, clients, rng), :LPT)
    priority == :EDD && return SelectionDecision(eddRule(env, station, clients, rng), :EDD)
    priority == :MINSLACK && return SelectionDecision(minSlackRule(env, station, clients, rng), :MINSLACK)
    priority == :CRITICALRATIO && return SelectionDecision(criticalRatioRule(env, station, clients, rng), :CRITICALRATIO)
    priority == :FOPNR && return SelectionDecision(fopnrRule(env, station, clients, rng), :FOPNR)
    priority == :MOPNR && return SelectionDecision(mopnrRule(env, station, clients, rng), :MOPNR)
    priority == :LWRK && return SelectionDecision(lwrkRule(env, station, clients, rng), :LWRK)
    priority == :MWRK && return SelectionDecision(mwrkRule(env, station, clients, rng), :MWRK)
    error("Priorita adaptive non valida: $(priority)")
end

function (priorityRule::AdaptiveSelectionRule)(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::SelectionDecision
    queueTriggered = priorityRule.queueThreshold !== nothing && length(station.waiting_queue) >= priorityRule.queueThreshold
    slackTriggered = priorityRule.slackThreshold !== nothing && queueMinSlack(env, station, clients) <= priorityRule.slackThreshold

    if queueTriggered && slackTriggered
        return selectWithAdaptivePriority(priorityRule.adaptivePriorityOrder[1], env, station, clients, rng)
    elseif queueTriggered
        return SelectionDecision(sptRule(env, station, clients, rng), :SPT)
    elseif slackTriggered
        return SelectionDecision(minSlackRule(env, station, clients, rng), :MINSLACK)
    end

    return SelectionDecision(fifoRule(env, station, clients, rng), :FIFO)
end

function adaptiveRule(queueThreshold, slackThreshold, cfg)::AdaptiveSelectionRule
    cleanQueueThreshold = queueThreshold === nothing ? nothing : Int64(queueThreshold)
    cleanSlackThreshold = slackThreshold === nothing ? nothing : Float64(slackThreshold)
    return AdaptiveSelectionRule(cleanQueueThreshold, cleanSlackThreshold, cfg.adaptivePriorityOrder)
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
    SelectionPolicy(:SIRO, "01.SIRO", siroRule),
    SelectionPolicy(:FIFO, "02.FIFO", fifoRule),
    SelectionPolicy(:LIFO, "03.LIFO", lifoRule),
    SelectionPolicy(:SPT, "04.SPT", sptRule),
    SelectionPolicy(:LPT, "05.LPT", lptRule),
    SelectionPolicy(:EDD, "06.EDD", eddRule),
    SelectionPolicy(:MINSLACK, "07.MINSLACK", minSlackRule),
    SelectionPolicy(:CRITICALRATIO, "08.CRITICALRATIO", criticalRatioRule),
    SelectionPolicy(:FOPNR, "09.FOPNR", fopnrRule),
    SelectionPolicy(:MOPNR, "10.MOPNR", mopnrRule),
    SelectionPolicy(:LWRK, "11.LWRK", lwrkRule),
    SelectionPolicy(:MWRK, "12.MWRK", mwrkRule)
]


end #quello del modulo
