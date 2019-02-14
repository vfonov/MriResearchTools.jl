using Statistics

const SIGMA_IN_MM = 7

# make other input types possible
makehomogeneous(mag::NIVolume, datatype = eltype(mag); keyargs...) = makehomogeneous!(datatype.(mag); pixdim = mag.header.pixdim[2:(1+ndims(mag))])
makehomogeneous(mag, datatype = eltype(mag); keyargs...) = makehomogeneous!(datatype.(mag); keyargs...)
makehomogeneous!(mag::NIVolume) = makehomogeneous!(mag; pixdim = mag.header.pixdim[2:(1+ndims(mag))])

function getsigma(pixdim)
    factorfinalsmoothing = 0.7
    σ = SIGMA_IN_MM ./ pixdim
    σ1 = sqrt(1 - factorfinalsmoothing^2) .* σ
    σ2 = factorfinalsmoothing .* σ
    return σ1, σ2
end

function makehomogeneous!(mag; pixdim = ones(ndims(mag)), maxIteration = 10)
    σ1, σ2 = getsigma(pixdim)

    firstecho = view(mag,:,:,:,1)
    mask = getrobustmask(firstecho)
    #savenii(mask, "/data/korbi/data/julia/SWI_KREK/mask.nii")

    lowpass = gaussiansmooth3d(firstecho, σ)
    #savenii(lowpass, "/data/korbi/data/julia/SWI_KREK/lowpass1.nii")
    segmentation = boxsegment(firstecho ./ lowpass, mask)
    #savenii(segmentation, "/data/korbi/data/julia/SWI_KREK/segmentation.nii")


    lowpass = iterative(firstecho, mask, segmentation, σ1, maxIteration)
    #savenii(lowpass, "/data/korbi/data/julia/SWI_KREK/lowpassIt.nii")

    fillandsmooth!(lowpass, mean(firstecho[mask]), σ2)
    #savenii(lowpass, "/data/korbi/data/julia/SWI_KREK/lowpass2.nii")

    if eltype(mag) <: AbstractFloat
        mag ./= lowpass
    else # Integer
        lowpass[isnan.(lowpass) .| (lowpass .<= 0)] .= typemax(eltype(lowpass))
        mag .= div.(mag, lowpass ./ 2048) .|> x -> min(x, typemax(eltype(mag)))
    end
    mag
end

function fillandsmooth!(lowpass, stablemean, σ2)
    stablethresh = stablemean / 4
    lowpassmask = (lowpass .< stablethresh) .| isnan.(lowpass) .| (lowpass .> 10 * stablemean)
    lowpass[lowpassmask] .= 3 * stablemean
    lowpassweight = 1.2 .- lowpassmask
    gaussiansmooth3d!(lowpass, σ2; weight = lowpassweight)
end

function threshold(image, mask; lowthresh = 0.95)
    masked = image[mask]
    masked[isnan.(masked)] .= 0

    m = mean(masked)
    m = mean(masked[(masked .> m) .& (masked .< 2m)])

    wm_mask = falses(size(mask))
    wm_mask[(lowthresh * m .< image .< 1.5m) .& mask] .= true

    wm_mask
end

threshold(image) = threshold(image, getrobustmask(image))

function iterative(firstecho, mask, segmentation, sigma, maxIteration)
    local lowpass
    local wm_mask = segmentation
    for i in 1:maxIteration
        lowpass = gaussiansmooth3d(firstecho, sigma; mask = wm_mask, nbox = 8)#ifelse(stop == 0, 4, 8))
        highpass = firstecho ./ lowpass
        highpass[.!isfinite.(highpass)] .= 0

        new_mask = threshold(highpass, mask; lowThresh = 0.99)

        if i > 1
            @show change = sum(new_mask .!= wm_mask) / length(wm_mask)
            if change < 0.01 break end
        end
        wm_mask = new_mask
    end
    lowpass
end

function boxsegment!(image::AbstractArray{T,3}, mask; nboxes = 15) where T <: AbstractFloat
    image[boxsegment(image, mask; nboxes = nboxes)] .= NaN
    image
end

# TODO check if inside box is only noise -> no pre mask required (std < 2 * mean ?)
function boxsegment(image, mask; nboxes = 20)
    N = size(image)
    boxsize = round.(Int, N ./ nboxes)
    boxshift = ceil.(Int, boxsize ./ 2)
    segmented = copy(mask) #TODO: sure this is a good initialization value?
    for t in Iterators.product([1:boxshift[i]:N[i] for i in 1:3]...)
        I = CartesianIndices( ntuple(d -> t[d]:min(t[d] + boxsize[d] - 1, N[d]), 3) )

        segmented[I] = segmented[I] .& threshold(image[I], mask[I])
    end
    segmented
end