# f_fwhm(x, p) = sqrt.((x .* x .* p[3] .+ x .* p[2] .+ p[1]) .* heaviside.(x .* x .* p[3] .+ x .* p[2] .+ p[1]))
f_fwhm(x::T, p::AbstractArray{<:T}) where T<:Unitful.RealOrRealQuantity = sqrt((x * x * p[3] + x * p[2] + p[1]) * heaviside(x^2 * p[3] + x * p[2] + p[1]))
f_fwhm(x::Array{<:T}, p::AbstractArray{<:T}) where T<:Unitful.RealOrRealQuantity = Base.Fix2(f_fwhm, p).(x)
f_fwhm(x, p1, p2, p3) = f_fwhm(x, [p1, p2, p3])

"""
    fit_fwhm(peaks::Vector{<:Unitful.Energy{<:Real}}, fwhm::Vector{<:Unitful.Energy{<:Real}}; pol_order::Int=1, e_type_cal::Symbol=:e_cal, e_expression::Union{Symbol, String}="e", uncertainty::Bool=true, use_pull_t::Bool=false)
Fit the FWHM of the peaks to a quadratic function.

# Arguments
    * 'peaks': Energies that correspond to the peaks
    * 'fwhm': Full width at half max of peaks

# Keywords
    * 'pol_order': Polynomial order of function
    * 'e_type_cal': 
    * 'e_expression: Energy expression
    * 'uncertainty': Fit uncertainty

# Returns
    * `qbb`: the FWHM at 2039 keV
    * `err`: the uncertainties of the fit parameters
    * `v`: the fit result parameters
    * `f_fit`: the fitted function

TO DO: keyword descriptions.
"""
function fit_fwhm(peaks::Vector{<:Unitful.Energy{<:Real}}, fwhm::Vector{<:Unitful.Energy{<:Real}}; pol_order::Int=1, e_type_cal::Symbol=:e_cal, e_expression::Union{Symbol, String}="e", uncertainty::Bool=true, use_pull_t::Bool=false)
    @assert length(peaks) == length(fwhm) "Peaks and FWHM must have the same length"
    @assert pol_order >= 1 "The polynomial order must be greater than 0"
    # fit FWHM fit function
    e_unit = u"keV"
    p_start = append!([1, 2.96e-3*0.11], fill(0.0, pol_order-1)) .* [e_unit^i for i in pol_order:-1:0]
    pull_t = [if !use_pull_t NamedTuple() elseif i > 2 (mean = 0.0, std = 0.1*(2.96e-3*0.11)^i) else NamedTuple() end for i in 1:pol_order+1]

    # fit FWHM fit function as a square root of a polynomial
    result_chi2, report_chi2 = chi2fit(x -> LegendSpecFits.heaviside(x)*sqrt(abs(x)), pol_order, ustrip.(e_unit, peaks), ustrip.(e_unit, fwhm); v_init=ustrip.(p_start), uncertainty=uncertainty, pull_t=pull_t)
    
    # get pars and apply unit
    par =  result_chi2.par
    par_unit = par .* [e_unit^i for i in pol_order:-1:0]

    # built function in string
    func = "sqrt($(join(["$(mvalue(par[i])) * ($(e_expression))^$(i-1)" for i in eachindex(par)], " + ")))$e_unit"
    func_cal = "sqrt($(join(["$(mvalue(par[i])) * $(e_type_cal)^$(i-1) * keV^$(length(par)+1-i)" for i in eachindex(par)], " + ")))"
    func_generic = "sqrt($(join(["par[$(i-1)] * $(e_type_cal)^$(i-1)" for i in eachindex(par)], " + ")))"

    # get fwhm at Qbb 
    # Qbb from: https://www.researchgate.net/publication/253446083_Double-beta-decay_Q_values_of_74Se_and_76Ge
    qbb = report_chi2.f_fit(measurement(2039.061, 0.007)) * e_unit
    result = merge(result_chi2, (par = par_unit , qbb = qbb, func = func, func_cal = func_cal, func_generic = func_generic, peaks = peaks, fwhm = fwhm))
    report = merge(report_chi2, (e_unit = e_unit, par = result.par, qbb = result.qbb, type = :fwhm))

    return result, report
end
export fit_fwhm