module coresimulation

using ..StableRNGs
using ..ResumableFunctions
using ..CSV
using ..ConcurrentSim
using ..DataFrames
using ..Distributions

using Main.configdata: SimConfig
using ..inputdata: ImportData
using ..structures
using ..selectionrules
using ..postprocess

export runSaveSim, runManySim, saveResults

# ===== SIMULATION FUNCTIONS =====

function timingSeconds(seconds::Float64)::Float64
    return round(seconds; digits = 3)
end

function batchDisplayName(policyName::String)::String
    combinedMatch = match(r"^combined_(queue|slack)_first__queue_(\d+)__slack_([0-9]+(?:\.[0-9]+)?)$", policyName)
    if combinedMatch !== nothing
        priority = combinedMatch.captures[1]
        queueThreshold = combinedMatch.captures[2]
        slackThreshold = combinedMatch.captures[3]
        return "adaptive $(priority) first queue $(queueThreshold) slack $(slackThreshold)"
    end

    queueMatch = match(r"^queue_(\d+)$", policyName)
    queueMatch !== nothing && return "adaptive spt queue $(queueMatch.captures[1])"

    slackMatch = match(r"^slack_([0-9]+(?:\.[0-9]+)?)$", policyName)
    slackMatch !== nothing && return "adaptive slack $(slackMatch.captures[1])"

    policyMatch = match(r"^\d+\.(.+)$", policyName)
    policyMatch !== nothing && return lowercase(policyMatch.captures[1])

    return lowercase(replace(replace(policyName, "__" => " "), "_" => " "))
end

function runSaveSim(cfg::SimConfig, importData::ImportData, seeds::Vector{UInt32}, policyName::String, priorityRule, outdir::String)
    println("##### batch: $(batchDisplayName(policyName)) #####")

    simTime = @elapsed dashvector = runManySim(cfg, importData, seeds, priorityRule)
    saveTime = @elapsed saveResults(dashvector, seeds, policyName, outdir, importData.stationNames, importData.stationCapacities)
    
    # Save timing to CSV in the same folder
    timingDF = DataFrame(
        policy = policyName,
        simCount = length(seeds),
        timeSimulation = timingSeconds(simTime),
        timeSaving = timingSeconds(saveTime),
        timeTotal = timingSeconds(simTime + saveTime)
    )
    CSV.write(joinpath(outdir, "time_simulation.csv"), timingDF)
    
    return (simTime = simTime, saveTime = saveTime, totalTime = simTime + saveTime, simCount = length(seeds))
end


function saveResults(dashvector::Vector{Dash}, seeds::Vector{UInt32}, policyName::String, outdir::String, stationsnames::Vector{String}, stationscapacities::Vector{Int64})
    println("  ##### inizio dei salvataggi ################")
    mkpath(outdir)
    results = postprocessDF(dashvector, seeds, policyName, stationsnames, stationscapacities)
    for (name, df) in pairs(results)
        CSV.write(joinpath(outdir, "$(name).csv"), df isa DataFrame ? df : DataFrame(value = df))
    end
    println("  ##### fine dei salvataggi ##################")
end


function runManySim(cfg::SimConfig, importData::ImportData, seeds::Vector{UInt32}, priorityRule)
    dashvector = Dash[]
    simTimes = Float64[]
    
    numSims = length(seeds)
    totalSimTime = @elapsed begin
        for (idx, seed) in enumerate(seeds)
            oneSimTime = @elapsed begin
                sim, rng, clients, dash = prepareOneSim(seed, cfg, importData)
                oneSimulation!(sim, rng, clients, dash, priorityRule)
                push!(dashvector, dash)
            end
            push!(simTimes, oneSimTime)
        end
    end
    
    return dashvector
end


function oneSimulation!(sim::Environment, rng::StableRNG, clients::Vector{Client}, dash::Dash, priorityRule)
    for client in clients
        @process processClient!(sim, rng, client, clients, dash, priorityRule)
    end
    run(sim)
end


function prepareOneSim(seed::UInt32, cfg::SimConfig, importData::ImportData)
    sim = Simulation()
    stations = buildstations(importData.stationNames, importData.stationCapacities)

    codeRouteStations = [[stations[findfirst(x -> x.name == stationName, stations)] for stationName in route] for route in importData.codeRoutes]

    dash = init_dash(stations)
    rng = StableRNG(seed)
    clients = generateClients(rng, cfg, importData.codeNames, importData.codeDistribution, codeRouteStations, importData.codeSizeValues, importData.codeSizeDistributions, importData.codeProcessingTimes)

    return sim, rng, clients, dash
end

@resumable function processClient!(env::Environment, rng::StableRNG, client::Client, clients::Vector{Client}, dash::Dash, priorityRule)
    @yield timeout(env, client.release_time)
    logging(:systemarrival, env, dash, client, "System")

    while client.current_station <= length(client.route)
        station = client.route[client.current_station]

        readyEvent = Event(env)
        push!(station.waiting_queue, WaitingTicket(client.id, readyEvent))
        logging(:enterqueue, env, dash, client, station.name, length(station.waiting_queue))

        tryDispatch!(env, station, clients, dash, rng, priorityRule)

        @yield readyEvent

        logging(:exitqueue, env, dash, client, station.name, length(station.waiting_queue))
        logging(:startprocess, env, dash, client, station.name)

        @yield timeout(env, client.processing_time[client.current_station])
        logging(:finishprocess, env, dash, client, station.name)

        station.busy -= 1
        tryDispatch!(env, station, clients, dash, rng, priorityRule)

        client.current_station += 1 #quando finisce, sfora le stazioni
    end

    logging(:systemexit, env, dash, client, "System")
end



function tryDispatch!(env::Environment, station::Station, clients::Vector{Client}, dash::Dash, rng::StableRNG, priorityRule)
    while station.busy < station.capacity && !isempty(station.waiting_queue)
        selectionDecision = selectNext(env, station, clients, rng, priorityRule)
        selectedTicket = splice!(station.waiting_queue, selectionDecision.queue_position)
        if selectionDecision.effective_policy !== nothing
            push!(
                dash.adaptiveSelectionLog,
                AdaptiveSelectionLog(now(env), station.name, selectionDecision.effective_policy),
            )
        end
        station.busy += 1
        succeed(selectedTicket.ready_event)
    end
end

end #quello del modulo
