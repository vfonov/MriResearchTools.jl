
function robustmask!(image; maskedvalue=if eltype(image) <: AbstractFloat NaN else 0 end)
    image[.!robustmask(image)] .= maskedvalue
    image
end

function robustmask(weight::AbstractArray, threshold=nothing)
    if threshold isa Nothing
        μ, σ = estimatenoise(weight)
        m = mean(filter(isfinite, weight[weight .> 5σ]))
        threshold = maximum((5σ, m/5))
    end
    mask = weight .> threshold
    # remove small holes and minimally grow
    boxsizes=[[5] for i in 1:ndims(weight)]
    mask = gaussiansmooth3d(mask; nbox=1, boxsizes) .> 0.4
    mask = fill_holes(mask)
    mask = gaussiansmooth3d(mask; nbox=1, boxsizes) .> 0.6
    return mask
end

"""
    robustmask(weight::AbstractArray)

Creates a mask from a intensity/weights images.
It assumes that at least one corner is without signal and only contains noise.

# Examples
```julia-repl
julia> mask1 = robustmask(mag); # Using magnitude
julia> mask2 = robustmask(phase_based_mask(phase)); # Using phase
julia> mask3 = robustmask(romeovoxelquality(phase; mag)); # Using magnitude and phase
```

See also [`romeovoxelquality`](@ref), [`phase_based_mask`](@ref), [`brain_mask`](@ref)
"""
robustmask, robustmask!

function sphere(radius, dim=3)
    len = 2radius + 1
    arr = OffsetArray(falses(repeat([len], dim)...), repeat([-radius:radius], dim)...)
    for I in CartesianIndices(arr)
        arr[I] = sqrt(sum(Tuple(I).^2)) < radius
    end
    return arr
end

"""
    phase_based_mask(phase, mask=trues(size(phase)))

Creates a mask from a phase image.
Filtering is required afterwards (morphological or smoothing+thresholding)

# Examples
```julia-repl
julia> phase_mask = phase_based_mask(phase);
julia> clean_mask = robustmask(phase_mask);
```

See also [`romeovoxelquality`](@ref), [`romeo`](@ref), [`robustmask`](@ref), [`brain_mask`](@ref)

Original MATLAB algorithm:
    se=strel('sphere',6);
    L=del2(sign(wr));
    test=convn(abs(L),se.Neighborhood,'same');
    PB=mask{1}.*(test<500);
    PB=imclose(PB,se);
    mask{2}=round(imopen(PB,se));
"""
function phase_based_mask(phase)
    laplacian = imfilter(sign.(phase), Kernel.Laplacian(1:ndims(phase), ndims(phase)))
    test = imfilter(abs.(laplacian), sphere(6, ndims(phase)))
    return test .< (500 * 6)
end

function imclose(image, strel)
    image = extreme_filter(max, image, strel)
    return extreme_filter(min, image, strel)
end

function imopen(image, strel)
    image = extreme_filter(min, image, strel)
    return extreme_filter(max, image, strel)
end


"""
    mask_from_voxelquality(qmap::AbstractArray, threshold=:auto)

Creates a mask from a quality map. Another option is to use `robustmask(qmap)`

# Examples
```julia-repl
julia> qmap = romeovoxelquality(phase_3echo; TEs=[1,2,3]);
julia> mask = mask_from_voxelquality(qmap);
```

See also [`romeovoxelquality`](@ref), [`romeo`](@ref), [`robustmask`](@ref), [`brain_mask`](@ref)
"""
function mask_from_voxelquality(args...)
    return robustmask(args...)
end

function fill_holes(mask; max_hole_size=length(mask) / 20)
    return .!imfill(.!mask, (1, max_hole_size)) # fills all holes up to max_hole_size (uses 6 connectivity as default for 3D)
end

function get_largest_connected_region(mask)
    labels = label_components(mask)
    return labels .== argmax(countmap(labels[labels .!= 0]))
end

"""
    brain_mask(mask)

Tries to extract the brain from a mask with skull and a gap between brain and skull.

# Examples
```julia-repl
julia> mask = robustmask(mag)
julia> brain = brain_mask(mask)
```

See also [`robustmask`](@ref), [`romeovoxelquality`](@ref), [`phase_based_mask`](@ref)
"""
function brain_mask(mask)
    # set border to false
    shrink_mask = copy(mask)
    if ndims(shrink_mask) == 3 && all(size(shrink_mask) .> 5)
        shrink_mask[:,:,[1,end]] .= false
        shrink_mask[[1,end],:,:] .= false
        shrink_mask[:,[1,end],:] .= false
    end

    boxsizes=[[7] for i in 1:ndims(shrink_mask)]
    smooth = gaussiansmooth3d(shrink_mask; nbox=1, boxsizes)
    shrink_mask2 = smooth .> 0.7

    brain_mask = get_largest_connected_region(shrink_mask2)

    # grow brain mask
    boxsizes=[[7,7] for i in 1:ndims(shrink_mask2)]
    smooth = gaussiansmooth3d(brain_mask; nbox=2, boxsizes)
    brain_mask = smooth .> 0.2
    return brain_mask .&& mask
end