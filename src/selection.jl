module selectionrules

using ..StableRNGs
using ..ConcurrentSim
using ..structures

export selectNext,
       adaptiveRule,
       adaptivePolicyLabel,
       buildAdaptiveSelectionPolicy,
       buildCombinedAdaptiveSelectionPolicy,
       buildBestSelectionRules,
       combinedAdaptivePolicyLabel,
       SelectionPolicy,
       SelectionDecision,
       selectionRules,
       policyRuleById

struct SelectionPolicy
    id::Symbol
    label::String
    rule
end

struct SelectionDecision
    queue_position::Int64
    effective_policy::Union{Nothing, Symbol}
end

struct AdaptiveTrigger
    policy::Symbol
    threshold::Float64
end

struct AdaptiveSelectionRule
    basePolicy::Symbol
    triggers::Vector{AdaptiveTrigger}
    priorityOrder::Vector{Symbol}
end

const BASELINE_POLICY_IDS = (:FIFO, :LIFO, :SIRO)
const ADAPTIVE_POLICY_IDS = (:SPT, :EDD, :MINSLACK, :CRITICALRATIO)
      
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

function queueMinDueDateRemaining(env::Environment, station::Station, clients::Vector{Client})::Float64
    leastRemaining = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        leastRemaining = min(leastRemaining, client.due_date - now(env))
    end

    return leastRemaining
end

function queueMinCriticalRatio(env::Environment, station::Station, clients::Vector{Client})::Float64
    lowestRatio = Inf

    for pos in eachindex(station.waiting_queue)
        client = clients[station.waiting_queue[pos].client_id]
        remainingWork = sum(client.expected_processing_time[client.current_station:end])
        ratio = remainingWork <= 0.0 ? Inf : (client.due_date - now(env)) / remainingWork
        lowestRatio = min(lowestRatio, ratio)
    end

    return lowestRatio
end

function adaptiveTriggerFires(trigger::AdaptiveTrigger, env::Environment, station::Station, clients::Vector{Client})::Bool
    trigger.policy == :SPT && return length(station.waiting_queue) >= Int(round(trigger.threshold))
    trigger.policy == :EDD && return queueMinDueDateRemaining(env, station, clients) <= trigger.threshold
    trigger.policy == :MINSLACK && return queueMinSlack(env, station, clients) <= trigger.threshold
    trigger.policy == :CRITICALRATIO && return queueMinCriticalRatio(env, station, clients) <= trigger.threshold
    error("Policy adaptive non supportata: $(trigger.policy)")
end

function (priorityRule::AdaptiveSelectionRule)(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG)::SelectionDecision
    triggered = Set{Symbol}()

    for trigger in priorityRule.triggers
        adaptiveTriggerFires(trigger, env, station, clients) && push!(triggered, trigger.policy)
    end

    for policy in priorityRule.priorityOrder
        policy in triggered && return selectWithAdaptivePriority(policy, env, station, clients, rng)
    end

    return selectWithAdaptivePriority(priorityRule.basePolicy, env, station, clients, rng)
end

function adaptiveRule(queueThreshold, slackThreshold, cfg)::AdaptiveSelectionRule
    triggers = AdaptiveTrigger[]
    queueThreshold !== nothing && push!(triggers, AdaptiveTrigger(:SPT, Float64(queueThreshold)))
    slackThreshold !== nothing && push!(triggers, AdaptiveTrigger(:MINSLACK, Float64(slackThreshold)))
    return AdaptiveSelectionRule(:FIFO, triggers, collect(cfg.adaptivePriorityOrder))
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

function policyRuleById(policy::Symbol)
    policy == :SIRO && return siroRule
    policy == :FIFO && return fifoRule
    policy == :LIFO && return lifoRule
    policy == :SPT && return sptRule
    policy == :LPT && return lptRule
    policy == :EDD && return eddRule
    policy == :MINSLACK && return minSlackRule
    policy == :CRITICALRATIO && return criticalRatioRule
    policy == :FOPNR && return fopnrRule
    policy == :MOPNR && return mopnrRule
    policy == :LWRK && return lwrkRule
    policy == :MWRK && return mwrkRule
    error("Policy non valida: $(policy)")
end

function thresholdValueLabel(value)::String
    value isa Integer && return string(value)
    clean = replace(string(round(Float64(value); digits = 10)), "-0.0" => "0.0")
    occursin(".", clean) || return clean * ".0"
    return clean
end

function adaptiveTriggerLabel(policy::Symbol, threshold)::String
    policy == :SPT && return "spt_queue_" * lpad(string(Int(round(threshold))), 3, "0")
    policy == :MINSLACK && return "minslack_slack_$(thresholdValueLabel(threshold))"
    policy == :EDD && return "edd_due_$(thresholdValueLabel(threshold))"
    policy == :CRITICALRATIO && return "criticalratio_ratio_$(thresholdValueLabel(threshold))"
    error("Policy adaptive non supportata per label: $(policy)")
end

function parseAdaptiveTriggerLabel(label::AbstractString)::AdaptiveTrigger
    label = String(label)
    sptMatch = match(r"^spt_queue_(\d+)$", label)
    sptMatch !== nothing && return AdaptiveTrigger(:SPT, parse(Float64, sptMatch.captures[1]))

    queueMatch = match(r"^queue_(\d+)$", label)
    queueMatch !== nothing && return AdaptiveTrigger(:SPT, parse(Float64, queueMatch.captures[1]))

    minSlackMatch = match(r"^minslack_slack_([0-9]+(?:\.[0-9]+)?)$", label)
    minSlackMatch !== nothing && return AdaptiveTrigger(:MINSLACK, parse(Float64, minSlackMatch.captures[1]))

    slackMatch = match(r"^slack_([0-9]+(?:\.[0-9]+)?)$", label)
    slackMatch !== nothing && return AdaptiveTrigger(:MINSLACK, parse(Float64, slackMatch.captures[1]))

    eddDueMatch = match(r"^edd_due_([0-9]+(?:\.[0-9]+)?)$", label)
    eddDueMatch !== nothing && return AdaptiveTrigger(:EDD, parse(Float64, eddDueMatch.captures[1]))

    eddMatch = match(r"^edd_([0-9]+(?:\.[0-9]+)?)$", label)
    eddMatch !== nothing && return AdaptiveTrigger(:EDD, parse(Float64, eddMatch.captures[1]))

    criticalRatioMatch = match(r"^criticalratio_ratio_([0-9]+(?:\.[0-9]+)?)$", label)
    criticalRatioMatch !== nothing && return AdaptiveTrigger(:CRITICALRATIO, parse(Float64, criticalRatioMatch.captures[1]))

    crMatch = match(r"^criticalratio_([0-9]+(?:\.[0-9]+)?)$", label)
    crMatch !== nothing && return AdaptiveTrigger(:CRITICALRATIO, parse(Float64, crMatch.captures[1]))

    error("Label trigger adaptive non valida: $(label)")
end

function selectionPolicyId(label::AbstractString)::Symbol
    label = String(label)
    clean = replace(uppercase(label), r"[^A-Z0-9]+" => "_")
    clean = strip(clean, '_')
    isempty(clean) && error("Label policy vuota")
    return Symbol(clean)
end

function adaptivePolicyLabel(basePolicy::Symbol, adaptivePolicy::Symbol, threshold)::String
    triggerLabel = adaptiveTriggerLabel(adaptivePolicy, threshold)
    basePolicy == :FIFO && return triggerLabel
    return "adaptive_$(lowercase(String(basePolicy)))__$(triggerLabel)"
end

function combinedAdaptivePolicyLabel(basePolicy::Symbol, firstPolicy::Symbol, firstThreshold, secondPolicy::Symbol, secondThreshold)::String
    firstLabel = adaptiveTriggerLabel(firstPolicy, firstThreshold)
    secondLabel = adaptiveTriggerLabel(secondPolicy, secondThreshold)

    if basePolicy == :FIFO && Set([firstPolicy, secondPolicy]) == Set([:SPT, :MINSLACK])
        prefix = firstPolicy == :SPT ? "combined_queue_first" : "combined_slack_first"
        queueLabel = firstPolicy == :SPT ? firstLabel : secondLabel
        slackLabel = firstPolicy == :MINSLACK ? firstLabel : secondLabel
        return "$(prefix)__$(queueLabel)__$(slackLabel)"
    end

    return "combined_$(lowercase(String(basePolicy)))__$(firstLabel)_first__$(secondLabel)"
end

function buildAdaptiveSelectionPolicy(label::String, basePolicy::Symbol, triggers::Vector{AdaptiveTrigger}, priorityOrder::Vector{Symbol})::SelectionPolicy
    basePolicy in BASELINE_POLICY_IDS || error("La baseline adaptive deve essere una tra $(BASELINE_POLICY_IDS), trovata $(basePolicy)")
    !isempty(triggers) || error("Serve almeno una policy adaptive per $(label)")

    for trigger in triggers
        trigger.policy in ADAPTIVE_POLICY_IDS || error("Policy adaptive non valida in $(label): $(trigger.policy)")
    end

    triggerPolicies = Set(trigger.policy for trigger in triggers)
    Set(priorityOrder) == triggerPolicies || error("priorityOrder non coerente per $(label): $(priorityOrder) vs $(collect(triggerPolicies))")

    return SelectionPolicy(
        selectionPolicyId(label),
        label,
        AdaptiveSelectionRule(basePolicy, triggers, priorityOrder),
    )
end

function buildAdaptiveSelectionPolicy(basePolicy::Symbol, adaptivePolicy::Symbol, threshold)::SelectionPolicy
    label = adaptivePolicyLabel(basePolicy, adaptivePolicy, threshold)
    return buildAdaptiveSelectionPolicy(label, basePolicy, [AdaptiveTrigger(adaptivePolicy, Float64(threshold))], [adaptivePolicy])
end

function buildCombinedAdaptiveSelectionPolicy(basePolicy::Symbol, firstPolicy::Symbol, firstThreshold, secondPolicy::Symbol, secondThreshold)::SelectionPolicy
    label = combinedAdaptivePolicyLabel(basePolicy, firstPolicy, firstThreshold, secondPolicy, secondThreshold)
    triggers = [
        AdaptiveTrigger(firstPolicy, Float64(firstThreshold)),
        AdaptiveTrigger(secondPolicy, Float64(secondThreshold)),
    ]
    return buildAdaptiveSelectionPolicy(label, basePolicy, triggers, [firstPolicy, secondPolicy])
end

function staticSelectionPolicyByLabel(label::AbstractString)::Union{Nothing, SelectionPolicy}
    label = String(label)
    for policy in selectionRules
        policy.label == label && return policy
        String(policy.id) == label && return policy
    end

    return nothing
end

function parseBestPolicyLabel(label::AbstractString, cfg)::SelectionPolicy
    label = String(label)
    staticPolicy = staticSelectionPolicyByLabel(label)
    staticPolicy !== nothing && return staticPolicy

    oldCombinedMatch = match(r"^combined_(queue|slack)_first__(queue_\d+)__(slack_[0-9]+(?:\.[0-9]+)?)$", label)
    if oldCombinedMatch !== nothing
        queueTrigger = parseAdaptiveTriggerLabel(oldCombinedMatch.captures[2])
        slackTrigger = parseAdaptiveTriggerLabel(oldCombinedMatch.captures[3])
        priorityOrder = oldCombinedMatch.captures[1] == "queue" ?
            [queueTrigger.policy, slackTrigger.policy] :
            [slackTrigger.policy, queueTrigger.policy]
        return buildAdaptiveSelectionPolicy(label, :FIFO, [queueTrigger, slackTrigger], priorityOrder)
    end

    genericCombinedMatch = match(r"^combined_([a-z]+)__(.+)_first__(.+)$", label)
    if genericCombinedMatch !== nothing
        basePolicy = Symbol(uppercase(genericCombinedMatch.captures[1]))
        triggerA = parseAdaptiveTriggerLabel(genericCombinedMatch.captures[2])
        triggerB = parseAdaptiveTriggerLabel(genericCombinedMatch.captures[3])
        priorityOrder = [triggerA.policy, triggerB.policy]
        return buildAdaptiveSelectionPolicy(label, basePolicy, [triggerA, triggerB], priorityOrder)
    end

    genericSingleMatch = match(r"^adaptive_([a-z]+)__(.+)$", label)
    if genericSingleMatch !== nothing
        basePolicy = Symbol(uppercase(genericSingleMatch.captures[1]))
        trigger = parseAdaptiveTriggerLabel(genericSingleMatch.captures[2])
        return buildAdaptiveSelectionPolicy(label, basePolicy, [trigger], [trigger.policy])
    end

    try
        trigger = parseAdaptiveTriggerLabel(label)
        return buildAdaptiveSelectionPolicy(label, :FIFO, [trigger], [trigger.policy])
    catch err
        error("Label bestPolicyLabels non valida: $(label). Errore: $(err)")
    end
end

function buildBestSelectionRules(labels, cfg)::Vector{SelectionPolicy}
    policies = SelectionPolicy[]
    for label in labels
        push!(policies, parseBestPolicyLabel(String(label), cfg))
    end
    return policies
end


end #quello del modulo
