module coresimulation

using ..StableRNGs
using ..ResumableFunctions
using ..CSV
using ..ConcurrentSim
using ..DataFrames
using ..Distributions

using ..structures
using ..selectionrules
using ..postprocess

export runSaveSim, runManySim, saveResults

function runSaveSim(seeds::Vector{UInt32}, stationsnames::Vector{String}, stationscapacities::Vector{Int64}, codesroute::Vector{Vector{String}}, codesnames::Vector{String}, codesdistribution::Categorical, codessizevalues::Vector{Vector{Int64}}, codessizedistributions::Vector{Categorical}, codesprocessingtimes::Vector{Vector{Float64}}, clientnum::Int64, priorityRule, outdir::String)
    dashvector = runManySim(seeds, stationsnames, stationscapacities, codesroute, codesnames, codesdistribution, codessizevalues, codessizedistributions, codesprocessingtimes, clientnum, priorityRule)
    saveResults(dashvector, outdir, clientnum)
end


function saveResults(dashvector::Vector{Dash}, outdir::String, clientnum::Int64)
    println("##### inizio dei salvataggi ################")
    mkpath(outdir)
    results = postprocessDF(dashvector, clientnum)
    for (name, df) in pairs(results)
        CSV.write(joinpath(outdir, "$(name).csv"), df isa DataFrame ? df : DataFrame(value = df))
    end
    println("##### fine dei salvataggi ##################")
end


function runManySim(seeds::Vector{UInt32}, stationsnames::Vector{String}, stationscapacities::Vector{Int64}, codesroute::Vector{Vector{String}}, codesnames::Vector{String}, codesdistribution::Categorical, codessizevalues::Vector{Vector{Int64}}, codessizedistributions::Vector{Categorical}, codesprocessingtimes::Vector{Vector{Float64}}, clientnum::Int64, priorityRule)
    dashvector = Dash[]
    for seed in seeds
        sim, rng, clients, dash = prepareOneSim(seed, stationsnames, stationscapacities, codesroute, codesnames, codesdistribution, codessizevalues, codessizedistributions, codesprocessingtimes, clientnum)
        oneSimulation!(sim, rng, clients, dash, priorityRule)
        push!(dashvector, dash)
    end
    return dashvector
end


function oneSimulation!(sim::Environment, rng::StableRNG, clients::Vector{Client}, dash::Dash, priorityRule)
    systemunits = [0]
    for client in clients
        @process processClient!(sim, rng, client, clients, dash, systemunits, priorityRule)
    end
    run(sim)
end


function prepareOneSim(seed::UInt32, stationsnames::Vector{String}, stationscapacities::Vector{Int64}, codesroute::Vector{Vector{String}}, codesnames::Vector{String}, codesdistribution::Categorical, codessizevalues::Vector{Vector{Int64}}, codessizedistributions::Vector{Categorical}, codesprocessingtimes::Vector{Vector{Float64}}, clientnum::Int64)
    sim = Simulation()
    stations = buildstations(stationsnames, stationscapacities)

    codesroutestations = [[stations[findfirst(x -> x.name == s, stations)] for s in route] for route in codesroute]

    dash = init_dash(stations)
    rng = StableRNG(seed)
    clients = generateClients(rng, clientnum, codesnames, codesdistribution, codesroutestations, codessizevalues, codessizedistributions, codesprocessingtimes)

    return sim, rng, clients, dash
end

@resumable function processClient!(env::Environment, rng::StableRNG, client::Client, clients::Vector{Client}, dash::Dash, systemunits::Vector{Int64}, priorityRule)
    @yield timeout(env, client.release_time)
    systemunits[1] += 1
    logging(:systemarrival, env, dash, client, "System", systemunits[1])

    while client.current_station <= length(client.route)
        station = client.route[client.current_station]

        readyEvent = Event(env)
        push!(station.waiting_queue, WaitingTicket(client.id, readyEvent))
        logging(:enterqueue, env, dash, client, station.name, systemunits[1])

        tryDispatch!(env, station, clients, rng, priorityRule)

        @yield readyEvent

        logging(:exitqueue, env, dash, client, station.name, systemunits[1])
        logging(:startprocess, env, dash, client, station.name, systemunits[1])

        @yield timeout(env, client.processing_time[client.current_station])
        logging(:finishprocess, env, dash, client, station.name, systemunits[1])

        station.busy -= 1
        tryDispatch!(env, station, clients, rng, priorityRule)

        client.current_station += 1 #quando finisce, sfora le stazioni
    end

    systemunits[1] -= 1
    logging(:systemexit, env, dash, client, "System", systemunits[1])
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



