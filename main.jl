#qui lancio il main

include("src/simemul.jl")
include("src/aftermath.jl")
include("src/anova.jl")

using .simEmul
using .showdash
using .showanova

outpath = "results2"

# Se decommenti :anova o :figures, scegli qui quale campagna analizzare.
#analysisPath = joinpath(outpath, "1.adaptive_SPT")
analysisPath = joinpath(outpath, "2.adaptive_SLACK")

runModes = [
    # :adaptive_spt,
     :adaptive_slack,
    # :adaptive_combined,
    # :static,
     :anova,
    # :figures,
]

for runMode in runModes
    println("##### RUN MODE: $(runMode) #####")

    if runMode == :adaptive_spt
        simemAdaptiveSPT(outpath)
    elseif runMode == :adaptive_slack
        simemAdaptiveSlack(outpath)
    elseif runMode == :adaptive_combined
        simemAdaptiveCombined(outpath)
    elseif runMode == :static
        simem(outpath)
    elseif runMode == :anova
        performAnova(analysisPath)
    elseif runMode == :figures
        savefigs(analysisPath)
    else
        error("Unknown runMode: $(runMode)")
    end
end
