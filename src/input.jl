module inputdata

using ..JSON3
using ..DataFrames
using ..CSV
using ..StableRNGs
using ..Distributions

export CLIENTNUM, buildinput

#FIXME non sono sicura di volere il clientum definito dentro l'input. non posso definirlo in un pannello di controllo?
#FIXME ci sara un modo intelligente di esportare gli input
function buildinput(path::String, registry::String, matrix::String)
    coderegistry = DataFrame(JSON3.read(read(joinpath(path, registry))))
    lavmat = CSV.read(joinpath(path, matrix), DataFrame)
    rename!(lavmat, names(lavmat)[1] => "CodeXX")
    codesnames::Vector{String} = string.(coderegistry.CodeXX)
    codesdistribution::Categorical = Categorical(coderegistry.occurrence)
    codesroute::Vector{Vector{String}} = coderegistry.route
    stationsnames::Vector{String} = sort!(unique!(reduce(vcat, codesroute)))
    codessizevalues::Vector{Vector{Int64}} = [parse.(Int64, String.(collect(keys(obj)))) for obj in coderegistry.lot_distribution]
    codessizedistributions::Vector{Categorical} = [Categorical(Float64.(values(obj))) for obj in coderegistry.lot_distribution]
    codesprocessingtimes::Vector{Vector{Float64}} = [[lavmat[lavmat.CodeXX .== code, Symbol(s)][1] for s in route] for (code, route) in zip(codesnames, codesroute)]
    stationscapacities::Vector{Int64} = [4, 3, 2, 3, 3, 2, 4, 3]
    return codesnames,
           codesdistribution,
           codesroute,
           stationsnames,
           codessizevalues,
           codessizedistributions,
           codesprocessingtimes,
           stationscapacities
end


end