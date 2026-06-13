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

function runSaveSim(cfg::SimConfig, importData::ImportData, seeds::Vector{UInt32}, policyName::String, priorityRule, outdir::String)
    totalTime = @elapsed begin
        simTime = @elapsed dashvector = runManySim(cfg, importData, seeds, priorityRule)
        saveTime = @elapsed saveResults(dashvector, seeds, policyName, outdir, importData.stationNames, importData.stationCapacities)
    end
    
    return (simTime = simTime, saveTime = saveTime, totalTime = totalTime, simCount = length(seeds))
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
