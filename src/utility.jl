#TODO open not writable as standard
function readphase(fn; keyargs...)
    phase = niread(fn; keyargs...)
    minp, maxp = approxextrema(phase)
    phase.header.scl_slope = 2pi / (maxp - minp)
    phase.header.scl_inter = -pi - minp * phase.header.scl_slope
    if any(isnan.(phase.raw)) println("WARNING: there are NaNs in the image: $fn") end
    return phase
end

function readmag(fn; normalize=false, keyargs...)
    mag = niread(fn; keyargs...)
    if mag.header.scl_slope == 0 || normalize
        _, maxi = approxextrema(mag)
        mag.header.scl_slope = 1 / maxi
        mag.header.scl_inter = 0
    end
    if any(isnan.(mag.raw)) println("WARNING: there are NaNs in the image: $fn") end
    return mag
end

approxextrema(image::NIVolume) = image.raw[1:10:end] |> I -> (minimum(I), maximum(I)) # sample every tenth value

savenii(image, name, writedir::Nothing, header = nothing) = nothing
savenii(image, name, writedir::String, header = nothing) = savenii(image, @show joinpath(writedir, name * ".nii"); header = header)
function savenii(image, filepath; header = nothing)
    if typeof(image) <: BitArray
        image = UInt8.(image)
    end
    vol = NIVolume([h for h in [header] if h != nothing]..., image)
    niwrite(filepath, vol)
end

function createniiforwriting(im, name::AbstractString, writedir::AbstractString; datatype::DataType = Float64, header = NIVolume(zeros(datatype, 1)).header)
    if !occursin(r"\.nii$", name)
        name *= ".nii"
    end
    filepath = joinpath(writedir, name)
    createniiforwriting(im, filepath; datatype = datatype, header = header)
end

function createniiforwriting(im::AbstractArray, filepath::AbstractString; datatype::DataType = eltype(im), header = NIVolume(zeros(datatype, 1)).header)
    nii = createniiforwriting(size(im), filepath; datatype = datatype, header = header)
    nii .= im
end

createniiforwriting(sz::Tuple, filepath::AbstractString; datatype::DataType = Float64, header = NIVolume(zeros(datatype, 1)).header) = createniiforwriting([sz...], filepath; datatype = datatype, header = header)
function createniiforwriting(sz::AbstractVector{Int}, filepath::AbstractString; datatype::DataType = Float64, header = NIVolume(zeros(datatype, 1)).header)
    write_emptynii(sz, filepath, datatype = datatype, header = header)
    niread(filepath, mmap = true, write = true).raw
end

"""
    getHIP(mag, phase; echoes=[1,2])
return the hermitian inner product between the specified echoes.
"""
function getHIP(mag, phase; echoes=[1,2])
    e1, e2 = echoes
    compl = zeros(ComplexF64, size(mag)[1:3])
    for iCha in 1:size(mag, 5)
        compl .+= exp.(1.0im .* (phase[:,:,:,e2,iCha] .- phase[:,:,:,e1,iCha])) .* mag[:,:,:,e1,iCha] .* mag[:,:,:,e2,iCha]
    end
    compl
end


function robustmask!(image; maskedvalue = if eltype(image) <: AbstractFloat NaN else 0 end)
    image[.!getrobustmask(image)] .= maskedvalue
    image
end

function getrobustmask(weight)
    notnan = isfinite.(weight)
    mean1 = mean(weight[notnan])
    noisemask = weight .< mean1
    noisemean = mean(weight[noisemask])
    if !isfinite(noisemean) return ones(size(weight)) end

    signalmean = mean(weight[.!noisemask .& notnan])
    noise_σ = std(weight[noisemask])

    mask = weight .> noisemean + noise_σ
    #closing(mask) .& notnan
end

getcomplex(mag::NIVolume, phase::NIVolume) = getcomplex(mag.raw, phase.raw)
getcomplex(fnmag::AbstractString, fnphase::AbstractString) = getcomplex(niread(fnmag), niread(fnphase))

function getcomplex(mag, phase)
    higherdims = ones(Int, length(size(phase)) - 2)
    minp = minimum(phase[:,:,higherdims...])
    maxp = maximum(phase[:,:,higherdims...])

    mag .* exp.((2im * pi / (maxp - minp)) .* phase)
end

function readfromtextheader(filename, searchstring)
    for line in readlines(open(filename, "r"))
        if occursin(searchstring, line)
            # regex to search for "= " or ": " and return the following non-whitespace characters
            return match(r"(?<=(= |: ))(\S+)", line).match
        end
    end
end

# root sum of squares combination
RSS(mag; dim = ndims(mag)) = dropdims(.√sum(mag.^Float32(2); dims = dim); dims = dim)

function getscaledimage(array, div::Number, offset = 0, type::Symbol = :trans)
    array = reshape(array, size(array)[1:2]) # drops singleton dimensions
    scaled = if offset != 0
        (array .- offset) .* (1 / div) .+ 0.5
    else
        array .* (1 / div)
    end
    scaled[isnan.(scaled) .| (scaled .< 0)] .= 0
    scaled[scaled .> 1] .= 1
    if type == :trans
        scaled = reverse(permutedims(scaled, [2 1]); dims = 1)
    else
    end
    Gray.(scaled)
end

function getscaledimage(array, type::Symbol = :trans)
    scaled = robustrescale(array, 0, 1, threshold = true)
    getscaledimage(scaled, 1, 0, type)
end

robustrescale(array, newmin, newmax; threshold = false, mask = trues(size(array)), datatype = Float64) =
    robustrescale!(datatype.(array), newmin, newmax; threshold = threshold, mask = mask)

function robustrescale!(array, newmin, newmax; threshold = false, mask = trues(size(array)))
    array[isnan.(array)] .= minimum(array[.!isnan.(array)])
    q = [0.01, 0.99] # quantiles
    oldq = estimatequantile(array[mask], q)
    oldrange = (oldq[2] - oldq[1]) / (q[2] - q[1])
    oldmin = oldq[1] - q[1] * oldrange
    newrange = newmax - newmin

    array .= (array .- oldmin) .* (newrange / oldrange) .+ newmin

    if threshold
        array[array .< newmin] .= newmin
        array[array .> newmax] .= newmax
    end
    array
end

function estimatequantile(array, p)
    samples = 1e5
    step = ceil(Int, length(array) / samples)
    quantile(array[1:step:end], p)
end

function rescale(array, newmin, newmax; datatype = eltype(array))
    rescale!(datatype.(array), newmin, newmax)
end

function rescale!(array, newmin, newmax)
    oldmin, oldmax = approxextrema(array)
    factor = (newmax - newmin) / (oldmax - oldmin)
    array .= (array .- oldmin) .* factor .+ newmin
end

mmtovoxel(sizemm, nii::NIVolume) = mmtovoxel(sizemm, nii.header)
mmtovoxel(sizemm, header::NIfTI.NIfTI1Header) = mmtovoxel(sizemm, header.pixdim)
mmtovoxel(sizemm, pixdim) = sizemm ./ pixdim
