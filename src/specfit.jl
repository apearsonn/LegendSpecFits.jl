# This file is a part of LegendSpecFits.jl, licensed under the MIT License (MIT).

"""
    fit_peaks(peakhists::Array, peakstats::StructArray, th228_lines::Vector; kwargs...)

Perform a fit of the peakshape to the data in `peakhists` using the initial values in `peakstats` to the calibration lines in `th228_lines`.

# Arguments
    * 'peakhists': Histogram of individual peaks
    * 'peakstats': Peak statistics
    * 'th228_lines': Calibration lines

# Returns
    * `peak_fit_plots`: array of plots of the peak fits
    * `return_vals`: dictionary of the fit results
"""
function fit_peaks(peakhists::Array, peakstats::StructArray, th228_lines::Vector; kwargs...)
    # remove calib type from kwargs
    @assert haskey(kwargs, :calib_type) "Calibration type not specified"
    calib_type = kwargs[:calib_type]
    # remove :calib_type from kwargs
    kwargs = pairs(NamedTuple(filter(k -> !(:calib_type in k), kwargs)))
    if calib_type == :th228
        return fit_peaks_th228(peakhists, peakstats, th228_lines,; kwargs...)
    else
        error("Calibration type not supported")
    end
end
export fit_peaks

"""
    fit_peaks_th228(peakhists::Array, peakstats::StructArray, th228_lines::Vector{T},; e_unit::Union{Nothing, Unitful.EnergyUnits}=nothing, uncertainty::Bool=true, low_e_tail::Bool=true, iterative_fit::Bool=false,
    fit_func::Symbol= :f_fit, pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true),  m_cal_simple::MaybeWithEnergyUnits = 1.0) where T<:Any

# Arguments
    * 'peakhists': Histogram of individual peaks
    * 'peakstats': Peak statistics
    * 'th228_lines': 
    
# Keywords
    * 'e_unit': energy unit
    * 'uncertainty': Uncertainty
    * 'low_e_tail': Low energy tail
    * 'iterative_fit': Iterative fit
    * 'fit_func': Fitted function
    * 'pseudo_prior': Pseudo prior
    * 'm_cal_simple': 

# Returns
    * 'Result':
    * 'Report':

TO DO: function description.
"""

function fit_peaks_th228(peakhists::Array, peakstats::StructArray, th228_lines::Vector{T},; e_unit::Union{Nothing, Unitful.EnergyUnits}=nothing, uncertainty::Bool=true, low_e_tail::Bool=true, iterative_fit::Bool=false,
    fit_func::Symbol= :f_fit, pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true),  m_cal_simple::MaybeWithEnergyUnits = 1.0) where T<:Any
    
    e_unit = ifelse(isnothing(e_unit), NoUnits, e_unit)

    # create return and result dicts
    v_result = Vector{NamedTuple}(undef, length(th228_lines))
    v_report = Vector{NamedTuple}(undef, length(th228_lines))


    # iterate throuh all peaks
    Threads.@threads for i in eachindex(th228_lines)
        # get histogram and peakstats
        peak = th228_lines[i]
        h  = peakhists[i]
        ps = peakstats[i]
        # fit peak
        result_peak, report_peak = fit_single_peak_th228(h, ps; uncertainty=uncertainty, low_e_tail=low_e_tail, fit_func = fit_func, pseudo_prior = pseudo_prior)

        # check covariance matrix for being semi positive definite (no negative uncertainties)
        if uncertainty
            if iterative_fit && !isposdef(result_peak.covmat)
                @warn "Covariance matrix not positive definite for peak $peak - repeat fit without low energy tail"
                pval_save = result_peak.pval
                result_peak, report_peak = fit_single_peak_th228(h, ps, ; uncertainty=uncertainty, low_e_tail=false, fit_func = fit_func, pseudo_prior = pseudo_prior)
                @info "New covariance matrix is positive definite: $(isposdef(result_peak.covmat))"
                @info "p-val with low-energy tail  p=$(round(pval_save,digits=5)) , without low-energy tail: p=$(round((result_peak.pval),digits=5))"
                end
        end
        # save results 
        keys_with_unit = [:μ, :σ, :fwhm, :centroid]
        result_peak = merge(result_peak, NamedTuple{Tuple(keys_with_unit)}([result_peak[k] .* e_unit ./ m_cal_simple for k in keys_with_unit]...))

        v_result[i] = result_peak
        v_report[i] = report_peak
    end

    # create return and result dicts
    result = Dict{T, NamedTuple}(th228_lines .=> v_result)
    report = Dict{T, NamedTuple}(th228_lines .=> v_report)

    return result, report
end


"""
    fit_single_peak_th228(h::Histogram, ps::NamedTuple{(:peak_pos, :peak_fwhm, :peak_sigma, :peak_counts, :mean_background, :mean_background_step, :mean_background_std), NTuple{7, T}}; 
    uncertainty::Bool=true, low_e_tail::Bool=true, fixed_position::Bool=false, pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true),
    fit_func::Symbol=:f_fit, background_center::Union{Real,Nothing} = ps.peak_pos, m_cal_simple::Real = 1.0) where T<:Real

Perform a fit of the peakshape to the data in `h` using the initial values in `ps` while using the `gamma_peakshape` with low-E tail.
Also, FWHM is calculated from the fitted peakshape with MC error propagation. The peak position can be fixed to the value in `ps` by setting `fixed_position=true`. If the low-E tail should not be fitted, it can be disabled by setting `low_e_tail=false`.

# Arguments
    * 'h': histogram data
    * 'ps': Peak statistics
    
# Keywords
    * 'uncertainty': Fit uncertainty
    * 'low_e_tail': Low energy tail
    * 'fixed_position': position of the peak is fixed
    * 'pseudo_prior': Pseudo prior of histogram
    * 'fit_func': Fitted function
    * 'background_center': Center of background fit curve
    * 'm_cal_simple':

# Returns
    * `result`: NamedTuple of the fit results containing values and errors
    * `report`: NamedTuple of the fit report which can be plotted

TO DO: argument descriptions
"""
function fit_single_peak_th228(h::Histogram, ps::NamedTuple{(:peak_pos, :peak_fwhm, :peak_sigma, :peak_counts, :mean_background, :mean_background_step, :mean_background_std), NTuple{7, T}}; 
    uncertainty::Bool=true, low_e_tail::Bool=true, fixed_position::Bool=false, pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true),
    fit_func::Symbol=:f_fit, background_center::Union{Real,Nothing} = ps.peak_pos, m_cal_simple::Real = 1.0) where T<:Real
    # create standard pseudo priors
    pseudo_prior = get_pseudo_prior(h, ps, fit_func; pseudo_prior = pseudo_prior, fixed_position = fixed_position, low_e_tail = low_e_tail)
    
    # transform back to frequency space
    f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

    # start values for MLE
    v_init = Vector(mean(f_trafo.target_dist))  

    # get fit function with background center
    fit_function = get_th228_fit_functions(; background_center = background_center)[fit_func]

    # create loglikehood function: f_loglike(v) that can be evaluated for any set of v (fit parameter)
    f_loglike = let f_fit = fit_function, h = h
        v -> hist_loglike(Base.Fix2(f_fit, v), h)
    end

    # MLE
    opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), v_init, LBFGS(), Optim.Options(iterations = 3000, callback=advanced_time_and_memory_control()), autodiff=:forward)
    converged = Optim.converged(opt_r)

    # best fit results
    v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))

    f_loglike_array = let f_fit=fit_function, h=h, v_keys = keys(pseudo_prior) #same loglikelihood function as f_loglike, but has array as input instead of NamedTuple
        v ->  - hist_loglike(x -> f_fit(x, NamedTuple{v_keys}(v)), h) 
    end

    if uncertainty && converged
        # Calculate the Hessian matrix using ForwardDiff
        H = ForwardDiff.hessian(f_loglike_array, tuple_to_array(v_ml))

        # Calculate the parameter covariance matrix
        param_covariance_raw = inv(H)
        param_covariance = nearestSPD(param_covariance_raw)
    
        # Extract the parameter uncertainties
        v_ml_err = array_to_tuple(sqrt.(abs.(diag(param_covariance))), v_ml)

        # calculate p-value
        pval, chi2, dof = p_value_poissonll(fit_function, h, v_ml) # based on likelihood ratio 

        # calculate normalized residuals
        residuals, residuals_norm, _, _ = get_residuals(fit_function, h, v_ml)

        # get fwhm of peak
        fwhm, fwhm_err = 
            try
                get_peak_fwhm_th228(v_ml, param_covariance)
            catch e
                get_peak_fwhm_th228(v_ml, v_ml_err)
            end

        @debug "Best Fit values"
        @debug "μ: $(v_ml.μ) ± $(v_ml_err.μ)"
        @debug "σ: $(v_ml.σ) ± $(v_ml_err.σ)"
        @debug "n: $(v_ml.n) ± $(v_ml_err.n)"
        @debug "p: $pval , chi2 = $(chi2) with $(dof) dof"
        @debug "FWHM: $(fwhm) ± $(fwhm_err)"
    
        result = merge(NamedTuple{keys(v_ml)}([measurement(v_ml[k], v_ml_err[k]) for k in keys(v_ml)]...),
                (fwhm = measurement(fwhm, fwhm_err), gof = (pvalue = pval, chi2 = chi2, dof = dof, covmat = param_covariance, converged = converged))
                )
        report = (
            v = v_ml,
            h = h,
            f_fit = x -> Base.Fix2(fit_function, result)(x),
            f_components = peakshape_components(fit_func, v_ml; background_center = background_center),
            gof = merge(result.gof, (residuals = residuals, residuals_norm = residuals_norm,))
        )
    else
        # get fwhm of peak
        fwhm, fwhm_err = get_peak_fwhm_th228(v_ml, v_ml, false)

        @debug "Best Fit values"
        @debug "μ: $(v_ml.μ)"
        @debug "σ: $(v_ml.σ)"
        @debug "n: $(v_ml.n)"
        @debug "FWHM: $(fwhm)"

        result = merge(NamedTuple{keys(v_ml)}([measurement(v_ml[k], NaN) for k in keys(v_ml)]...),
            (fwhm = measurement(fwhm, NaN), ), (gof = (converged = converged,),))
        report = (
            v = v_ml,
            h = h,
            f_fit = x -> Base.Fix2(fit_function, v_ml)(x),
            f_components = peakshape_components(fit_func, v_ml; background_center = background_center),
            gof = NamedTuple()
        )
    end

    # convert µ, centroid and sigma, fwhm back to [ADC]
    centroid = peak_centroid(result)/m_cal_simple
    result = merge(result, (µ = result.µ/m_cal_simple, fwhm = result.fwhm/m_cal_simple, σ = result.σ/m_cal_simple, centroid = centroid))
    return result, report
end
export fit_single_peak_th228

"""
    peak_centroid(v::NamedTuple)
Calculate centroid of gamma peak from fit parameters

# Arguments
    * 'v': Fit parameters

# Returns
    * 'centroid': Centroid of the gamma peak
"""
function peak_centroid(v::NamedTuple)
    centroid = v.μ - v.skew_fraction * (v.µ * v.skew_width)
    if haskey(v, :skew_fraction_highE)
        centroid += v.skew_fraction_highE * (v.µ * v.skew_width_highE)
    end
    return centroid
end
export peak_centroid

"""
    estimate_fwhm(v::NamedTuple)
Get the FWHM of a peak from the fit parameters.

# Arguments
    * 'v': Fit parameters

# Returns
    * `fwhm`: the FWHM of the peak
"""
function estimate_fwhm(v::NamedTuple)
    # get FWHM
    f_sigWithTail = Base.Fix2(get_th228_fit_functions().f_sigWithTail,v)
    try
        if v.skew_fraction <= 0.5
            half_max_sig = maximum(f_sigWithTail.(v.μ - v.σ:0.001:v.μ + v.σ))/2
            roots_low = find_zero(x -> f_sigWithTail(x) - half_max_sig, v.μ - v.σ, maxiter=100)
            roots_high = find_zero(x -> f_sigWithTail(x) - half_max_sig, v.μ + v.σ, maxiter=100)
            return roots_high - roots_low
        else
            e_low = v.μ * (1 - v.skew_width) 
            e_high = v.μ * (1 + v.skew_width)
            half_max_sig = maximum(f_sigWithTail.(e_low:0.001:e_high))/2
            roots_low = find_zero(x -> f_sigWithTail(x) - half_max_sig, e_low, maxiter=100)
            roots_high = find_zero(x -> f_sigWithTail(x) - half_max_sig, e_high, maxiter=100)
            return roots_high - roots_low
        end 
    catch e
        return NaN 
    end
end
"""
    get_peak_fwhm_th228(v_ml::NamedTuple, v_ml_err::Union{Matrix,NamedTuple}, uncertainty::Bool=true)
Get the FWHM of a peak from the fit parameters while performing a MC error propagation.

# Arguments
    * 'v_ml': Best fit parameters
    * 'v_ml_err': Best fit parameters error
    * 'uncertainty': Fit uncertainty
 
# Returns
    * `fwhm`: the FWHM of the peak
    * `fwhm_err`: FWHM error

"""
function get_peak_fwhm_th228(v_ml::NamedTuple, v_ml_err::Union{Matrix,NamedTuple}, uncertainty::Bool=true)
    # get fwhm for peak fit
    fwhm = estimate_fwhm(v_ml)
    if !uncertainty
        return fwhm, NaN
    end

    # get MC for FWHM err
    if isa(v_ml_err, Matrix)# use correlated fit parameter uncertainties 
        v_mc = get_mc_value_shapes(v_ml, v_ml_err, 10000)
    elseif isa(v_ml_err, NamedTuple) # use uncorrelated fit parameter uncertainties 
        v_mc = get_mc_value_shapes(v_ml, v_ml_err, 1000)
    end
    fwhm_mc = estimate_fwhm.(v_mc)
    fwhm_err = std(fwhm_mc[isfinite.(fwhm_mc)])
    return fwhm, fwhm_err
end
export get_peak_fwhm_th228



"""
    fit_subpeaks_th228(
    h_survived::Histogram, h_cut::Histogram, h_result; 
    uncertainty::Bool=false, low_e_tail::Bool=true, fix_σ::Bool = true, fix_skew_fraction::Bool = true, fix_skew_width::Bool = true, 
    pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true), fit_func::Symbol=:f_fit, background_center::Real = h_result.μ
)
    
Perform a simultaneous fit of two peaks (`h_survived` and `h_cut`) that together would form a histogram `h`, from which the result `h_result` was already determined using `fit_single_peak_th228`.
Also, FWHM is calculated from the fitted peakshape with MC error propagation. The peak position can be fixed to the value in `ps` by setting `fixed_position=true`. If the low-E tail should not be fitted, it can be disabled by setting `low_e_tail=false`.

# Arguments
    * 'h_survived': one peak that forms a histogram with another peak
    * 'h_cut': one peak that forms a histogram with another peak
    * 'h_result': 

# Keywords
    * 'uncertainty': Fit uncertainty
    * 'low_e_tail': Low energy tail
    * 'fix_σ': Fixed standard deviation
    * 'fix_skew_fraction': Fixed skew fraction
    * 'fix_skew_width': Fixed skew width
    * 'pseudo_prior': Histogram pseudo priors
    * 'fit_func': Fitted function
    * 'background_center': Center of background fit curve

# Returns
    * `result`: NamedTuple of the fit results containing values and errors, in particular the signal survival fraction `sf` and the background survival frachtion `bsf`.
    * `report`: NamedTuple of the fit report which can be plotted

TO DO: argument descriptions
"""
function fit_subpeaks_th228(
    h_survived::Histogram, h_cut::Histogram, h_result; 
    uncertainty::Bool=false, low_e_tail::Bool=true, fix_σ::Bool = true, fix_skew_fraction::Bool = true, fix_skew_width::Bool = true, 
    pseudo_prior::NamedTupleDist=NamedTupleDist(empty = true), fit_func::Symbol=:f_fit, background_center::Real = h_result.μ
)

    # create standard pseudo priors
    standard_pseudo_prior = let ps = h_result, ps_cut = estimate_single_peak_stats(h_cut), ps_survived = estimate_single_peak_stats(h_survived)
        NamedTupleDist(
            μ = ConstValueDist(mvalue(ps.μ)),
            σ_survived = ifelse(fix_σ, ConstValueDist(mvalue(ps.σ)), weibull_from_mx(mvalue(ps.σ), 2*mvalue(ps.σ))),
            σ_cut = ifelse(fix_σ, ConstValueDist(mvalue(ps.σ)), weibull_from_mx(mvalue(ps.σ), 2*mvalue(ps.σ))),
            n = ConstValueDist(mvalue(ps.n)),
            sf = Uniform(0,1), # signal survival fraction
            bsf = Uniform(0,1), # background survival fraction 
            sasf = Uniform(0,1), # step amplitude survival fraction
            step_amplitude = ConstValueDist(mvalue(ps.step_amplitude)),
            skew_fraction_survived = ifelse(low_e_tail, ifelse(fix_skew_fraction, ConstValueDist(mvalue(ps.skew_fraction)), truncated(weibull_from_mx(0.01, 0.05), 0.0, 0.1)), ConstValueDist(0.0)),
            skew_fraction_cut = ifelse(low_e_tail, ifelse(fix_skew_fraction, ConstValueDist(mvalue(ps.skew_fraction)), truncated(weibull_from_mx(0.01, 0.05), 0.0, 0.1)), ConstValueDist(0.0)),
            skew_width_survived = ifelse(low_e_tail, ifelse(fix_skew_width, mvalue(ps.skew_width), weibull_from_mx(0.001, 1e-2)), ConstValueDist(1.0)),
            skew_width_cut = ifelse(low_e_tail, ifelse(fix_skew_width, mvalue(ps.skew_width), weibull_from_mx(0.001, 1e-2)), ConstValueDist(1.0)),
            background = ConstValueDist(mvalue(ps.background))
        )
    end

    # get fit function with background center
    fit_function = get_th228_fit_functions(; background_center = background_center)[fit_func]

    # use standard priors in case of no overwrites given
    if !(:empty in keys(pseudo_prior))
        # check if input overwrite prior has the same fields as the standard prior set
        @assert all(f -> f in keys(standard_pseudo_prior), keys(pseudo_prior)) "Pseudo priors can only have $(keys(standard_pseudo_prior)) as fields."
        # replace standard priors with overwrites
        pseudo_prior = merge(standard_pseudo_prior, pseudo_prior)
    else
        # take standard priors as pseudo priors with overwrites
        pseudo_prior = standard_pseudo_prior    
    end

    # transform back to frequency space
    f_trafo = BAT.DistributionTransform(Normal, pseudo_prior)

    # start values for MLE
    v_init = Vector(mean(f_trafo.target_dist))

    # create loglikehood function: f_loglike(v) that can be evaluated for any set of v (fit parameter)
    f_loglike = let f_fit=fit_function, h_cut=h_cut, h_survived=h_survived
        v -> begin
            v_survived = (μ = v.μ, σ = v.σ_survived, n = v.n * v.sf, 
                step_amplitude = v.step_amplitude * v.sasf,
                skew_fraction = v.skew_fraction_survived,
                skew_width = v.skew_width_survived,
                background = v.background * v.bsf
            )
            v_cut = (μ = v.μ, σ = v.σ_cut, n = v.n * (1 - v.sf), 
                step_amplitude = v.step_amplitude * (1 - v.sasf),
                skew_fraction = v.skew_fraction_cut,
                skew_width = v.skew_width_cut,
                background = v.background * (1 - v.bsf)
            )
            hist_loglike(Base.Fix2(f_fit, v_survived), h_survived) + hist_loglike(Base.Fix2(f_fit, v_cut), h_cut)
        end
    end

    # MLE
    opt_r = optimize((-) ∘ f_loglike ∘ inverse(f_trafo), v_init, Optim.Options(time_limit = 60, iterations = 5000))
    converged = Optim.converged(opt_r)

    # best fit results
    v_ml = inverse(f_trafo)(Optim.minimizer(opt_r))
    
    v_ml_survived = (
        μ = v_ml.μ, 
        σ = v_ml.σ_survived, 
        n = v_ml.n * v_ml.sf, 
        step_amplitude = v_ml.step_amplitude * v_ml.sasf,
        skew_fraction = v_ml.skew_fraction_survived,
        skew_width = v_ml.skew_width_survived,
        background = v_ml.background * v_ml.bsf
    ) 
            
    v_ml_cut = (
        μ = v_ml.μ, 
        σ = v_ml.σ_cut, 
        n = v_ml.n * (1 - v_ml.sf), 
        step_amplitude = v_ml.step_amplitude * (1 - v_ml.sasf),
        skew_fraction = v_ml.skew_fraction_cut,
        skew_width = v_ml.skew_width_cut,
        background = v_ml.background * (1 - v_ml.bsf)
    )

    gof_survived = NamedTuple()
    gof_cut = NamedTuple()

    if uncertainty && converged

        f_loglike_array = let v_keys = keys(pseudo_prior)
            v ->  -f_loglike(NamedTuple{v_keys}(v))
        end

        # Calculate the Hessian matrix using ForwardDiff
        H = ForwardDiff.hessian(f_loglike_array, tuple_to_array(v_ml))

        # Calculate the parameter covariance matrix
        param_covariance_raw = inv(H)
        param_covariance = nearestSPD(param_covariance_raw)

        # Extract the parameter uncertainties
        v_ml_err = array_to_tuple(sqrt.(abs.(diag(param_covariance))), v_ml)
            
        # calculate all of this for each histogram individually
        gofs = [
            begin
                
            h_part = Dict("survived" => h_survived, "cut" => h_cut)[part]
            v_ml_part = Dict("survived" => v_ml_survived, "cut" => v_ml_cut)[part]
            
            # calculate p-value
            pval, chi2, dof = p_value_poissonll(fit_function, h_part, v_ml_part)
        
            # calculate normalized residuals
            residuals, residuals_norm, _, bin_centers = get_residuals(fit_function, h_part, v_ml_part)
                
            gof = (
                pvalue = pval, chi2 = chi2, dof = dof,
                covmat = param_covariance,
                residuals = residuals, residuals_norm = residuals_norm,
                bin_centers = bin_centers,
                converged = converged
            )
                    
            end for part in ("survived", "cut")
        ]
        # get gofs
        gof_survived, gof_cut = gofs

        # get fwhm of peak
        fwhm, fwhm_err = try
                get_peak_fwhm_th228(v_ml, param_covariance)
            catch e
                get_peak_fwhm_th228(v_ml, v_ml_err)
            end

        @debug "Best Fit values"
        @debug "SF: $(v_ml.sf) ± $(v_ml_err.sf)"
        @debug "BSF: $(v_ml.bsf) ± $(v_ml_err.bsf)"
        @debug "μ: $(v_ml.μ) ± $(v_ml_err.μ)"
        @debug "σ survived: $(v_ml.σ_survived) ± $(v_ml_err.σ_survived)"
        @debug "σ cut     : $(v_ml.σ_cut) ± $(v_ml_err.σ_cut)"

        result = merge(NamedTuple{keys(v_ml)}([measurement(v_ml[k], v_ml_err[k]) for k in keys(v_ml)]...),
                (fwhm = measurement(fwhm, fwhm_err),), #NamedTuple{(:gof_survived, :gof_cut)}(gofs))
                (gof = (converged = converged,
                    survived = (pvalue = gofs[1].pvalue, chi2 = gofs[1].chi2, dof = gofs[1].dof, covmat = gofs[1].covmat),
                    cut = (pvalue = gofs[2].pvalue, chi2 = gofs[2].chi2, dof = gofs[2].dof, covmat = gofs[2].covmat)
                ), ))
    else
        # get fwhm of peak
        fwhm, fwhm_err = get_peak_fwhm_th228(v_ml, v_ml, false)

        @debug "Best Fit values"
        @debug "SF: $(v_ml.sf)"
        @debug "BSF: $(v_ml.bsf)"
        @debug "μ: $(v_ml.μ)"
        @debug "σ survived: $(v_ml.σ_survived)"
        @debug "σ cut     : $(v_ml.σ_cut)"

        result = merge(NamedTuple{keys(v_ml)}([measurement(v_ml[k], NaN) for k in keys(v_ml)]...),
        (fwhm = measurement(fwhm, NaN), gof = (converged = converged, survived = NamedTuple(), cut = NamedTuple())))
    end

    report = (
        survived = (
            v = v_ml_survived,
            h = h_survived,
            f_fit = x -> Base.Fix2(fit_function, v_ml_survived)(x),
            f_components = peakshape_components(fit_func, v_ml_survived; background_center = background_center),
            gof = gof_survived
        ),
        cut = (
            v = v_ml_cut,
            h = h_cut,
            f_fit = x -> Base.Fix2(fit_function, v_ml_cut)(x),
            f_components = peakshape_components(fit_func, v_ml_cut; background_center = background_center),
            gof = gof_cut
        ),
        sf = result.sf,
        bsf = result.bsf
    )

    return result, report
end