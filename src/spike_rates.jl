function ComputeSpikeRates(spike_times::Vector{Vector{Float64}},
                           time_windows::Union{AbstractMatrix, AbstractRange};
                           inclusive_edge::Symbol = :right)
    
    # Convert single vector to vector{vector}
    if spike_times isa Vector{Float64}
        spike_times = [spike_times]
    end 
    num_trials = length(spike_times)

    # Determine time windows/bin edges
    if time_windows isa AbstractMatrix
        if size(time_windows,2) > 2
            error("time_windows{AbstractMatrix} must be an Nx2 matrix")
        end

    elseif time_windows isa AbstractRange
        time_window_vec = collect(time_windows)
        time_windows = hcat(time_window_vec[1:end-1], time_window_vec[2:end])
    else
        error("Unsupported time_windows. Must be an AbstractMatrix (Nx2) or an AbstractRange")
    end
    num_periods = size(time_windows,1)

    # Compute durations ahead of time
    durations = mapslices(diff, time_windows, dims=2)
    
    # Iterate through each trial and compute rate in each period
    rate_output = fill(0.0, num_trials, num_periods)
    for t = 1:num_trials
        if all(isnan.(spike_times[t]))
            continue
        end
        @views for p = 1:num_periods
            if inclusive_edge == :right
                rate_output[t,p] = sum((spike_times[t] .> time_windows[p,1]) .& (spike_times[t] .<= time_windows[p,2])) / durations[p]
            elseif inclusive_edge == :left
                rate_output[t,p] = sum((spike_times[t] .>= time_windows[p,1]) .& (spike_times[t] .< time_windows[p,2])) / durations[p]
            end
        end
    end

    return rate_output
end

"""
### SmoothRates(spike_hist::Union{Matrix{<:Number}, Vector{<:Number}}; args...)
    
Takes a vector or matrix of numbers and smooths along the desired dimension. 
"""
function SmoothRates(spike_hist::Matrix{<:Real}; # Matrix version
                     method::Symbol = :gaussian,
                     windowsize::Int = 5,
                     gauss_lim::Int = 3,
                     dims::Int = 1)

    if !any(dims .== [1,2]) # Assert dimension for matrix
        error("dims must be equal to 1 or 2")
    end

    if method == :mean
        smoothed_hist = reduce(hcat, map(x -> _SmoothRatesMean(x, windowsize), eachslice(spike_hist, dims=dims)))
    elseif method == :median
        smoothed_hist = reduce(hcat, map(x -> _SmoothRatesMedian(x, windowsize), eachslice(spike_hist, dims=dims)))
    elseif method == :gaussian
        smoothed_hist = reduce(hcat, map(x -> _SmoothRatesGaussian(x, windowsize, gauss_lim), eachslice(spike_hist, dims=dims)))
    end

    if dims == 1 # Rotate to maintain input shape
        smoothed_hist = rotl90(smoothed_hist)
    end

    return smoothed_hist
end

# Vector version
function SmoothRates(spike_hist::Vector{<:Real};
                     method::Symbol = :gaussian,
                     windowsize::Int = 5,
                     gauss_lim::Union{Int, Float64} = 3)
    
    if method == :mean
        smoothed_hist = _SmoothRatesMean(spike_hist, windowsize)
    elseif method == :median
        smoothed_hist = _SmoothRatesMedian(spike_hist, windowsize)
    elseif method == :gaussian
        smoothed_hist = _SmoothRatesGaussian(spike_hist, windowsize, gauss_lim)
    end
    
    return smoothed_hist
end

### Core functions
function _SmoothRatesMean(spike_hist,
                          windowsize::Int = 5)
    
    # Calculate size of kernel
    half_win_idx = Int(floor(round(windowsize/2)))
    if half_win_idx == 0
        error("Window size $window_size is too small")
    end

    # Allocate output
    smoothed_hist = zeros(size(spike_hist))
    num_points = size(spike_hist,1)

    @views for i = axes(spike_hist,1)
        if i <= half_win_idx
            smoothed_hist[i] = mean(spike_hist[1:i+half_win_idx])
        elseif i > num_points - half_win_idx
            smoothed_hist[i] = mean(spike_hist[i-half_win_idx:end])
        else
            smoothed_hist[i] = mean(spike_hist[i-half_win_idx:i+half_win_idx])
        end
    end

    return smoothed_hist
end

function _SmoothRatesMedian(spike_hist, windowsize::Int = 5)

    # Calculate size of kernel
    half_win_idx = Int(floor(round(windowsize/2)))
    if half_win_idx == 0
        error("Window size $window_size is too small")
    end

    # Allocate output
    smoothed_hist = zeros(size(spike_hist))
    num_points = size(spike_hist,1)

    @views for i = axes(spike_hist,1)
        if i <= half_win_idx
            smoothed_hist[i] = median(spike_hist[1:i+half_win_idx])
        elseif i > num_points - half_win_idx
            smoothed_hist[i] = median(spike_hist[i-half_win_idx:end])
        else
            smoothed_hist[i] = median(spike_hist[i-half_win_idx:i+half_win_idx])
        end
    end

    return smoothed_hist
end

function _SmoothRatesGaussian(spike_hist, windowsize::Int = 5, gauss_lim::Union{Int, Float64} = 3)

    # Calculate size of kernel
    half_win_idx = Int(floor(round(windowsize/2)))
    if half_win_idx == 0
        error("Window size $window_size is too small")
    end

    # Allocate output
    smoothed_hist = zeros(size(spike_hist))
    num_points = size(spike_hist,1)

    # Create the smoothing kernel
    hw_x = LinRange(-gauss_lim,gauss_lim,(half_win_idx*2)+1)
    gauss_pdf = pdf.(Normal(0,1), hw_x)
    gauss_mult = gauss_pdf ./ sum(gauss_pdf) # Adjust for gauss_lim parameter where values don't necessarily sum to 1
    # Convolve
    @views for i = axes(spike_hist,1)
        if i <= half_win_idx # Partial left tail gauss - normalized by amount of gauss overlapping
            smoothed_hist[i] = sum(spike_hist[1:i+half_win_idx] .* gauss_mult[end-(half_win_idx+i-1):end]) * 1/sum(gauss_mult[end-(half_win_idx+i-1):end])
        elseif i > num_points - half_win_idx # Partial right tail gauss - normalized by amount of gauss overlapping
            smoothed_hist[i] = sum(spike_hist[i-half_win_idx:end] .* gauss_mult[1:num_points - i + half_win_idx + 1]) * 1/sum(gauss_mult[1:num_points - i + half_win_idx + 1])
        else # Full gauss
            smoothed_hist[i] = sum(spike_hist[i-half_win_idx:i+half_win_idx] .* gauss_mult)
        end
    end

    return smoothed_hist
end