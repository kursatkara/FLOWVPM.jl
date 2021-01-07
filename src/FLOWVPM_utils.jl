#=##############################################################################
# DESCRIPTION
    Utilities

# AUTHORSHIP
  * Author    : Eduardo J Alvarez
  * Email     : Edo.AlvarezR@gmail.com
  * Created   : Aug 2020
  * Copyright : Eduardo J Alvarez. All rights reserved.
=###############################################################################



"""
  `run_vpm!(pfield, dt, nsteps; runtime_function=nothing, save_path=nothing,
run_name="pfield", nsteps_save=1, verbose=true, prompt=true)`

Solves `nsteps` of the particle field with a time step of `dt`.

**Optional Arguments**
* `runtime_function::Function`   : Give it a function of the form
                            `myfun(pfield, t, dt)`. On each time step it
                            will call this function. Use this for adding
                            particles, deleting particles, etc.
* `static_particles_function::Function`   : Give it a function of the form
                            `myfun(pfield, t, dt)` to add static particles
                            representing solid boundaries to the solver. This
                            function is called at every time step right before
                            solving the governing equations, and any new
                            particles added by this function are immediately
                            removed.
* `nsteps_relax::Int`   : Relaxes the particle field every this many time steps.
* `save_path::String`   : Give it a string for saving VTKs of the particle
                            field. Creates the given path.
* `run_name::String`    : Name of output files.
* `nsteps_save::Int64`  : Saves vtks every this many time steps.
* `prompt::Bool`        : If `save_path` already exist, it will prompt the
                            user before overwritting the folder if true; it will
                            directly overwrite it if false.
* `verbose::Bool`       : Prints progress of the run to the terminal.
* `verbose_nsteps::Bool`: Number of time steps between verbose.
"""
function run_vpm!(pfield::ParticleField, dt::Real, nsteps::Int;
                      # RUNTIME OPTIONS
                      runtime_function::Function=runtime_default,
                      static_particles_function::Function=static_particles_default,
                      nsteps_relax::Int64=-1,
                      # OUTPUT OPTIONS
                      save_path::Union{Nothing, String}=nothing,
                      create_savepath::Bool=true,
                      run_name::String="pfield",
                      save_code::String="",
                      save_static_particles::Bool=true,
                      nsteps_save::Int=1, prompt::Bool=true,
                      verbose::Bool=true, verbose_nsteps::Int=10, v_lvl::Int=0,
                      save_time=true)

    # ERROR CASES
    ## Check that viscous scheme and kernel are compatible
    compatible_kernels = _kernel_compatibility[typeof(pfield.viscous).name]

    if !(pfield.kernel in compatible_kernels)
        error("Kernel $(pfield.kernel) is not compatible with viscous scheme"*
                " $(typeof(pfield.viscous).name); compatible kernels are"*
                " $(compatible_kernels)")
    end

    if save_path!=nothing
        # Create save path
        if create_savepath; create_path(save_path, prompt); end;

        # Save code
        if save_code!=""; cp(save_code, save_path*"/"; force=true); end;

        # Save settings
        save_settings(pfield, run_name; path=save_path)
    end

    # Initialize verbose
    (line1, line2, run_id, file_verbose,
        vprintln, time_beg) = initialize_verbose(   verbose, save_path, run_name, pfield,
                                                    nsteps_relax, runtime_function,
                                                    static_particles_function, v_lvl)

    # RUN
    for i in 0:nsteps

        if i%verbose_nsteps==0
            vprintln("Time step $i out of $nsteps\tParticles: $(get_np(pfield))", v_lvl+1)
        end

        # Relaxation step
        relax = pfield.relax && (nsteps_relax>=1 && i>0 && i%nsteps_relax==0)

        org_np = get_np(pfield)

        # Time step
        if i!=0
            # Add static particles
            static_particles_function(pfield, pfield.t, dt)

            # Step in time solving governing equations
            nextstep(pfield, dt; relax=relax)

            # Remove static particles (assumes particles remained sorted)
            if save_static_particles==false
                for pi in get_np(pfield):-1:(org_np+1)
                    remove_particle(pfield, pi)
                end
            end
        end

        # Save particle field
        if save_path!=nothing && (i%nsteps_save==0 || i==nsteps || breakflag)
            overwrite_time = save_time ? nothing : pfield.nt
            save(pfield, run_name; path=save_path, add_num=true,
                                        overwrite_time=overwrite_time)
        end

        if i!=0 && save_static_particles==true
            for pi in get_np(pfield):-1:(org_np+1)
                remove_particle(pfield, pi)
            end
        end

        # Calls user-defined runtime function
        breakflag = runtime_function(pfield, pfield.t, dt)

        # User-indicated end of simulation
        if breakflag
            break
        end

    end

    # Finalize verbose
    finalize_verbose(time_beg, line1, vprintln, run_id, v_lvl)

    return nothing
end


"""
  `save(pfield, file_name; path="")`

Saves the particle field in HDF5 format and a XDMF file especifying its the
attributes. This format can be opened in Paraview for post-processing and
visualization.
"""
function save(self::ParticleField, file_name::String; path::String="",
                add_num::Bool=true, num::Int64=-1, createpath::Bool=false,
                overwrite_time=nothing)

    # Save a field with one dummy particle if field is empty
    if get_np(self)==0
        dummy_pfield = ParticleField(1; nt=self.nt, t=self.t,
                                            formulation=formulation_classic)
        add_particle(dummy_pfield, (0,0,0), (0,0,0), 0)
        return save(dummy_pfield, file_name;
                    path=path, add_num=add_num, num=num, createpath=createpath,
                    overwrite_time=overwrite_time)
    end

    if createpath; create_path(path, true); end;

    fname = file_name*(add_num ? num==-1 ? ".$(self.nt)" : ".$num" : "")
    h5fname = fname*".h5"
    np = get_np(self)

    time = overwrite_time != nothing ? overwrite_time :
            typeof(self.t) in [Float64, Int64] ? self.t :
            self.t.value

    # Creates/overwrites HDF5 file
    h5 = HDF5.h5open(joinpath(path, h5fname), "w")

    # Writes parameters
    h5["np"] = np
    h5["nt"] = self.nt
    h5["t"] = time

    # Writes fields
    # NOTE: It is very inefficient to convert the data structure to a matrices
    # like this. This could help to make it more efficient: https://stackoverflow.com/questions/58983994/save-array-of-arrays-hdf5-julia
    h5["X"] = [P.X[i] for i in 1:3, P in iterate(self)]
    h5["Gamma"] = [P.Gamma[i] for i in 1:3, P in iterate(self)]
    h5["sigma"] = [P.sigma[1] for P in iterate(self)]
    h5["circulation"] = [P.circulation[1] for P in iterate(self)]
    h5["vol"] = [P.vol[1] for P in iterate(self)]
    h5["i"] = [P.index[1] for P in iterate(self)]

    # Connectivity information
    h5["connectivity"] = [i%3!=0 ? 1 : Int(i/3)-1 for i in 1:3*np]

    # # Write fields
    # dtype = HDF5.datatype(T)
    #
    # for (field, dim) in [("X", 3), ("Gamma", 3), ("sigma", 1)] # Iterate over fields
    #
    #     dims = dim==1 && false ? HDF5.dataspace(np) : HDF5.dataspace(dim, np)
    #     chunk = dim==1 && false ? (np,) : (1, np)
    #     dset = HDF5.d_create(h5, field, dtype, dims, "chunk", chunk)
    #
    #     for (pi, P) in enumerate(iterator(self))
    #         dset[:, pi] .= getproperty(P, Symbol(field))
    #     end
    #
    # end

    # # Connectivity information
    # dtype = HDF5.datatype(Int)
    # dims = HDF5.dataspace(3*np, 1)
    # chunk = (np, 1)
    # dset = HDF5.d_create(h5, "connectivity", dtype, dims, "chunk", chunk)
    # for i in 1:np
    #     dset[3*(i-1)+1, 1] = 1
    #     dset[3*(i-1)+2, 1] = 1
    #     dset[3*(i-1)+3, 1] = i-1
    # end

    close(h5)

    # Generates XDMF file specifying fields for paraview
    xmf = open(joinpath(path, fname*".xmf"), "w")

    # Open xmf block
    print(xmf, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
    print(xmf, "<Xdmf xmlns:xi=\"http://www.w3.org/2001/XInclude\" Version=\"3.0\">\n")
        print(xmf, "\t<Domain>\n")
          print(xmf, "\t\t<Grid GridType=\"Collection\" CollectionType=\"Temporal\">\n")
            print(xmf, "\t\t\t<Grid Name=\"particles\">\n")

        			  print(xmf, "\t\t\t\t<Time Value=\"", time, "\" />\n")

              # Nodes: particle positions
              print(xmf, "\t\t\t\t<Geometry Origin=\"\" Type=\"XYZ\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 3,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":X</DataItem>\n")
              print(xmf, "\t\t\t\t</Geometry>\n")

              # Topology: every particle as a point cell
              print(xmf, "\t\t\t\t<Topology Dimensions=\"", np, "\" Type=\"Mixed\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Int\"",
                            " Dimensions=\"", np*3,
                            "\" Format=\"HDF\" Precision=\"8\">",
                            h5fname, ":connectivity</DataItem>\n")
              print(xmf, "\t\t\t\t</Topology>\n")

              # Attribute: Gamma
              print(xmf, "\t\t\t\t<Attribute Center=\"Node\" ElementCell=\"\"",
                          " ElementDegree=\"0\" ElementFamily=\"\" ItemType=\"\"",
                          " Name=\"Gamma\" Type=\"Vector\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 3,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":Gamma</DataItem>\n")
              print(xmf, "\t\t\t\t</Attribute>\n")

              # Attribute: sigma
              print(xmf, "\t\t\t\t<Attribute Center=\"Node\" ElementCell=\"\"",
                          " ElementDegree=\"0\" ElementFamily=\"\" ItemType=\"\"",
                          " Name=\"sigma\" Type=\"Scalar\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 1,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":sigma</DataItem>\n")
              print(xmf, "\t\t\t\t</Attribute>\n")

              # Attribute: circulation
              print(xmf, "\t\t\t\t<Attribute Center=\"Node\" ElementCell=\"\"",
                          " ElementDegree=\"0\" ElementFamily=\"\" ItemType=\"\"",
                          " Name=\"circulation\" Type=\"Scalar\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 1,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":circulation</DataItem>\n")
              print(xmf, "\t\t\t\t</Attribute>\n")

              # Attribute: vol
              print(xmf, "\t\t\t\t<Attribute Center=\"Node\" ElementCell=\"\"",
                          " ElementDegree=\"0\" ElementFamily=\"\" ItemType=\"\"",
                          " Name=\"vol\" Type=\"Scalar\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 1,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":vol</DataItem>\n")
              print(xmf, "\t\t\t\t</Attribute>\n")


              # Attribute: index
              print(xmf, "\t\t\t\t<Attribute Center=\"Node\" ElementCell=\"\"",
                          " ElementDegree=\"0\" ElementFamily=\"\" ItemType=\"\"",
                          " Name=\"i\" Type=\"Scalar\">\n")
                print(xmf, "\t\t\t\t\t<DataItem DataType=\"Float\"",
                            " Dimensions=\"", np, " ", 1,
                            "\" Format=\"HDF\" Precision=\"4\">",
                            h5fname, ":i</DataItem>\n")
              print(xmf, "\t\t\t\t</Attribute>\n")

            print(xmf, "\t\t\t</Grid>\n")
          print(xmf, "\t\t</Grid>\n")
        print(xmf, "\t</Domain>\n")
    print(xmf, "</Xdmf>\n")

    close(xmf)
end

"""
Return a hash table with the solver settings of the particle field.
"""
function _get_settings(pfield::ParticleField)
    settings = OrderedDict()

    for sym in _pfield_settings

        if sym in _pfield_settings_functions

            fun = getproperty(pfield, sym)
            if fun in _standardfunctions
                settings[String(sym)] = _fun2key[fun]
            else
                settings[String(sym)] = _key_userfun
            end

        else
            settings[String(sym)] = getproperty(pfield, sym)
        end

    end

    return settings
end

function _get_settings_string(pfield::ParticleField; tab=0)
    settings = _get_settings(pfield)

    str = ""
    for (key, val) in settings
        str *= "\t"^(tab)

        valstr = val in _lengthyoptions ? "$(_lengthy2key[val])" : "$(val)"

        str *= Printf.@sprintf "%14.14s----> %s\n" key valstr
    end

    return str
end

function save_settings(pfield::ParticleField, file_name::String;
                                        path::String="", suff="_settings")
    settings = _get_settings(pfield)
    JLD.save(joinpath(path, file_name*suff*".jld"), settings)
end

# """
#   `read(pfield, h5_fname; path="")`
#
# Reads an HDF5 file containing particle data created with `save()` and adds
# all particles the the particle field `pfield`.
# """
# function read(pfield::ParticleField, h5_fname::String;
#                             path::String="", load_time::Bool=false)
#
#     # Opens the HDF5 file
#     fname = h5_fname * (h5_fname[end-3:end]==".h5" ? "" : ".h5")
#     h5 = HDF5.h5open(joinpath(path, h5_fname), "r")
#
#     # Number of particles
#     np = load(h5["np"])
#
#     # Data
#     X = h5["X"]
#     Gamma = h5["Gamma"]
#     sigma = h5["sigma"]
#     vol = h5["vol"]
#
#     # Loads particles
#     for i in 1:np
#         add_particle(pfield, X[1:3, i], Gamma[1:3, i], sigma[i]; vol=vol[i])
#     end
#
#     # Loads time stamp
#     if load_time
#         pfield.t = load(h5["t"])
#         pfield.nt = load(h5["nt"])
#     end
# end


"""
  `create_path(save_path::String, prompt::Bool)`

Create folder `save_path`. `prompt` prompts the user if true.
"""
function create_path(save_path::String, prompt::Bool)
  # Checks if folder already exists
    if isdir(save_path)
        if prompt
            inp1 = ""
            opts1 = ["y", "n"]
            while false==(inp1 in opts1)
                print("\n\nFolder $save_path already exists. Remove? (y/n) ")
                inp1 = readline()[1:end]
            end
            if inp1=="y"
                rm(save_path, recursive=true, force=true)
                println("\n")
            else
                return
            end
        else
            rm(save_path, recursive=true, force=true)
        end
    end
    mkdir(save_path)
end


function timeformat(time_beg, time_end)
    time_delta = Dates.value(time_end)-Dates.value(time_beg)
    hrs = Int(floor(time_delta/1000/60/60))
    mins = Int(floor((time_delta-hrs*60*60*1000)/1000/60))
    secs = Int(floor((time_delta-hrs*60*60*1000-mins*1000*60)/1000))
    return hrs,mins,secs
end


function initialize_verbose(verbose, save_path, run_name, pfield, nsteps_relax,
                            runtime_function, static_particles_function, v_lvl)
    line1 = "*"^(73-8*v_lvl)
    line2 = "-"^(length(line1))
    run_id = save_path!=nothing ? joinpath(save_path, run_name) : ""

    # Set up IO streams for verbose
    file_verbose = save_path != nothing ? joinpath(save_path, "verbose.txt") : nothing

    function vprintln(str, v_lvl)
        if verbose; println("\t"^v_lvl*str); end;
        if file_verbose != nothing
            f = open(file_verbose, "a")
            println(f, "\t"^v_lvl*str)
            close(f)
        end
    end

    # Initial verbose
    vprintln(line2, v_lvl)
    vprintln("", v_lvl)
    vprintln("SOLVER SETTINGS", v_lvl+1)
    vprintln(_get_settings_string(pfield; tab=v_lvl+2), v_lvl)
    vprintln("SIMULATION SETTINGS", v_lvl+1)
    vprintln("nsteps_relax:\t\t$(nsteps_relax)", v_lvl+2)
    vprintln("Runtime Function:\t"*( runtime_function==runtime_default ?
                                "Nothing" : "$(runtime_function)"), v_lvl+2)
    vprintln("Static Particles:\t"*( static_particles_function==static_particles_default ?
                                "Nothing" : "$(static_particles_function)"), v_lvl+2)
    vprintln("", v_lvl)
    vprintln(line2, v_lvl)

    time_beg = Dates.DateTime(Dates.now())
    vprintln(line1, v_lvl)
    vprintln("START $run_id", v_lvl)
    vprintln("$time_beg", v_lvl+1)
    vprintln(line1, v_lvl)

    return line1, line2, run_id, file_verbose, vprintln, time_beg
end


function finalize_verbose(time_beg, line1, vprintln, run_id, v_lvl)
    time_end = Dates.DateTime(Dates.now())
    hrs,mins,secs = timeformat(time_beg, time_end)
    vprintln(line1, v_lvl)
    vprintln("END $run_id", v_lvl)
    vprintln("$time_end", v_lvl+1)
    vprintln(line1, v_lvl)
    vprintln("ELAPSED TIME: $hrs hours $mins minutes $secs seconds", v_lvl)
end
