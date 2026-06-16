println()
println("############################################")
println("########                            ########")
println("########     Buongiorno Padrona     ########")
println("########                            ########")
println("############################################")
println()

#println("##### loading config #######################")
include("config.jl")

#println("##### loading simulation engine ############")
include("src/simemul.jl")

include("src/anova.jl")
println("##### Analysis Modules Loaded ##############")

#println("##### loading figure module ################")
include("src/aftermath.jl")

#println("##### loading evaluation module ############")
include("src/evaluation.jl")

#println("##### loading ex-post evaluation module ####")
include("src/evaluation_ex_post.jl")

#println("##### loading orchestration ################")
include("orchestration.jl")

println()
println("############################################")
println("########                            ########")
println("########     Abbiamo importato.     ########")
println("########     Perdoni la lentezza    ########")
println("########                            ########")
println("############################################")
println()

using .configdata
using .simEmul
using .showanova
using .showdash
using .showevaluation
using .showexpost
using .orchestration

runCampaign(runModes, analysisRunModes, exPostRunModes)
