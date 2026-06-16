module configdata

using StableRNGs
using Random

export SimConfig,
       DashboardColors,
       anovaEffectColors,
       relativeHeatmapColors,
       surfacePlotColors,
       buildSeeds,
       analysisRunModes,
       exPostRunModes,
       makespanComponentColors,
       runModes,
       seriesColors,
       validateConfig

# ========     CONFIGURAZIONE PIPELINE     ===================================

const analysisRunModes = [
     :static,
     :adaptive_spt,
     :adaptive_slack,
     :adaptive_combined_spt_first,
     :adaptive_combined_slack_first,
]

const exPostRunModes = [
     :static,
     :adaptive_spt,
     :adaptive_slack,
     :adaptive_combined_spt_first,
     :adaptive_combined_slack_first,
]

const runModes = [
     #:static,
     #:adaptive_spt,
     #:adaptive_slack,
     #:adaptive_combined_spt_first,
     #:adaptive_combined_slack_first,
     #:figures,
     #:anova,
     #:evaluation,
     :ex_post,
]


# ========     CONFIGURAZIONE MODELLO     ====================================

Base.@kwdef struct SimConfig
    clientNum::Int64 = 320
    repetitions::Int64 = 100
    masterSeed::Int64 = 42
    paretoTolerancePercent::Float64 = 2.0
    inputPath::String = "inputfile"
    registryFile::String = "code_registry_3route_5client_norm.json"
    matrixFile::String = "lavoration_matrix.csv"
    releaseBatchSize::Int64 = 80
    releaseBatchSpacing::Float64 = 40.0
    dueDateMinOffset::Float64 = 16.0
    dueDateMaxOffset::Float64 = 40.0
    adaptivePriorityOrder::Tuple{Symbol, Symbol} = (:SPT, :MINSLACK)
    adaptiveQueueMin::Int64 = 3
    adaptiveQueueMax::Int64 = 50
    adaptiveSlackMin::Float64 = 0.0
    adaptiveSlackMax::Float64 = 14.0
    adaptiveSlackStep::Float64 = 0.2
end

const DashboardColors = (
    neutral = :lightgrey,
    positive = :green3,
    negative = :crimson,
    caution = :gold,
    seriesPalette = :viridis,
    processing = :magenta,
)

const anovaEffectColors = (
    queue = :deepskyblue,
    slack = :hotpink2,
    interaction = :green3,
    residual = :lightgrey,
)

const relativeHeatmapColors = (
    worse = :firebrick,
    neutral = :white,
    better = :forestgreen,
    )
    
    const surfacePlotColors = (
        worse = :firebrick,
    neutral = :gold,
    better = :forestgreen,
)

function validateConfig(cfg::SimConfig)::SimConfig
    cfg.clientNum > 0 || error("clientNum deve essere positivo")
    cfg.repetitions > 0 || error("repetitions deve essere positivo")
    cfg.releaseBatchSize > 0 || error("releaseBatchSize deve essere positivo")
    cfg.releaseBatchSpacing >= 0.0 || error("releaseBatchSpacing non puo essere negativo")
    cfg.dueDateMinOffset >= 0.0 || error("dueDateMinOffset non puo essere negativo")
    cfg.dueDateMaxOffset >= cfg.dueDateMinOffset || error("dueDateMaxOffset deve essere maggiore o uguale a dueDateMinOffset")
    Set(cfg.adaptivePriorityOrder) == Set([:SPT, :MINSLACK]) || error("adaptivePriorityOrder deve contenere esattamente :SPT e :MINSLACK")
    cfg.adaptiveQueueMin > 0 || error("adaptiveQueueMin deve essere positivo")
    cfg.adaptiveQueueMax >= cfg.adaptiveQueueMin || error("adaptiveQueueMax deve essere maggiore o uguale a adaptiveQueueMin")
    cfg.adaptiveSlackStep > 0.0 || error("adaptiveSlackStep deve essere positivo")
    cfg.adaptiveSlackMax >= cfg.adaptiveSlackMin || error("adaptiveSlackMax deve essere maggiore o uguale a adaptiveSlackMin")
    cfg.paretoTolerancePercent >= 0.0 || error("paretoTolerancePercent non puo essere negativo")
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
