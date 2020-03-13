# Read and properly scale phase
fn_phase = "data/small/Phase.nii"
phase_nii = readphase(fn_phase)
@test maximum(phase_nii) ≈ π atol=2e-3
@test minimum(phase_nii) ≈ -π atol=2e-3

# Read and normalize mag
fn_mag = "data/small/Mag.nii"
mag_nii = readmag(fn_mag; normalize=true)
@test 1 ≤ maximum(mag_nii) ≤ 2
@test 0 ≤ minimum(mag_nii) ≤ 1

# robust mask
mag = Float32.(readmag(fn_mag; normalize=true))
mag[(end÷2):end,:,:,:] .= 0.3rand.()
m = robustmask(mag)
@test 1.1 < count(.!m) / count(m) < 1.2

#TODO savenii

# close mmapped files
GC.gc()

@test estimatequantile(1:1000, 0.8) ≈ 800 atol=1

hdr = similar(mag_nii.header)
@test hdr.scl_inter == 0
@test hdr.scl_slope == 1
@test hdr.dim == mag_nii.header.dim
