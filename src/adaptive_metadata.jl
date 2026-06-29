module adaptivemetadata

using DataFrames

export THRESHOLD_COLUMNS,
       METADATA_COLUMNS,
       adaptiveThresholdColumn,
       thresholdDisplayName,
       thresholdEffectPrefix,
       triggerInfo,
       emptyScenarioMetadata,
       scenarioMetadata,
       scenarioMetadataTuple,
       addAdaptiveMetadataColumns!,
       scenarioAxisColumns,
       singleAxisColumnFromLabels,
       combinedAxisColumnsFromLabels,
       combinedAxisColumnsFromFrame,
       sortByAxisColumns!

const THRESHOLD_COLUMNS = [
    :spt_queue_threshold,
    :edd_due_threshold,
    :minslack_slack_threshold,
    :criticalratio_ratio_threshold,
]

const CONTEXT_COLUMNS = [
    :base_policy,
    :adaptive_policy,
    :priority_first_policy,
    :priority_second_policy,
]

const METADATA_COLUMNS = vcat(CONTEXT_COLUMNS, THRESHOLD_COLUMNS)

function adaptiveThresholdColumn(policy::AbstractString)::Symbol
    text = uppercase(String(policy))
    text == "SPT" && return :spt_queue_threshold
    text == "EDD" && return :edd_due_threshold
    text == "MINSLACK" && return :minslack_slack_threshold
    text == "CRITICALRATIO" && return :criticalratio_ratio_threshold
    error("Policy adaptive non supportata per metadata: $(policy)")
end

function thresholdDisplayName(column::Symbol)::String
    column == :spt_queue_threshold && return "SPT queue threshold"
    column == :edd_due_threshold && return "EDD due threshold"
    column == :minslack_slack_threshold && return "MINSLACK slack threshold"
    column == :criticalratio_ratio_threshold && return "CRITICALRATIO ratio threshold"
    return replace(String(column), "_" => " ")
end

function thresholdEffectPrefix(column::Symbol)::String
    text = String(column)
    return replace(text, "_threshold" => "")
end

function emptyScenarioMetadata()
    metadata = Dict{Symbol, Any}()
    for column in CONTEXT_COLUMNS
        metadata[column] = missing
    end
    for column in THRESHOLD_COLUMNS
        metadata[column] = missing
    end
    return metadata
end

function parseThreshold(value::AbstractString)::Float64
    return parse(Float64, String(value))
end

function thresholdValue(policy::AbstractString, value)
    uppercase(String(policy)) == "SPT" && return Int(round(Float64(value)))
    return Float64(value)
end

function triggerInfo(label::AbstractString)
    text = String(label)

    m = match(r"^spt_queue_(\d+)$", text)
    m !== nothing && return (policy = "SPT", value = parseThreshold(m.captures[1]), column = :spt_queue_threshold)

    m = match(r"^queue_(\d+)$", text)
    m !== nothing && return (policy = "SPT", value = parseThreshold(m.captures[1]), column = :spt_queue_threshold)

    m = match(r"^edd_due_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "EDD", value = parseThreshold(m.captures[1]), column = :edd_due_threshold)

    m = match(r"^edd_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "EDD", value = parseThreshold(m.captures[1]), column = :edd_due_threshold)

    m = match(r"^minslack_slack_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "MINSLACK", value = parseThreshold(m.captures[1]), column = :minslack_slack_threshold)

    m = match(r"^slack_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "MINSLACK", value = parseThreshold(m.captures[1]), column = :minslack_slack_threshold)

    m = match(r"^criticalratio_ratio_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "CRITICALRATIO", value = parseThreshold(m.captures[1]), column = :criticalratio_ratio_threshold)

    m = match(r"^criticalratio_([0-9]+(?:\.[0-9]+)?)$", text)
    m !== nothing && return (policy = "CRITICALRATIO", value = parseThreshold(m.captures[1]), column = :criticalratio_ratio_threshold)

    return nothing
end

function setPolicyThreshold!(metadata::Dict{Symbol, Any}, trigger)
    trigger === nothing && return metadata
    metadata[trigger.column] = thresholdValue(trigger.policy, trigger.value)
    return metadata
end

function scenarioMetadata(policyLabel::AbstractString, candidateType::AbstractString = "")
    label = String(policyLabel)
    metadata = emptyScenarioMetadata()

    genericSingle = match(r"^adaptive_([a-z]+)__(.+)$", label)
    if genericSingle !== nothing
        metadata[:base_policy] = uppercase(genericSingle.captures[1])
        trigger = triggerInfo(genericSingle.captures[2])
        if trigger !== nothing
            metadata[:adaptive_policy] = trigger.policy
            setPolicyThreshold!(metadata, trigger)
        end
        return metadata
    end

    genericCombined = match(r"^combined_([a-z]+)__(.+)_first__(.+)$", label)
    if genericCombined !== nothing
        metadata[:base_policy] = uppercase(genericCombined.captures[1])
        firstTrigger = triggerInfo(genericCombined.captures[2])
        secondTrigger = triggerInfo(genericCombined.captures[3])
        if firstTrigger !== nothing
            metadata[:priority_first_policy] = firstTrigger.policy
            setPolicyThreshold!(metadata, firstTrigger)
        end
        if secondTrigger !== nothing
            metadata[:priority_second_policy] = secondTrigger.policy
            setPolicyThreshold!(metadata, secondTrigger)
        end
        return metadata
    end

    legacyCombined = match(r"^combined_(queue|slack)_first__(queue_\d+)__(slack_[0-9]+(?:\.[0-9]+)?)$", label)
    if legacyCombined !== nothing
        metadata[:base_policy] = "FIFO"
        queueTrigger = triggerInfo(legacyCombined.captures[2])
        slackTrigger = triggerInfo(legacyCombined.captures[3])
        first = legacyCombined.captures[1] == "queue" ? queueTrigger : slackTrigger
        second = legacyCombined.captures[1] == "queue" ? slackTrigger : queueTrigger
        metadata[:priority_first_policy] = first.policy
        metadata[:priority_second_policy] = second.policy
        setPolicyThreshold!(metadata, queueTrigger)
        setPolicyThreshold!(metadata, slackTrigger)
        return metadata
    end

    bareCombined = match(r"^(.+)__(.+)$", label)
    if bareCombined !== nothing
        firstTrigger = triggerInfo(bareCombined.captures[1])
        secondTrigger = triggerInfo(bareCombined.captures[2])
        if firstTrigger !== nothing && secondTrigger !== nothing
            metadata[:base_policy] = "FIFO"
            setPolicyThreshold!(metadata, firstTrigger)
            setPolicyThreshold!(metadata, secondTrigger)
            return metadata
        end
    end

    trigger = triggerInfo(label)
    if trigger !== nothing
        metadata[:base_policy] = "FIFO"
        metadata[:adaptive_policy] = trigger.policy
        setPolicyThreshold!(metadata, trigger)
        return metadata
    end

    return metadata
end

function scenarioMetadataTuple(policyLabel::AbstractString, candidateType::AbstractString = "")
    metadata = scenarioMetadata(policyLabel, candidateType)
    return (
        base_policy = metadata[:base_policy],
        adaptive_policy = metadata[:adaptive_policy],
        priority_first_policy = metadata[:priority_first_policy],
        priority_second_policy = metadata[:priority_second_policy],
        spt_queue_threshold = metadata[:spt_queue_threshold],
        edd_due_threshold = metadata[:edd_due_threshold],
        minslack_slack_threshold = metadata[:minslack_slack_threshold],
        criticalratio_ratio_threshold = metadata[:criticalratio_ratio_threshold],
    )
end

function addAdaptiveMetadataColumns!(df::DataFrame, labelColumn::Symbol = :policy)::DataFrame
    labelColumn in propertynames(df) || error("Colonna label mancante per metadata adaptive: $(labelColumn)")
    metadataRows = [scenarioMetadataTuple(String(label)) for label in df[!, labelColumn]]
    for column in METADATA_COLUMNS
        df[!, column] = [getproperty(row, column) for row in metadataRows]
    end
    return df
end

function scenarioAxisColumns(policyLabel::AbstractString)::Vector{Symbol}
    metadata = scenarioMetadata(policyLabel)
    cols = Symbol[]

    if !ismissing(metadata[:priority_first_policy])
        push!(cols, adaptiveThresholdColumn(String(metadata[:priority_first_policy])))
    end
    if !ismissing(metadata[:priority_second_policy])
        push!(cols, adaptiveThresholdColumn(String(metadata[:priority_second_policy])))
    end

    if isempty(cols)
        for column in THRESHOLD_COLUMNS
            !ismissing(metadata[column]) && push!(cols, column)
        end
    end

    return unique(cols)
end

function axisColumnsFromLabels(labels, expectedCount::Int)
    cleanLabels = collect(String.(labels))
    isempty(cleanLabels) && return nothing
    firstCols = scenarioAxisColumns(first(cleanLabels))
    length(firstCols) == expectedCount || return nothing

    firstSet = Set(firstCols)
    for label in cleanLabels
        cols = scenarioAxisColumns(label)
        length(cols) == expectedCount || return nothing
        Set(cols) == firstSet || return nothing
    end

    return firstCols
end

function singleAxisColumnFromLabels(labels)
    cols = axisColumnsFromLabels(labels, 1)
    cols === nothing && return nothing
    return only(cols)
end

function combinedAxisColumnsFromLabels(labels)
    return axisColumnsFromLabels(labels, 2)
end

function hasConcreteValue(value)::Bool
    return !ismissing(value) && !(value isa AbstractFloat && isnan(value))
end

function combinedAxisColumnsFromFrame(df::DataFrame)
    if :queue_threshold in propertynames(df) && !(:spt_queue_threshold in propertynames(df))
        df[!, :spt_queue_threshold] = Int.(df[!, :queue_threshold])
    end
    if :slack_threshold in propertynames(df) && !(:minslack_slack_threshold in propertynames(df))
        df[!, :minslack_slack_threshold] = Float64.(df[!, :slack_threshold])
    end

    if :priority_first_policy in propertynames(df) && :priority_second_policy in propertynames(df)
        firstValues = [value for value in df.priority_first_policy if hasConcreteValue(value)]
        secondValues = [value for value in df.priority_second_policy if hasConcreteValue(value)]
        if !isempty(firstValues) && !isempty(secondValues)
            firstColumn = adaptiveThresholdColumn(String(first(firstValues)))
            secondColumn = adaptiveThresholdColumn(String(first(secondValues)))
            if firstColumn in propertynames(df) &&
               secondColumn in propertynames(df) &&
               any(hasConcreteValue, df[!, firstColumn]) &&
               any(hasConcreteValue, df[!, secondColumn])
                return [firstColumn, secondColumn]
            end
        end
    end

    cols = Symbol[]
    for column in THRESHOLD_COLUMNS
        column in propertynames(df) || continue
        any(hasConcreteValue, df[!, column]) && push!(cols, column)
    end

    if length(cols) == 2
        return cols
    end

    return nothing
end

function sortByAxisColumns!(df::DataFrame, axisColumns::Vector{Symbol}; leading::Vector{Symbol} = Symbol[])
    cols = vcat(leading, axisColumns)
    cols = [col for col in cols if col in propertynames(df)]
    isempty(cols) || sort!(df, cols)
    return df
end

end
