"""$(README)

$(EXPORTS)
"""
module ActinRingsMC

export SystemParams, SimulationParams, System, Lattice
export calc_lf, calc_Lf, calc_max_lattice_height, calc_min_lattice_height, calc_radius
export generate_starting_config, update_occupancies!, run!, run_us!

using DelimitedFiles
using DocStringExtensions
using JSON
using Random

const kb = 1.380649e-23

"""
System parameters.

$(TYPEDFIELDS)
"""
struct SystemParams
    """Dissociation constant for single crosslinker binding"""
    ks::Float64
    """Dissociation constant for double crosslinker binding"""
    kd::Float64
    """Temperature (K)"""
    T::Float64
    """Lattice spacing (m)"""
    delta::Float64
    """Crosslinker concentration (M)"""
    Xc::Float64
    """Bending rigidity (N m^2)"""
    EI::Float64
    """Filament length (m)"""
    Lf::Float64
    """Binding sites per filament"""
    lf::Int
    """Total number of filaments"""
    Nfil::Int
    """Number of scaffold filaments"""
    Nsca::Int
end

"""
Simulation parameters.

$(TYPEDFIELDS)
"""
struct SimulationParams
    """Number of iterations for US"""
    iters::Int
    """MC steps for a run or single iteration"""
    steps::Int
    """Maximum change in bias energy (kbT)"""
    max_bias_diff::Float64
    """Number of steps between writing to output files"""
    write_interval::Int
    """Frequency of radius moves (the remainder are filament translation moves)"""
    radius_move_freq::Float64
    """Output filebase (include filepath)"""
    filebase::String
    """Use analytical model to generation starting biases"""
    analytical_biases::Bool
    """Read starting biases from file"""
    read_biases::Bool
    """File to read biases from"""
    biases_filename::String
    """Iteration to to start on"""
    restart_iter::Int
    """Width of bins for lattice height bias (set to 1 for no binning)"""
    binwidth::Int
end

mutable struct Filament
    lf::Int
    using_current::Bool
    coors::Array{Int,2}
    current_coors::Array{Int,2}
    trial_coors::Array{Int,2}
    index::Int
end

mutable struct System
    parms::SystemParams
    filaments::Vector{Filament}
    radius::Float64
    energy::Float64
end

"""
$(TYPEDSIGNATURES)

System data, including parameters and positions of filaments.

The given radius should be that corresponding to the lattice height used to create the
lattice and the starting configuration of the filaments.
"""
function System(parms::SystemParams, filaments::Vector{Filament}, radius::Float64)
    return System(parms, filaments, radius, 0)
end

mutable struct Lattice
    occupancy::Dict{Vector{Int},Tuple{Int,Int}}
    using_current::Bool
    current_occupancy::Dict{Vector{Int},Tuple{Int,Int}}
    trial_occupancy::Dict{Vector{Int},Tuple{Int,Int}}
    height::Int
    current_height::Int
    trial_height::Int
    max_height::Int
    min_height::Int
end

"""
$(TYPEDSIGNATURES)

2D lattice with periodic conditions on y.

The max and min heights should be calculated based on the number of scaffold filaments and
the length of the filaments.
"""
function Lattice(height::Int, max_height::Int, min_height::Int)
    occupancy::Dict{Vector{Int},Tuple{Int,Int}} = Dict()
    return Lattice(
        occupancy,
        true,
        occupancy,
        copy(occupancy),
        height,
        height,
        height,
        max_height,
        min_height
)
end

mutable struct Biases
    barriers::Vector{Int}
    counts::Vector{Int}
    freqs::Vector{Float64}
    probs::Vector{Float64}
    enes::Vector{Float64}
    numbins::Int
    binwidth::Int
end

function create_bin_barriers(lattice::Lattice, numbins::Int)
    binsize = div((lattice.max_height - lattice.min_height + 1), numbins)
    barriers::Vector{Int} = []
    barrier = lattice.min_height
    for _ in 1:(numbins - 1)
        barrier += binsize
        push!(barriers, barrier)
    end

    return barriers
end

function Biases(lattice::Lattice, binwidth::Int)
    numstates = lattice.max_height - lattice.min_height + 1
    numbins = div(numstates, binwidth)
    barriers = create_bin_barriers(lattice, numbins)

    return Biases(
        barriers,
        zeros(numbins),
        zeros(numbins),
        zeros(numbins),
        zeros(numbins),
        numbins,
        binwidth
   )
end

function read_biases!(filename::String, itr::Int, biases::Biases)
    biases.enes = readdlm(filename, skipstart=1)[itr, :]
end

function get_bin(barriers::Vector{Int}, height::Int)
    for (bin, barrier) in enumerate(barriers)
        if height < barrier
            return bin
        end
    end

    return length(barriers) + 1
end

"""
$(TYPEDSIGNATURES)

Calculate the number of sites per filament.
"""
calc_lf(Lf::Float64, delta::Float64)::Int = div(Lf, delta)

"""
$(TYPEDSIGNATURES)

Calculate the length of a filament.
"""
calc_Lf(lf::Int, delta::Float64) = delta * lf

"""
$(TYPEDSIGNATURES)

Calculate the maximum allowable height of a lattice given Nsca.
"""
calc_max_lattice_height(Nsca::Int, lf::Int) = Nsca * lf - Nsca - 1

"""
$(TYPEDSIGNATURES)

Calculate the minimum allowable height of a lattice given Nsca.
"""
calc_min_lattice_height(Nsca::Int, lf::Int) = div(Nsca, 2) * lf - 1

"""
$(TYPEDSIGNATURES)

Calculate the radius of a ring for a given lattice height.
"""
calc_radius(delta::Float64, height::Int) = delta * (height + 1) / (2pi)

"""Update the radius/height variables in the system and lattice."""
function update_radius!(system::System, lattice::Lattice, height::Int)
    lattice.height = height
    system.radius = calc_radius(system.parms.delta, height)

    return nothing
end

"""Use the current coordinates and occupancies."""
function use_current_coors!(system::System, lattice::Lattice)
    lattice.using_current = true
    lattice.occupancy = lattice.current_occupancy
    update_radius!(system, lattice, lattice.current_height)
    for filament in system.filaments
        filament.using_current = true
        filament.coors = filament.current_coors
    end

    return nothing
end

"""Use the trial coordinates and occupancies."""
function use_trial_coors!(system::System, lattice::Lattice)
    lattice.using_current = false
    lattice.occupancy = lattice.trial_occupancy
    update_radius!(system, lattice, lattice.trial_height)
    for filament in system.filaments
        filament.using_current = false
        filament.coors = filament.trial_coors
    end
    
    return nothing
end

"""Replace the current coordinates/occupancies with the trial ones."""
function accept_trial!(filament::Filament, lattice::Lattice)
    filament.current_coors = copy(filament.trial_coors)
    lattice.current_occupancy = copy(lattice.trial_occupancy)

    return nothing
end

function accept_trial!(system::System, lattice::Lattice)
    for filament in system.filaments
        filament.current_coors = copy(filament.trial_coors)
    end

    lattice.current_occupancy = copy(lattice.trial_occupancy)
    lattice.current_height = lattice.trial_height

    return nothing
end

"""Replace the trial coordinates/occupancies with the current ones."""
function accept_current!(filament::Filament, lattice::Lattice)
    filament.trial_coors = copy(filament.current_coors)
    lattice.trial_occupancy = copy(lattice.current_occupancy)

    return nothing
end

function accept_current!(system::System, lattice::Lattice)
    for filament in system.filaments
        filament.trial_coors = copy(filament.current_coors)
    end

    lattice.trial_occupancy = copy(lattice.current_occupancy)
    lattice.trial_height = lattice.current_height

    return nothing
end

"""Apply periodic boundary conditions to position."""
function wrap_pos!(lattice::Lattice, pos::Vector{Int})
    if pos[2] > lattice.height
        pos[2] = -(lattice.height + 1) + pos[2]
    elseif pos[2] < 0
        pos[2] = (lattice.height + 1) + pos[2]
    end

    return nothing
end


"""Distance between two points on the lattice along y given direction."""
function periodic_distance(lattice::Lattice, y1::Int, y2::Int, dir::Int)
    d = 0
    if y2 > y1
        if dir == 1
            d = y2 - y1
        else
            d = -(lattice.height - y2 + y1 + 1)
        end
    elseif y2 < y1
        if dir == 1
            d = lattice.height - y1 + y2 + 1
        else
            d = y2 - y1
        end
    end

    return d
end

function system_in_boundaries(system::System, lattice::Lattice)
    for filament in system.filaments
        if any(filament.coors[2, :] .< 0) || any(filament.coors[2, :] .> lattice.height)
            return false
        end
    end

    return true
end

"""
$(TYPEDSIGNATURES)

Generate a starting configuration with uniform overlaps.

The number of scaffold filament Nsca and the number of lattices lf must be even.
"""
function generate_starting_config(
    lattice::Lattice,
    Nfil::Int,
    Nsca::Int,
    lf::Int,
    overlap::Int
)
    if Nsca % 2 != 0
        throw(DomainError("Can currently only handle even Nsca"))
    end
    if lf % 2 != 0
        throw(DomainError("Uniform overlaps only possible with even lf"))
    end

    filaments::Vector{Filament} = []
    pos = [0, 0]
    Ni = 1
    while Ni <= Nfil
        for _ in 1:div(Nsca, 2)
            coors = zeros(2, lf)
            for j in 1:lf
                coors[:, j] = pos
                pos[2] += 1
                wrap_pos!(lattice, pos)
            end
            filament = Filament(lf, true, coors, coors, copy(coors), Ni)
            push!(filaments, filament)
            pos[2] += lf - 2 * overlap
            wrap_pos!(lattice, pos)
            Ni += 1
            if Ni > Nfil
                break
            end
        end

        pos[1] += 1
        pos[1] % 2 == 0 ? pos[2] = 0 : pos[2] = lf - overlap
        wrap_pos!(lattice, pos)
    end

    return filaments
end

"""
$(TYPEDSIGNATURES)

Clear occupancies and fully update.
"""
function update_occupancies!(filaments::Vector{Filament}, lattice::Lattice)
    lattice.current_occupancy = Dict()
    lattice.trial_occupancy = Dict()
    for filament in filaments
        for i in 1:filament.lf
            pos = filament.coors[:, i]
            lattice.current_occupancy[copy(pos)] = (filament.index, i)
            lattice.trial_occupancy[copy(pos)] = (filament.index, i)
        end
    end

    lattice.occupancy = lattice.current_occupancy

    return nothing
end

"""Calculate the bending energy (J) for a single filament."""
function filament_bending_energy(system::System)
    return system.parms.EI * system.parms.Lf / (2 * system.radius^2)
end

function filament_bending_energy(system::System, radius::Float64)
    return system.parms.EI * system.parms.Lf / (2 * radius^2)
end

"""Calculate the bending energy (J) for the whole system."""
function total_bending_energy(system::System)
    ene = 0
    for _ in 1:system.parms.Nfil
        ene += filament_bending_energy(system)
    end

    return ene
end

"""Calculate the overlap energy (J)."""
function overlap_energy(system::System, L::Float64)
    factor_t = L * kb * system.parms.T / system.parms.delta 
    ks = system.parms.ks
    kd = system.parms.kd
    Xc = system.parms.Xc
    log_t = log(1 + ks^2 * Xc / (kd * (ks + Xc)^2))

    return -factor_t * log_t
end

function overlap_energy(system::System, lattice::Lattice, filament::Filament)
    l = 0
    for i in 1:system.parms.lf
        pos = filament.coors[:, i]
        for dx in [-1, 1]
            adj_pos = [pos[1] + dx, pos[2]]
            if adj_pos in keys(lattice.occupancy)
                l += 1
            end
        end
    end
    L = system.parms.delta * l

    return overlap_energy(system, L)
end

function overlap_energy(system::System, lattice::Lattice)
    ene = 0
    for filament in system.filaments
        ene += overlap_energy(system, lattice, filament) / 2
    end

    return ene
end

"""Calculate the bias energy (J)."""
function bias_energy(lattice::Lattice, biases::Biases)
    return biases.enes[get_bin(biases.barriers, lattice.height)]
end

"""Calculate total energy (J)."""
function total_energy(system::System, lattice::Lattice)
    ene = 0
    for filament in system.filaments
        ene += overlap_energy(system, lattice, filament) / 2
        ene += filament_bending_energy(system)
    end

    return ene
end

function total_energy(system::System, lattice::Lattice, biases::Biases)
    ene = total_energy(system, lattice)
    ene += bias_energy(lattice, biases)

    return ene
end

"""Calculate total energy difference (J)."""
function energy_diff(system::System, lattice::Lattice, filament::Filament)
    using_current = lattice.using_current
    if !using_current
        use_current_coors!(system, lattice)
    end

    cur_overlap_ene = overlap_energy(system, lattice, filament)
    cur_bending_ene = filament_bending_energy(system)

    use_trial_coors!(system, lattice)
    trial_overlap_ene = overlap_energy(system, lattice, filament)
    trial_bending_ene = filament_bending_energy(system)

    if using_current
        use_current_coors!(system, lattice)
    end

    return trial_overlap_ene + trial_bending_ene - cur_overlap_ene - cur_bending_ene
end

function energy_diff(system::System, lattice::Lattice, biases::Biases)
    using_current = lattice.using_current
    if !using_current
        use_current_coors!(system, lattice)
    end

    current_ene = total_energy(system, lattice, biases)

    use_trial_coors!(system, lattice)
    trial_ene = total_energy(system, lattice, biases)

    if using_current
        use_current_coors!(system, lattice)
    end

    return trial_ene - current_ene
end

"""Check if system connected and ring is unbroken with correct Nsca."""
function ring_and_system_connected(system::System, lattice::Lattice, check_consistency=false)
    ring_connected = []
    for filament in system.filaments
        push!(ring_connected, ring_and_system_connected(system, lattice, filament))
        if !check_consistency
            break
        end
    end
    if all(ring_connected)
        return true
    elseif all(.!ring_connected)
        return false
    else
        throw(ErrorException("Inconsistent connectivity check"))
    end
end

function ring_and_system_connected(system::System, lattice::Lattice, filament::Filament)
    # if system.parms.Nfil == system.parms.Nsca == 2
    #    first_pos = filament.coors[:, 1]
    #    last_pos = filament.coors[:, end]
    #    if (([first_pos[1] - 1, first_pos[2]] in keys(lattice.occupancy) ||
    #        [first_pos[1] + 1, first_pos[2]] in keys(lattice.occupancy)) &&
    #        ([last_pos[1] - 1, last_pos[2]] in keys(lattice.occupancy) ||
    #        [last_pos[1] + 1, last_pos[2]] in keys(lattice.occupancy)))
    #        return true
    #    else
    #        return false
    #    end
    # end
    searched_filaments::Set{Int} = Set()
    pos = filament.coors[:, 1]
    site_i = 1
    path::Vector{Vector{Int}} = [[], [], []]
    path_length = 0
    ring_contig = false
    connected_filaments::Set{Int} = Set(filament.index)
    Nsca::Int = system.parms.Nfil
    while site_i <= filament.lf
        for dx in [-1, 1]
            adj_pos = [pos[1] + dx, pos[2]]
            if adj_pos in keys(lattice.occupancy)
                adj_filament_i, adj_site_i = lattice.occupancy[adj_pos]
                if adj_filament_i in searched_filaments
                    continue
                end
                union!(searched_filaments, adj_filament_i)
                union!(connected_filaments, adj_filament_i)
                adj_filament = system.filaments[adj_filament_i]
                push!(path[1], filament.index)
                push!(path[2], site_i)
                push!(path[3], path_length)
                ring_contig, connected_filaments, Nsca = search_filament_for_path(
                    system,
                    lattice,
                    adj_filament,
                    adj_site_i,
                    path,
                    ring_contig,
                    connected_filaments,
                    Nsca
                )
                if (ring_contig &&
                    length(connected_filaments) == system.parms.Nfil &&
                    Nsca == system.parms.Nsca)

                    return true
                end
                pop!(path[1])
                pop!(path[2])
                pop!(path[3])
            end
        end
        site_i += 1
        pos += [0, 1]
        wrap_pos!(lattice, pos)
        path_length += 1
    end

    return false
end

function path_completed(
    lattice::Lattice,
    path_length::Int,
    entry_site::Int,
    exit_site::Int,
    )
    remainder_dist = exit_site - entry_site
    # println((entry_site, exit_site, remainder_dist, path_length, abs(path_length + remainder_dist), lattice.height + 1))

    return abs(path_length + remainder_dist) == lattice.height + 1
end

function search_filament_for_path(
    system::System,
    lattice::Lattice,
    filament::Filament,
    site_i::Int,
    path::Vector{Vector{Int}},
    ring_contig::Bool,
    connected_filaments::Set{Int},
    Nsca::Int
)
    searched_filaments::Set{Int} = Set()
    initial_pos = filament.coors[:, site_i]
    path_length = path[3][end]
    initial_path_length = path_length
    pos = copy(initial_pos)
    dir = -1
    initial_site_i = site_i
    # println(filament.index)
    # println(path)
    while true

        # Check if end of filament reached
        if site_i < 1 || site_i > filament.lf
            if dir == -1
                dir = 1
                path_length = initial_path_length + dir
                site_i = initial_site_i + dir
                pos = initial_pos + [0, dir]
                wrap_pos!(lattice, pos)
                continue
            else
                break
            end
        end

        for dx in [-1, 1]
            adj_pos = [pos[1] + dx, pos[2]]
            if adj_pos in keys(lattice.occupancy)
                # println(adj_pos)
                adj_filament_i, adj_site_i = lattice.occupancy[adj_pos]
                adj_filament = system.filaments[adj_filament_i]

                # This will check the neighbouring filaments at every site
                # This seems inefficient, but then I can't skip after one check if Nsca = 2
                if adj_filament_i in path[1]
                    path_i = indexin(adj_filament_i, path[1])[1]
                    sub_path_length = path_length - path[3][path_i]
                    exit_site = path[2][path_i]
                    if path_completed(lattice, sub_path_length, adj_site_i, exit_site)
                        ring_contig = true
                        Nsca = min(Nsca, length(path[1]) - path_i + 2)
                    end
                end

                if (ring_contig &&
                    length(connected_filaments) == system.parms.Nfil &&
                    Nsca == system.parms.Nsca)

                    return (ring_contig, connected_filaments, Nsca) 
                end

                if (adj_filament_i in searched_filaments ||
                    adj_filament_i in path[1])

                    continue
                end

                union!(connected_filaments, adj_filament_i)
                union!(searched_filaments, adj_filament_i)
                push!(path[1], filament.index)
                push!(path[2], site_i)
                push!(path[3], path_length)
                ring_contig, connected_filaments, Nsca = search_filament_for_path(
                    system,
                    lattice,
                    adj_filament,
                    adj_site_i,
                    path,
                    ring_contig,
                    connected_filaments,
                    Nsca
                )
                if (ring_contig &&
                    length(connected_filaments) == system.parms.Nfil &&
                    Nsca == system.parms.Nsca)

                    return (ring_contig, connected_filaments, Nsca)
                end
                pop!(path[1])
                pop!(path[2])
                pop!(path[3])
                # println(filament.index)
                # println(path)
            end
        end

        site_i += dir
        pos += [0, dir]
        wrap_pos!(lattice, pos)
        path_length += dir
    end

    return (ring_contig, connected_filaments, Nsca)
end

"""Check filaments are contiguous, i.e. on adjacent lattice sites."""
function filaments_contiguous(system::System, lattice::Lattice)
    for filament in system.filaments
        prev_pos = filament.coors[:, 1]
        for i in 2:filament.lf
            pos = filament.coors[:, i]
            exp_pos = [prev_pos[1], prev_pos[2] + 1]
            wrap_pos!(lattice, exp_pos)
            if exp_pos != pos
                return false
            end
            prev_pos = pos
        end
    end

    return true
end

"""Test acceptance with Metropolis criterion."""
function accept_move(system::System, delta_energy::Float64, mult::Float64=1.)
    p_accept = min(1, mult * exp(-delta_energy / kb / system.parms.T))
    accept = false
    if p_accept == 1 || p_accept > rand(Float64)
        accept = true;
    end

    return accept;
end

function recenter!(system::System, lattice::Lattice)
    origin = system.filaments[1].coors[2, 1]
    if origin == 0
        return nothing
    end

    for filament in system.filaments
        for i in 1:filament.lf
            pos = filament.coors[:, i]
            delete!(lattice.occupancy, pos)
            pos[2] -= origin
            wrap_pos!(lattice, pos)
            lattice.occupancy[copy(pos)] = (filament.index, i)
            filament.coors[:, i] = pos
        end
    end

    return nothing
end

"""
Translate a filament with given vector.

Returns false if steric clash occurs.
"""
function translate_filament!(filament::Filament, lattice::Lattice, move_vector::Vector{Int})
    for i in 1:filament.lf
        pos = filament.coors[:, i]
        delete!(lattice.occupancy, pos)
    end

    for i in 1:filament.lf
        pos = filament.coors[:, i]
        pos += move_vector
        wrap_pos!(lattice, pos)
        if pos in keys(lattice.occupancy)
            return false
        end
        filament.coors[:, i] = pos
        lattice.occupancy[copy(pos)] = (filament.index, i)
    end

    return true
end

"""Attempt to translate a filament up or down by one site."""
function attempt_translation_move!(system::System, lattice::Lattice, ::Biases)
    use_trial_coors!(system, lattice)

    # Do not move the first filament as it is the reference
    filament = rand(system.filaments[2:end])
    move_vector = [0, rand([-1, 1])]
    if !translate_filament!(filament, lattice, move_vector)
        accept_current!(system, lattice)
        use_current_coors!(system, lattice)
        
        return false
    end

    if !ring_and_system_connected(system, lattice)
        accept_current!(filament, lattice)
        use_current_coors!(system, lattice)
        
        return false
    end

    delta_energy = energy_diff(system, lattice, filament)
    accept = accept_move(system, delta_energy)
    if accept
        accept_trial!(filament, lattice)
    else
        accept_current!(filament, lattice)
    end

    use_current_coors!(system, lattice)

    return accept
end

"""Find filament sites that are below upper periodic boundary."""
function find_split_points(system::System, lattice::Lattice)
    split_points::Vector{Int} = []
    for filament in system.filaments
        push!(split_points, 0)
        for i in 1:filament.lf
            y = filament.coors[2, i]
            if y == lattice.height
                if i != filament.lf
                    split_points[end] = i
                    break
                end
            end
        end
    end

    return split_points
end


"""
Translate segments of filaments below split point only.

Returns false if steric clash occurs.
"""
function translate_filaments_with_split_points!(
    system::System,
    lattice::Lattice,
    split_points::Vector{Int},
    dir::Int
)
    for (filament, split_point) in zip(system.filaments, split_points)
        for i in 1:split_point
            pos = filament.coors[:, i]
            delete!(lattice.occupancy, pos)
        end
    end

    for (filament, split_point) in zip(system.filaments, split_points)
        for i in 1:split_point
            filament.coors[2, i] += dir
            pos = filament.coors[:, i]
            if !(pos in keys(lattice.occupancy))
                lattice.occupancy[pos] = (filament.index, i)
            else
                return false
            end
        end
    end

    return true
end

"""Attempt to increase or decrease radius by one lattice site."""
function attempt_radius_move!(system::System, lattice::Lattice, biases::Biases)
    dir = rand([-1, 1])
    if (dir == 1 && lattice.height == lattice.max_height ||
        dir == -1 && lattice.height == lattice.min_height)
        accept_current!(system, lattice)
        use_current_coors!(system, lattice)

        return false
    end

    use_trial_coors!(system, lattice)
    split_points = find_split_points(system, lattice)
    if !translate_filaments_with_split_points!(system, lattice, split_points, dir)
        accept_current!(system, lattice)
        use_current_coors!(system, lattice)

        return false
    end

    lattice.trial_height += dir
    update_radius!(system, lattice, lattice.trial_height)
    # if lattice.trial_height > lattice.max_height
    #    println(dir)
    #    println(lattice.height)
    #    println(lattice.current_height)
    #    println(lattice.trial_height)
    #    throw(DomainError)
    # end
    if !filaments_contiguous(system, lattice)
        accept_current!(system, lattice)
        use_current_coors!(system, lattice)

        return false
    end

    if dir == 1
        if !ring_and_system_connected(system, lattice)
            accept_current!(system, lattice)
            use_current_coors!(system, lattice)
            
            return false
        end
    end

    delta_energy = energy_diff(system, lattice, biases)
    # mult = (lattice.trial_height + 1) / (lattice.current_height + 1)
    # accept = accept_move(system, delta_energy, mult)
    accept = accept_move(system, delta_energy)
    if accept
        accept_trial!(system, lattice)
    else
        update_radius!(system, lattice, lattice.height - dir)
        accept_current!(system, lattice)
    end

    use_current_coors!(system, lattice)

    return accept
end

"""Return an attempt move function according to move type weights."""
function select_move(simparms::SimulationParams)
    if simparms.radius_move_freq > rand(Float64)
        return attempt_radius_move!
    else
        return attempt_translation_move!
    end
end

"""Open and write header for order parameters file."""
function prepare_ops_file(filename::String)
    file = open(filename, "w")
    header = "step energy height radius"
    println(file, header)
    
    return file
end

"""Open and write header for umbrella sampling output file."""
function prepare_us_file(filename::String, lattice::Lattice)
    file = open(filename, "w")
    header = ""
    for h in lattice.min_height:lattice.max_height
        header *= "$h "
    end

    println(file, header)

    return file
end

"""Open and write header for VTF output file."""
function prepare_vtf_file(filename::String, system::System)
    file = open(filename, "w")
    atom_i = 0
    for filament in system.filaments
        end_atom_i = atom_i + filament.lf - 1
        println(file, "a $atom_i:$end_atom_i c $(filament.index) r 2.5")
        atom_i += filament.lf
    end

    println(file, "")

    return file
end

"""Write configuration in VTF format to file."""
function write_vtf(system::System, file::IOStream)
    println(file, "t")
    for filament in system.filaments
        for i in 1:filament.lf
            # Widen the aspect ratio for easier viewing
            x = filament.coors[1, i] * 10
            y = filament.coors[2, i]
            println(file, "$x $y 0")
        end
    end

    println(file, "")

    return nothing
end

"""Write current order parameters to file."""
function write_ops(system::System, lattice::Lattice, step::Int, file::IOStream)
    println(file, "$step $(system.energy) $(lattice.height) $(system.radius)")

    return nothing
end

"""Write current umbrella sampling output data to file."""
function write_us_data(data::Vector, file::IOStream)
    for d in data
        print(file, "$d ")
    end

    println(file, "")

    return nothing
end

"""Write simulation parameters to file."""
function write_params(system::System, simparms::SimulationParams, file::IOStream)
    parms = Dict(
        "lf" => system.parms.lf,
        "T" => system.parms.T,
        "kd" => system.parms.kd,
        "ks" => system.parms.ks,
        "EI" => system.parms.EI,
        "Lf" => system.parms.Lf,
        "Xc" => system.parms.Xc,
        "Nfil" => system.parms.Nfil,
        "Nsca" => system.parms.Nsca,
        "delta" => system.parms.delta,
        "steps" => simparms.steps,
        "write_interval" => simparms.write_interval,
        "filebase" => simparms.filebase,
        "max_bias_diff" => simparms.max_bias_diff,
        "radius_move_freq" => simparms.radius_move_freq,
        "iters" => simparms.iters,
        "analytical_biases" => simparms.analytical_biases,
        "binwidth" => simparms.binwidth
    )
    println(file, json(parms))
    
    return nothing
end

"""Add one to count of visits of current state."""
function update_counts(biases::Biases, lattice::Lattice)
    bin = get_bin(biases.barriers, lattice.height)
    biases.counts[bin] += 1

    return nothing
end

"""
$(TYPEDSIGNATURES)

Run an MC simulation.
"""
function run!(
    system::System,
    lattice::Lattice,
    simparms::SimulationParams,
    biases::Biases,
    ops_file::IOStream,
    vtf_file::IOStream
)

    # Overly simple way to record move acceptance frequencies
    attempts = [0, 0]
    accepts = [0, 0]
    recenter!(system, lattice)
    for step in 1:simparms.steps
        attempt_move! = select_move(simparms)
        accepted = attempt_move!(system, lattice, biases)
        attempt_move! === attempt_translation_move! ? attempts[1] += 1 : attempts[2] += 1
        if accepted
            attempt_move! === attempt_translation_move! ? accepts[1] += 1 : accepts[2] += 1
        end
        update_counts(biases, lattice)
        if step % simparms.write_interval == 0
            ring_and_system_connected(system, lattice, true)
            println("Step: $step")
            system.energy = total_energy(system, lattice)
            write_ops(system, lattice, step, ops_file)
            write_vtf(system, vtf_file)
        end
    end

    println()
    println("Move info:")
    println()
    println("Filament translation")
    println("Attempts: $(attempts[1])")
    println("Accepts: $(accepts[1])")
    println("Ratio: $(accepts[1] / attempts[1])")
    println()
    println("Radius move")
    println("Attempts: $(attempts[2])")
    println("Accepts: $(accepts[2])")
    println("Ratio: $(accepts[2] / attempts[2])")

    return nothing
end

"""
$(TYPEDSIGNATURES)

Run an MC simulation.
"""
function run!(system::System, lattice::Lattice, simparms::SimulationParams)
    ops_file = prepare_ops_file("$(simparms.filebase).ops")
    vtf_file = prepare_vtf_file("$(simparms.filebase).vtf", system)
    biases = Biases(lattice, simparms.binwidth)
    run!(system, lattice, simparms, biases, ops_file, vtf_file)
    close(ops_file)
    close(vtf_file)
    open("$(simparms.filebase).parms", "w") do file
        write_params(system, simparms, file)
    end

    return nothing
end

"""
Calculate new biases from counts.

Updates the passed arrays in the process.
"""
function update_biases!(biases::Biases, T::Float64, max_bias_diff::Float64)
    reduced_enes = biases.enes ./ (kb * T)
    steps = sum(biases.counts)
    norm = sum(biases.counts .* exp.(reduced_enes))
    max_bias_diff *= kb * T
    for i in 1:length(biases.counts)
        if biases.counts[i] == 0
            biases.freqs[i] = 0
            biases.probs[i] = 0
            bias_diff = -max_bias_diff
        else
            biases.freqs[i] = biases.counts[i] / steps
            biases.probs[i] = biases.counts[i] * exp(reduced_enes[i]) / norm
            bias_diff = kb * T * log(biases.probs[i]) - biases.enes[i]
            if bias_diff > max_bias_diff
                bias_diff = max_bias_diff
            elseif bias_diff < -max_bias_diff
                bias_diff = -max_bias_diff
            end
        end

        biases.enes[i] += bias_diff
        biases.counts[i] = 0
    end

    return nothing
end

"""
Calculate biases from analytical model.

Interpolate between the bin endpoints.
"""
function analytical_biases(system::System, lattice::Lattice, biases::Biases)
    radius_max = calc_radius(system.parms.delta, lattice.max_height)
    for bin in 1:biases.numbins
        if bin == biases.numbins
            lower_barrier = biases.barriers[bin - 1]
            upper_barrier = lower_barrier + biases.binwidth
        else
            upper_barrier = biases.barriers[bin]
            lower_barrier = upper_barrier - biases.binwidth
        end

        lower_upper_biases = []
        for h in [lower_barrier, upper_barrier]
            radius = calc_radius(system.parms.delta, h)
            L = 2 * pi * (radius_max - radius) / system.parms.Nsca
            overlaps = system.parms.Nsca + 2 * (system.parms.Nfil - system.parms.Nsca)
            sliding_energy = overlaps * overlap_energy(system, L)
            bending_energy = system.parms.Nfil * filament_bending_energy(system, radius)
            push!(lower_upper_biases, -(sliding_energy + bending_energy))
        end
        biases.enes[bin] = sum(lower_upper_biases) / 2
    end

    return nothing
end

"""
$(TYPEDSIGNATURES)

Run an umbrella sampling MC simulation.
"""
function run_us!(system::System, lattice::Lattice, simparms::SimulationParams)
    open("$(simparms.filebase).parms", "w") do file
        write_params(system, simparms, file)
    end

    biases = Biases(lattice, simparms.binwidth)

    start_iter = 1
    end_iter = simparms.iters
    if simparms.read_biases
        read_biases!(simparms.biases_filename, simparms.restart_iter, biases)
        start_iter = simparms.restart_iter + 1
        end_iter += simparms.restart_iter
    elseif simparms.analytical_biases
        analytical_biases(system, lattice, biases)
    end
    counts_file = prepare_us_file("$(simparms.filebase).counts", lattice)
    freqs_file = prepare_us_file("$(simparms.filebase).freqs", lattice)
    biases_file = prepare_us_file("$(simparms.filebase).biases", lattice)
    for i in start_iter:end_iter
        println()
        println("Iter: $i")
        iter_filebase = "$(simparms.filebase)_iter-$i"
        ops_file = prepare_ops_file("$iter_filebase.ops")
        vtf_file = prepare_vtf_file("$iter_filebase.vtf", system)
        run!(system, lattice, simparms, biases, ops_file, vtf_file)
        write_us_data(biases.counts, counts_file)
        update_biases!(biases, system.parms.T, simparms.max_bias_diff)
        write_us_data(biases.freqs, freqs_file)
        write_us_data(biases.enes, biases_file)
        close(ops_file)
        close(vtf_file)
    end

    close(counts_file)
    close(freqs_file)
    close(biases_file)

    println()

    return nothing
end

end
