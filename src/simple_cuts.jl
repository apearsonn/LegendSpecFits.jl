
"""
    cut_single_peak(x::Vector{<:Unitful.RealOrRealQuantity}, min_x::T, max_x::T,; n_bins::Int=-1, relative_cut::Float64=0.5) where T<:Unitful.RealOrRealQuantity

Cut out a single peak from the array `x` between `min_x` and `max_x`.
The number of bins is the number of bins to use for the histogram.
The relative cut is the fraction of the maximum counts to use for the cut.

# Arguments
    * 'x': array of x-values
    * 'min_x': minimum x value
    * 'max_x': maximum x value
    
# Keywords
    * 'n_bins': number of bins to use in histogram
    * 'relative_cut': fraction of the maximum counts to use for the cut

# Returns 
    * `max`: maximum position of the peak
    * `low`: lower edge of the cut peak
    * `high`: upper edge of the cut peak
"""
function cut_single_peak(x::Vector{<:Unitful.RealOrRealQuantity}, min_x::T, max_x::T,; n_bins::Int=-1, relative_cut::Float64=0.5) where T<:Unitful.RealOrRealQuantity
    @assert unit(min_x) == unit(max_x) == unit(x[1]) "Units of min_x, max_x and x must be the same"
    x_unit = unit(x[1])
    x, min_x, max_x = ustrip.(x), ustrip(min_x), ustrip(max_x)

    # cut out window of interest
    x = x[(x .> min_x) .&& (x .< max_x)]
    # fit histogram
    if n_bins < 0
        bin_width = get_friedman_diaconis_bin_width(x)
        h = fit(Histogram, x, minimum(x):bin_width:maximum(x))
    else
        h = fit(Histogram, x, nbins=n_bins)
    end
    # find peak
    cts_argmax = mapslices(argmax, h.weights, dims=1)[1]
    cts_max    = h.weights[cts_argmax]

    # find left and right edge of peak
    cut_low_arg  = findfirst(w -> w >= relative_cut*cts_max, h.weights[1:cts_argmax])
    cut_high_arg = findfirst(w -> w <= relative_cut*cts_max, h.weights[cts_argmax:end]) + cts_argmax - 1
    cut_low, cut_high, cut_max = Array(h.edges[1])[cut_low_arg] * x_unit, Array(h.edges[1])[cut_high_arg] * x_unit, Array(h.edges[1])[cts_argmax] * x_unit
    @debug "Cut window: [$cut_low, $cut_high]"
    return (low = cut_low, high = cut_high, max = cut_max)
end
export cut_single_peak


"""
    get_centered_gaussian_window_cut(x::Vector{T}, min_x::T, max_x::T, n_σ::Real,; center::T=zero(x[1]), n_bins_cut::Int=500, relative_cut::Float64=0.2, left::Bool=false, fixed_center::Bool=true) where T<:Unitful.RealOrRealQuantity
Cut out a single peak from the array `x` between `min_x` and `max_x` by fitting a truncated one-sided Gaussian and extrapolating a window cut with `n_σ` standard deviations.
The `center` and side of the fit can be specified with `left` and `center` variable.

# Arguments
    * 'x': array of x values
    * 'min_x': minimum x value
    * 'max_x': maximum x value
    * 'n_σ': number of standard deviations
    
# Keywords
    * 'center': center of fit
    * 'n_bins_cut': Number of bins cut
    * 'relative_cut': 
    * 'left': Left side of fit
    * 'fixed_center': Center of fit is fixed

# Returns
    * `low_cut`: lower edge of the cut peak
    * `high_cut`: upper edge of the cut peak
    * `center`: center of the peak
    * `σ`: standard deviation of the Gaussian
    * `low_cut_fit`: lower edge of the cut peak from the fit
    * `high_cut_fit`: upper edge of the cut peak from the fit
    * 'max_cut_fit': 
    * `err`: error of the fit parameters
    * 'f_fit': Function fit
    * 'x_fit':
    * 'h': Histogram data

TO DO: return and keyword descriptions.
"""
function get_centered_gaussian_window_cut(x::Vector{T}, min_x::T, max_x::T, n_σ::Real,; center::T=zero(x[1]), n_bins_cut::Int=500, relative_cut::Float64=0.2, left::Bool=false, fixed_center::Bool=true) where T<:Unitful.RealOrRealQuantity
    @assert unit(min_x) == unit(max_x) == unit(x[1]) "Units of min_x, max_x and x must be the same"
    # prepare data
    x_unit = unit(x[1])
    x, min_x, max_x, center = ustrip.(x), ustrip(min_x), ustrip(max_x), ustrip(center)

    # get cut window around peak
    cuts = cut_single_peak(x, min_x, max_x,; n_bins=n_bins_cut, relative_cut=relative_cut)

    # fit half centered gaussian to define sigma width
    if !fixed_center
        result_fit, report_fit = fit_half_trunc_gauss(x, cuts,; left=left)
    else
        result_fit, report_fit = fit_half_centered_trunc_gauss(x, center, cuts,; left=left)
    end

    # get bin width
    bin_width = get_friedman_diaconis_bin_width(x[x .> result_fit.μ - 0.5*result_fit.σ .&& x .< result_fit.μ + 0.5*result_fit.σ])
    # prepare histogram
    h = fit(Histogram, x, mvalue(result_fit.μ-5*result_fit.σ):mvalue(bin_width):mvalue(result_fit.μ+5*result_fit.σ))
    # norm fitted distribution for better plotting
    # n_fit = length(x[ifelse(left, cuts.low, result_fit.μ) .< x .< ifelse(left, result_fit.μ, cuts.high)])
    # n_fit = length(x)
    # x_fit = ifelse(left, cuts.low:(result_fit.μ-cuts.low)/1000:result_fit.μ, result_fit.μ:(cuts.high-result_fit.μ)/1000:cuts.high)
    # pdf_norm = n_fit / sum(report_fit.f_fit.(x_fit))

    result = (
        low_cut  = (result_fit.μ - n_σ*result_fit.σ)*x_unit,
        high_cut = (result_fit.μ + n_σ*result_fit.σ)*x_unit,
        center  = result_fit.μ*x_unit,
        σ       = result_fit.σ*x_unit,
        low_cut_fit = ifelse(left, cuts.low, result_fit.μ), 
        high_cut_fit = ifelse(left, result_fit.μ, cuts.high),
        max_cut_fit = cuts.max
    )
    report = (
        h = LinearAlgebra.normalize(h, mode=:pdf),
        f_fit = t -> report_fit.f_fit(t),
        x_fit = ifelse(left, cuts.low:mvalue(result_fit.μ-cuts.low)/1000:mvalue(result_fit.μ), mvalue(result_fit.μ):mvalue(cuts.high-result_fit.μ)/1000:cuts.high),
        low_cut = result.low_cut,
        high_cut = result.high_cut,
        low_cut_fit = result.low_cut_fit,
        high_cut_fit = result.high_cut_fit,
        center = result.center,
        σ = result.σ,
    )
    return result, report
end
export get_centered_gaussian_window_cut
