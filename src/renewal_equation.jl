include("../src/renewal_equation_utils.jl")

# Variable declaration
Valentina_gam1 = GammaOffset(3.42, 5.25, 1.0)
# Valentina_gam2 = GammaOffset(28.74, 1.01, 1.0)
Valentina_wb_ser1 = WeibullOffset(1.63, 18.29, 1)
Valentina_wb_ser2 = WeibullOffset(2.17, 6.10, 6)

UnivariateAndOffset = Union{UnivariateDistribution, UnivariateOffset}

struct RenewalRtHolder
	x::Union{Vector, AbstractRange}
	y::Vector
	chn::Chains
	dic::Dict
end

function RenewalRtHolder(x::Vector, y::Vector, Is::Vector, chn::Chains)
	dic = Dict(
		:Rt_mlh => quantile(chn[:Rt][:, 1], [0.5, 0.025, 0.975]),
		:Is => Is,
	)
	return RenewalRtHolder(x, y, chn, dic)
end

function weekly_discretise_pdf(d::UnivariateAndOffset)::Vector{Float64}
	return [cdf(d, 7 * (i + 1)) - cdf(d, 7 * i) for i in 0:100]
end

function estimated_incidence_renewal(Cs, d_weekly_pdf)
	return sum([d_weekly_pdf[s] * Cs[end-s] for s in 1:(length(Cs)-1)])
end


"""Renewal equation to calculate the reproduction number
"""
@model function renewal_equation_Rt_piecewise(Cs::Vector, λs::Vector)
	Rt ~ Gamma(1, 2)
	for i in 1:length(Cs)
		Cs[i] ~ Poisson(λs[i] * Rt)
	end
end

"""Renewal equation considering spillover events.

# Args:
- Cs: Confirmed weekly cases.
- Is: Assumed weekly spillover cases.
"""
function fit_renewal_equation_Rt_piecewise(Cs::Vector, Is::Vector, d::UnivariateAndOffset)
	T = length(Cs)
	λs = Vector{Float64}(undef, T)
	d_weekly_pdf = weekly_discretise_pdf(d)
	# Remove 1 for the inability to estimate Rt since gm is fixed at 1.
	for t in 2:T
		λs[t] = estimated_incidence_renewal(Cs[1:t], d_weekly_pdf)
	end
	Cs_local = Cs .- Is
	return sample(
		renewal_equation_Rt_piecewise(Cs_local[2:end], λs[2:end]),
		NUTS(), 1000, progress = false; initial_params = [1.0])
end

function create_RenewalRtHolder(ds::Vector, Cs::Vector, Is::Vector, d::UnivariateAndOffset)
	chn = fit_renewal_equation_Rt_piecewise(Cs, Is, d)
	return RenewalRtHolder(ds, Cs, Is, chn)
end

function estimate_multiple_RenewalRt(df_conf2023Sep, df_SK)
	RtHol_DRC2023Sep1 = @with df_conf2023Sep create_RenewalRtHolder(
		:xvalue, :new_confirmed_cases, :spillover, Valentina_wb_ser1)
	RtHol_DRC2023Sep1.dic |> display

	RtHol_DRC2023Sep2 = @with df_conf2023Sep create_RenewalRtHolder(
		:xvalue, :new_confirmed_cases, :spillover, Valentina_wb_ser2)
	RtHol_DRC2023Sep2.dic |> display

	df_SK.null .= 0
	RtHol_SK1 = @with df_SK create_RenewalRtHolder(
		:xvalue, :new_suspect_SK, :null, Valentina_wb_ser1)
	RtHol_SK1.dic |> display

	RtHol_SK2 = @with df_SK create_RenewalRtHolder(
		:xvalue, :new_suspect_SK, :null, Valentina_wb_ser2)
	RtHol_SK2.dic |> display
	return [RtHol_DRC2023Sep1, RtHol_DRC2023Sep2, RtHol_SK1, RtHol_SK2]
end

function merge_means_confs(RtHols::Vector{RenewalRtHolder})
	R_means = [RtHol.dic[:Rt_mlh][1] for RtHol in RtHols]
	R_confs = [RtHol.dic[:Rt_mlh][2:3] for RtHol in RtHols]
	return R_means, R_confs
end

function fetch_1st_date_of_month(df::DataFrame, xticks::Vector; col_date = :date)
	x_adjs = []
	labels = []
	for xtick in xticks
		date = df[xtick, col_date]
		st_date = Dates.firstdayofmonth(date)
		x_adj = df[xtick, :xvalue] - (date - st_date).value / 7
		label = Dates.format(st_date, "dd/mm")
		push!(labels, label)
		push!(x_adjs, x_adj)
	end
	return (x_adjs, labels)
end

function plot_epicurve_SK_DRC(
	df_DRC, df_SK, df_conf, df_conf2023, df_conf2023Sep,
	R_means, R_confs,
)
	# Panel A
	pl1 = plot(title = "DRC", ylabel = "incidence")
	xticks = [1, 10, 20, 30, 36, 46, 56, 66, 72, 82]
	xticks, xticks_label = fetch_1st_date_of_month(df_DRC, xticks)
	bar!(pl1, df_DRC.xvalue, df_DRC.new_suspect_DRC,
		xticks = (xticks, xticks_label), xlim = [0, 86],
		label = "suspected", color = 1)
	bar!(pl1, df_conf.xvalue, df_conf.new_confirmed_cases,
		label = "confirmed", color = 2)
	annotate!(pl1, (0.265, -0.22), text("2023", :left, font(10, "Helvetica")))
	annotate!(pl1, (0.82, -0.22), text("2024", :left, font(10, "Helvetica")))
	annotate!(pl1, (-0.05, 1.05), text("(A)", :left, font(12, "Helvetica")))

	# Panel B
	pl2 = plot(xlabel = "2023", title = "DRC (pre-clade Ib)", ylabel = "incidence"
	)
	xticks = [1, 15, 30, 40]
	xticks, xticks_label = fetch_1st_date_of_month(df_DRC, xticks)
	bar!(pl2, df_conf2023.xvalue, df_conf2023.new_confirmed_cases,
		xticks = (xticks, xticks_label),
		label = "confirmed", color = 2, legend = (0.1, 0.95))
	bar!(pl2, df_conf2023Sep.xvalue, df_conf2023Sep.spillover, color = 3, label = "assumed spillover")
	plot!(pl2, [35.5, 54], [0, 0], fillrange = [0, 0] .+ 80,
		label = false, color = :grey, alpha = 0.5)
	annotate!(pl2, (-0.05, 1.15), text("(B)", :left, font(12, "Helvetica")))

	# Panel C
	pl3 = plot(xlabel = "2024", title = "South Kivu (clade Ib)", ylabel = "incidence")
	xticks = [1, 10, 20, 30]
	xticks, xticks_label = fetch_1st_date_of_month(df_DRC, xticks)
	bar!(pl3, df_SK.xvalue, df_SK.new_suspect_SK,
		xticks = (xticks, xticks_label),
		label = "suspected", color = 1)
	annotate!(pl3, (-0.05, 1.12), text("(C)", :left, font(12, "Helvetica")))

	# Panel D
	pl4 = plot(xrotation = 90)
	xticks = ["pre-Ib 1", "pre-Ib 2", "SK 1", "SK 2"]
	plot!(pl4, [[x, x] for x in xticks], R_confs, color = 1, label = "", lw = 1.5)
	scatter!(pl4, xticks, R_means, label = "",
		xlabel = "", ylabel = "reproduction number", lw = 2, size = (200, 400),
		color = 1, markersize = 3.0, markerstrokewidth = 0.5, xlim = [0.0, 4.0], ylim = [0, 1.7])
	hline!(pl4, [1], ls = :dash, color = "black", label = "")
	annotate!(pl4, (-0.1, 1.125), text("(D)", :left, font(12, "Helvetica")))

	pl_space = plot(legend = false, grid = true, ticks = false, showaxis = true,
		foreground_color_subplot = :white)
	layout = @layout [a; b{0.02h}; c d e{0.15w}]
	pl = plot(pl1, pl_space, pl2, pl3, pl4, layout = layout, size = (800, 500),
		bottom_margin = 4Plots.mm, left_margin = 3Plots.mm, right_margin = 3Plots.mm,
		dpi = 300)
	display(pl)
end