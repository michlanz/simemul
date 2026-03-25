module inputdata

using ..JSON3
using ..DataFrames
using ..CSV
using ..Distributions
using ..configdata: SimConfig

export ImportData, loadImportData

struct ImportData
    codeNames::Vector{String}
    codeDistribution::Categorical
    codeRoutes::Vector{Vector{String}}
    stationNames::Vector{String}
    codeSizeValues::Vector{Vector{Int64}}
    codeSizeDistributions::Vector{Categorical}
    codeProcessingTimes::Vector{Vector{Float64}}
    stationCapacities::Vector{Int64}
end

function loadImportData(cfg::SimConfig)::ImportData
    coderegistry = DataFrame(JSON3.read(read(joinpath(cfg.inputPath, cfg.registryFile))))
    lavmat = CSV.read(joinpath(cfg.inputPath, cfg.matrixFile), DataFrame)
    rename!(lavmat, names(lavmat)[1] => "CodeXX")
    codeNames::Vector{String} = string.(coderegistry.CodeXX)
    codeDistribution::Categorical = Categorical(coderegistry.occurrence)
    codeRoutes::Vector{Vector{String}} = coderegistry.route
    stationNames::Vector{String} = sort!(unique!(reduce(vcat, codeRoutes)))
    codeSizeValues::Vector{Vector{Int64}} = [parse.(Int64, String.(collect(keys(obj)))) for obj in coderegistry.lot_distribution]
    codeSizeDistributions::Vector{Categorical} = [Categorical(Float64.(values(obj))) for obj in coderegistry.lot_distribution]
    codeProcessingTimes::Vector{Vector{Float64}} = [[lavmat[lavmat.CodeXX .== code, Symbol(station)][1] for station in route] for (code, route) in zip(codeNames, codeRoutes)]
    stationCapacities::Vector{Int64} = [4, 3, 2, 3, 3, 2, 4, 3]
    return ImportData(
        codeNames,
        codeDistribution,
        codeRoutes,
        stationNames,
        codeSizeValues,
        codeSizeDistributions,
        codeProcessingTimes,
        stationCapacities,
    )
end


end
