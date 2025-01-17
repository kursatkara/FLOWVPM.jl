"""
# DESCRIPTION
    Implementation of the three-dimensional viscous Vortex Particle Method.

# AUTHORSHIP
  * Author    : Eduardo J. Alvarez
  * Email     : Edo.AlvarezR@gmail.com
  * Created   : 2019

# TODO
* [ ] Review time integration routines and SFS models to conform to new GE derivation.
* [ ] Remember to multiply SFS by p.sigma[1]^3/zeta0
* [ ] Save and read C for restart.
* [ ] Remove circulation property.
* [ ] Optimize creating of hdf5s to speed up simulations.
"""
module FLOWVPM

# ------------ GENERIC MODULES -------------------------------------------------
import HDF5
import JLD
import SpecialFunctions
import Dates
import Printf
import DataStructures: OrderedDict

# ------------ FLOW CODES ------------------------------------------------------
import FLOWExaFMM
const fmm = FLOWExaFMM

# ------------ GLOBAL VARIABLES ------------------------------------------------
const module_path = splitdir(@__FILE__)[1]      # Path to this module

# Determine the floating point precision of ExaFMM
const exafmm_single_precision = fmm.getPrecision()
const RealFMM = exafmm_single_precision ? Float32 : Float64

# ------------ HEADERS ---------------------------------------------------------
for header_name in ["kernel", "fmm", "viscous", "formulation",
                    "particle", "relaxation", "subfilterscale",
                    "particlefield",
                    "UJ", "subfilterscale_models", "timeintegration",
                    "monitors", "utils"]
    include(joinpath( module_path, "FLOWVPM_"*header_name*".jl" ))
end


# ------------ AVAILABLE SOLVER OPTIONS ----------------------------------------

# ------------ Available VPM formulations
const formulation_classic = ClassicVPM{RealFMM}()
const formulation_cVPM = ReformulatedVPM{RealFMM}(0, 0)
const formulation_rVPM = ReformulatedVPM{RealFMM}(0, 1/5)

const formulation_tube_continuity = ReformulatedVPM{RealFMM}(1/2, 0)
const formulation_tube_momentum = ReformulatedVPM{RealFMM}(1/4, 1/4)
const formulation_sphere_momentum = ReformulatedVPM{RealFMM}(0, 1/5 + 1e-8)

# Formulation aliases
const cVPM = formulation_cVPM
const rVPM = formulation_rVPM
const formulation_default = formulation_rVPM

const standard_formulations = ( :formulation_classic,
                                :formulation_cVPM, :formulation_rVPM,
                                :formulation_tube_continuity, :formulation_tube_momentum,
                                :formulation_sphere_momentum
                              )

# ------------ Available Kernels
const kernel_singular = Kernel(zeta_sing, g_sing, dgdr_sing, g_dgdr_sing, 1, 1)
const kernel_gaussian = Kernel(zeta_gaus, g_gaus, dgdr_gaus, g_dgdr_gaus, -1, 1)
const kernel_gaussianerf = Kernel(zeta_gauserf, g_gauserf, dgdr_gauserf, g_dgdr_gauserf, 5, 1)
const kernel_winckelmans = Kernel(zeta_wnklmns, g_wnklmns, dgdr_wnklmns, g_dgdr_wnklmns, 3, 1)
const kernel_default = kernel_gaussianerf

# Kernel aliases
const singular = kernel_singular
const gaussian = kernel_gaussian
const gaussianerf = kernel_gaussianerf
const winckelmans = kernel_winckelmans

const standard_kernels = (:singular, :gaussian, :gaussianerf, :winckelmans)


# ------------ Available relaxation schemes
const relaxation_none = Relaxation((args...; optargs...)->nothing, -1, RealFMM(0.0))
const relaxation_pedrizzetti = Relaxation(relax_pedrizzetti, 1, RealFMM(0.3))
const relaxation_correctedpedrizzetti = Relaxation(relax_correctedpedrizzetti, 1, RealFMM(0.3))

# Relaxation aliases
const pedrizzetti = relaxation_pedrizzetti
const correctedpedrizzetti = relaxation_correctedpedrizzetti
const norelaxation = relaxation_none
const relaxation_default = pedrizzetti

const standard_relaxations = (:norelaxation, :pedrizzetti, :correctedpedrizzetti)

# ------------ Subfilter-scale models
# SFS procedure aliases
const pseudo3level = dynamicprocedure_pseudo3level
const pseudo3level_positive(args...; optargs...) = pseudo3level(args...; force_positive=true, optargs...)
const sensorfunction = dynamicprocedure_sensorfunction

# SFS Schemes
const SFS_none = NoSFS{RealFMM}()
const SFS_Cs_nobackscatter = ConstantSFS(Estr_fmm; Cs=1.0, clippings=[clipping_backscatter])
const SFS_Cd_twolevel_nobackscatter = DynamicSFS(Estr_fmm, pseudo3level_positive; alpha=0.999, clippings=[clipping_backscatter])
const SFS_Cd_threelevel_nobackscatter = DynamicSFS(Estr_fmm, pseudo3level_positive; alpha=0.667, clippings=[clipping_backscatter])

# SFS aliases
const noSFS = SFS_none
const SFS_default = SFS_none

const standard_SFSs = (
                        :SFS_none, :SFS_Cs_nobackscatter,
                        # :SFS_Cd_twolevel_nobackscatter,
                        # :SFS_Cd_threelevel_nobackscatter
                        )

# ------------ Other default functions
const nofreestream(t) = zeros(3)
const Uinf_default = nofreestream
# const runtime_default(pfield, t, dt) = false
const monitor_enstrophy = monitor_enstrophy_Gammaomega
const runtime_default = monitor_enstrophy
const static_particles_default(pfield, t, dt) = nothing


# ------------ Compatibility between kernels and viscous schemes
const _kernel_compatibility = Dict( # Viscous scheme => kernels
        Inviscid.body.name      => [singular, gaussian, gaussianerf, winckelmans,
                                        kernel_singular, kernel_gaussian,
                                        kernel_gaussianerf, kernel_winckelmans],
        CoreSpreading.body.name => [gaussianerf, kernel_gaussianerf],
        ParticleStrengthExchange.body.name => [gaussianerf, winckelmans,
                                        kernel_gaussianerf, kernel_winckelmans],
    )


# ------------ INTERNAL DATA STRUCTURES ----------------------------------------

# Field inside the Particle type where the SFS contribution is stored (make sure
# this is consistent with ExaFMM and functions under FLOWVPM_subfilterscale.jl)
const _SFS = :Jexa

# ----- Instructions on how to save and print solver settings ------------------
# Settings that are functions
const _pfield_settings_functions = (:Uinf, :UJ, :integration, :kernel,
                                            :relaxation, :SFS, :viscous)

# Hash table between functions that are solver settings and their symbol
const _keys_standardfunctions = (:nofreestream, :UJ_direct, :UJ_fmm, :euler,
                                 :rungekutta3, standard_kernels...,
                                               standard_relaxations...,
                                               standard_SFSs...)
const _fun2key = Dict( (eval(sym), sym) for sym in _keys_standardfunctions )
const _key2fun = Dict( (sym, fun) for (fun, sym) in _fun2key )
const _standardfunctions = Tuple(keys(_fun2key))
const _key_userfun = Symbol("*userfunction")

# Hash table between standard options that are too lengthy to describe in print
const _keys_lengthyoptions = (standard_formulations..., standard_kernels...)
const _lengthy2key = Dict( (eval(sym), sym) for sym in _keys_lengthyoptions )
const _lengthyoptions = Tuple(keys(_lengthy2key))

# Relevant solver settings in a given particle field
const _pfield_settings = (sym for sym in fieldnames(ParticleField)
                          if !( sym in (:particles, :bodies, :np, :nt, :t, :M) )
                        )

# ------------------------------------------------------------------------------

end # END OF MODULE
