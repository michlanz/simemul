module configdata

using StableRNGs
using Random

export SimConfig,
       DashboardColors,
       anovaEffectColors,
       relativeHeatmapColors,
       surfacePlotColors,
       buildSeeds,
       adaptiveBasePolicy,
       adaptivePolicies,
       adaptiveThresholdSpecs,
       analysisRunModes,
       bestPolicyLabels,
       exPostOutputDir,
       exPostRunRange,
       findBestOutputDir,
       findBestParetoMetrics,
       findBestRunNumbers,
       makespanComponentColors,
       runModes,
       seriesColors,
       validateConfig

# ========     CONFIGURAZIONE PIPELINE     ===================================

# Campagne da usare quando runModes contiene :figures, :anova o :evaluation.
# Per analizzare l'ultima campagna best prodotta, lascia :best.
const analysisRunModes = [
    :static,
    :adaptive_first,
    :adaptive_second,
    :combined_first,
    :combined_second,
    :best,
]

# Modalita operative da lanciare.
# :best usa bestPolicyLabels; :find_best genera suggerimenti copiabili.
const runModes = [
     #:best,
     #:static,
     #:adaptive_first,
     #:adaptive_second,
     #:combined_first,
     #:combined_second,
     #:figures,
     #:anova,
     #:evaluation,
     #:find_best,
     :ex_post,
]


# Range di campagne usato da :ex_post per identificare le migliori policy.
const exPostRunRange = 14:18
const exPostOutputDir = "r14_18_ex_post"

# ========     CONFIGURAZIONE FIND BEST     ==================================

const findBestRunNumbers = 14:18
const findBestOutputDir = "r14_18_find_best"
const findBestParetoMetrics = (:simtime, :ontime_share, :mean_processing_ratio)

# Lista manuale usata dalla run mode :best. Il file find_best_policy_labels.jl
# prodotto da :find_best genera righe copiabili qui.
const bestPolicyLabels = [
    "02.FIFO",
    "03.LIFO",
    "04.SPT",
    "06.EDD",
    "07.MINSLACK",
    "combined_queue_first__queue_003__slack_12.2",
    "combined_queue_first__queue_003__slack_12.4",
    "combined_queue_first__queue_004__slack_13.6",
    "combined_slack_first__queue_003__slack_3.6",
    "combined_slack_first__queue_003__slack_6.0",
    "combined_slack_first__queue_003__slack_6.2",
    "combined_slack_first__queue_004__slack_8.2",
    "combined_slack_first__queue_016__slack_8.2",
    "combined_slack_first__queue_020__slack_9.0",
    "combined_slack_first__queue_021__slack_7.4",
    "combined_slack_first__queue_022__slack_7.2",
    "combined_slack_first__queue_022__slack_9.0",
]

# ========     CONFIGURAZIONE ADAPTIVE     ===================================

const adaptiveBasePolicy = :LIFO
const adaptivePolicies = [:SPT, :EDD]

const adaptiveThresholdSpecs = (
    SPT = (min = 3.0, max = 30.0, step = 1.0),
    EDD = (min = 0.0, max = 16.0, step = 0.5),
    MINSLACK = (min = 0.0, max = 16.0, step = 0.5),
    CRITICALRATIO = (min = 0.1, max = 2.0, step = 0.1),
)

# ========     CONFIGURAZIONE MODELLO     ====================================
#standard: 320 lotti, 80 ogni 40 ore, CV 0.1, offset 16-40 ore, 100 ripetizioni, seed 42
Base.@kwdef struct SimConfig
    clientNum::Int64 = 40
    repetitions::Int64 = 100
    masterSeed::Int64 = 42
    paretoTolerancePercent::Float64 = 2.0
    processingTimeCV::Float64 = 0.1
    inputPath::String = "inputfile"
    registryFile::String = "code_registry_3route_5client_norm.json"
    matrixFile::String = "lavoration_matrix.csv"
    releaseBatchSize::Int64 = 80
    releaseBatchSpacing::Float64 = 40.0
    dueDateMinOffset::Float64 = 16.0
    dueDateMaxOffset::Float64 = 40.0
    adaptivePriorityOrder::Tuple{Symbol, Symbol} = (:SPT, :MINSLACK) #TODO: SERVE ANCORA?
    adaptiveQueueMin::Int64 = 3
    adaptiveQueueMax::Int64 = 30
    adaptiveSlackMin::Float64 = 0.0
    adaptiveSlackMax::Float64 = 16.0
    adaptiveSlackStep::Float64 = 0.5
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
    cfg.processingTimeCV >= 0.0 || error("processingTimeCV non puo essere negativo")
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
