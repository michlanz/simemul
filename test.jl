using Plots

gr()

x = [1.0, 2.0, 3.0, 4.0, 5.0]
y = [1.0, 1.4, 1.8, 1.2, 2.1]

p = scatter(
    xlabel = "Dummy X",
    ylabel = "Dummy Y",
    title = "Marker test: small black dot and small black star",
    legend = :outertopright,
    grid = true,
    framestyle = :box,
    size = (1000, 650),
)

scatter!(
    p,
    x[[1, 5]],
    y[[1, 5]];
    label = "Outside tolerance",
    markercolor = :gray75,
    markerstrokecolor = :gray35,
    markersize = 7,
)

scatter!(
    p,
    x[[2, 4]],
    y[[2, 4]];
    label = "Within 2.0% of global Pareto",
    markercolor = :gold,
    markerstrokecolor = :darkorange,
    markersize = 8,
)

scatter!(
    p,
    x[[3]],
    y[[3]];
    label = "Cut Pareto",
    markercolor = :green3,
    markerstrokecolor = :green3,
    markersize = 8,
)

scatter!(
    p,
    x[[2, 3]],
    y[[2, 3]];
    label = "",
    markershape = :circle,
    markercolor = :black,
    markerstrokecolor = :black,
    markersize = 3,
)

scatter!(
    p,
    [NaN],
    [NaN];
    label = "Global Pareto",
    markershape = :circle,
    markercolor = :black,
    markerstrokecolor = :black,
    markersize = 3,
)

scatter!(
    p,
    x[[4]],
    y[[4]];
    label = "Within tolerance all cuts",
    markershape = :star5,
    markercolor = :black,
    markerstrokecolor = :black,
    markerstrokewidth = 1.0,
    markersize = 7,
)

savefig(p, "test_marker_dot_star.png")
display(p)
gui()

println("Saved in: ", joinpath(pwd(), "test_marker_dot_star.png"))
println("Press Enter to close")
readline()