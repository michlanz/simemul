module configdata

using ..StableRNGs
using ..Random

export SimConfig,
       DashboardColors,
       buildSeeds,
       makespanComponentColors,
       seriesColors,
       validateConfig

Base.@kwdef struct SimConfig
    clientNum::Int64 = 320
    repetitions::Int64 = 100
    masterSeed::Int64 = 42
    inputPath::String = "inputfile"
    registryFile::String = "code_registry_3route_5client_norm.json"
    matrixFile::String = "lavoration_matrix.csv"
    releaseBatchSize::Int64 = 80
    releaseBatchSpacing::Float64 = 40.0
    dueDateMinOffset::Float64 = 16.0
    dueDateMaxOffset::Float64 = 40.0
end

const DashboardColors = (
    neutral = :lightgrey,
    positive = :green3,
    negative = :crimson,
    caution = :gold,
    seriesPalette = :viridis,
    processing = :magenta,
)

function validateConfig(cfg::SimConfig)::SimConfig
    cfg.clientNum > 0 || error("clientNum deve essere positivo")
    cfg.repetitions > 0 || error("repetitions deve essere positivo")
    cfg.releaseBatchSize > 0 || error("releaseBatchSize deve essere positivo")
    cfg.releaseBatchSpacing >= 0.0 || error("releaseBatchSpacing non puo essere negativo")
    cfg.dueDateMinOffset >= 0.0 || error("dueDateMinOffset non puo essere negativo")
    cfg.dueDateMaxOffset >= cfg.dueDateMinOffset || error("dueDateMaxOffset deve essere maggiore o uguale a dueDateMinOffset")
    return cfg
end

function buildSeeds(cfg::SimConfig)::Vector{UInt32}
    validateConfig(cfg)
    seedsRng = StableRNG(cfg.masterSeed)
    return rand(seedsRng, UInt32, cfg.repetitions)
end

function seriesColors(paletteBuilder, count::Int)
    count <= 0 && return Symbol[]
    return collect(paletteBuilder(DashboardColors.seriesPalette, count))
end

function makespanComponentColors(paletteBuilder, waitingCount::Int)
    return vcat(seriesColors(paletteBuilder, waitingCount), [DashboardColors.processing])
end

end
