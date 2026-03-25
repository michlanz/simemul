module coresimulation

using ..StableRNGs
using ..ResumableFunctions
using ..CSV
using ..ConcurrentSim
using ..DataFrames
using ..Distributions

using ..configdata: SimConfig
using ..inputdata: ImportData
using ..structures
using ..selectionrules
using ..postprocess

export runSaveSim, runManySim, saveResults

function runSaveSim(cfg::SimConfig, importData::ImportData, seeds::Vector{UInt32}, policyName::String, priorityRule, outdir::String)
    dashvector = runManySim(cfg, importData, seeds, priorityRule)
    saveResults(dashvector, seeds, policyName, outdir, importData.stationNames, importData.stationCapacities)
end


function saveResults(dashvector::Vector{Dash}, seeds::Vector{UInt32}, policyName::String, outdir::String, stationsnames::Vector{String}, stationscapacities::Vector{Int64})
    println("##### inizio dei salvataggi ################")
    mkpath(outdir)
    results = postprocessDF(dashvector, seeds, policyName, stationsnames, stationscapacities)
    for (name, df) in pairs(results)
        CSV.write(joinpath(outdir, "$(name).csv"), df isa DataFrame ? df : DataFrame(value = df))
    end
    println("##### fine dei salvataggi ##################")
end


function runManySim(cfg::SimConfig, importData::ImportData, seeds::Vector{UInt32}, priorityRule)
    dashvector = Dash[]
    for seed in seeds
        sim, rng, clients, dash = prepareOneSim(seed, cfg, importData)
        oneSimulation!(sim, rng, clients, dash, priorityRule)
        push!(dashvector, dash)
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

        tryDispatch!(env, station, clients, rng, priorityRule)

        @yield readyEvent

        logging(:exitqueue, env, dash, client, station.name, length(station.waiting_queue))
        logging(:startprocess, env, dash, client, station.name)

        @yield timeout(env, client.processing_time[client.current_station])
        logging(:finishprocess, env, dash, client, station.name)

        station.busy -= 1
        tryDispatch!(env, station, clients, rng, priorityRule)

        client.current_station += 1 #quando finisce, sfora le stazioni
    end

    logging(:systemexit, env, dash, client, "System")
end



function tryDispatch!(env::Environment, station::Station, clients::Vector{Client}, rng::StableRNG, priorityRule)
    while station.busy < station.capacity && !isempty(station.waiting_queue)
        selectedQueuePos = selectNext(env, station, clients, rng, priorityRule)
        selectedTicket = splice!(station.waiting_queue, selectedQueuePos)
        station.busy += 1
        succeed(selectedTicket.ready_event)
    end
end

end #quello del modulo
