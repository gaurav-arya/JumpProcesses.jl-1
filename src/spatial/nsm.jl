# Implementation of the Next Subvolume Method on a grid


############################ NSM ###################################
struct NSM <: AbstractAggregatorAlgorithm end

#NOTE state vector u is a matrix. u[i,j] is species i, site j
#NOTE diffusion_constants is a matrix. diffusion_constants[i,j] is species i, site j
mutable struct NSMJumpAggregation{J,T,R<:AbstractSpatialRates,C,S,RNG,DEPGR,PQ,SS<:AbstractSpatialSystem} <: AbstractSpatialSSAJumpAggregator
    next_jump::SpatialJump{J} #some structure to identify the next event: reaction or diffusion
    prev_jump::SpatialJump{J} #some structure to identify the previous event: reaction or diffusion
    next_jump_time::T
    end_time::T
    cur_rates::R #some structure to store current rates
    diffusion_constants::C #matrix with ith column being diffusion constants for site i
    ma_jumps::S #massaction jumps
    # rates::F1 #rates for constant-rate jumps
    # affects!::F2 #affects! function determines the effect of constant-rate jumps
    save_positions::Tuple{Bool,Bool}
    rng::RNG
    dep_gr::DEPGR #dep graph is same for each locale
    pq::PQ
    spatial_system::SS
end

# NOTE make 0 a sink state

function NSMJumpAggregation(nj::SpatialJump{J}, njt::T, et::T, crs::R, diffusion_constants::C,
                                      maj::S, sps::Tuple{Bool,Bool},
                                      rng::RNG, spatial_system::AbstractSpatialSystem; num_specs, dep_graph=nothing, kwargs...) where {T,S,R,C,F1,F2,RNG}

    # a dependency graph is needed and must be provided if there are constant rate jumps
    if dep_graph === nothing
        dg = DiffEqJump.make_dependency_graph(num_specs, maj)
    else
        dg = dep_graph

        # make sure each jump depends on itself
        add_self_dependencies!(dg)
    end

    pq = MutableBinaryMinHeap{T}()

    NSMJumpAggregation{J,T,R,C,S,F1,F2,RNG,typeof(dg),typeof(pq)}(nj, nj, njt, et, crs, diffusion_constants, maj,
                                                            sps, rng, dg, pq, spatial_system)
end

############################# Required Functions ##############################
# creating the JumpAggregation structure (function wrapper-based constant jumps)
#QUESTION what needs to be changed if the signature of aggregate changes?
function aggregate(aggregator::NSM, num_species, end_time, diffusion_constants, ma_jumps, save_positions, rng, spatial_system; kwargs...)

    majumps = ma_jumps
    if majumps === nothing
        majumps = MassActionJump(Vector{typeof(end_time)}(), Vector{Vector{Pair{Int,Int}}}(), Vector{Vector{Pair{Int,Int}}}())
    end

    next_jump = SpatialJump{Int}(typemax(Int),typemax(Int),typemax(Int)) #a placeholder
    next_jump_time = typemax(typeof(end_time))
    current_rates = SpatialRates(get_num_majumps(majumps), num_species, number_of_sites(spatial_system))

    NSMJumpAggregation(next_jump, next_jump_time, end_time, current_rates, diffusion_constants, majumps, save_positions, rng, spatial_system; num_specs = num_species, kwargs...)
end

#NOTE integrator and params are not used. They remain to adhere to the interface of `AbstractSSAJumpAggregator` defined in ssajump.jl
# set up a new simulation and calculate the first jump / jump time
function initialize!(p::NSMJumpAggregation, integrator, u, params, t)
    fill_rates_and_get_times!(p, u, t)
    generate_jumps!(p, u, t)
    nothing
end

#NOTE integrator and params are not used. They remain to adhere to the interface of `AbstractSSAJumpAggregator` defined in ssajump.jl
# calculate the next jump / jump time
function generate_jumps!(p::NRMJumpAggregation, integrator, params, u, t)
    @unpack cur_rates, rng = p

    p.next_jump_time, site = top_with_handle(p.pq)
    if rand(rng)*get_site_rate(cur_rates, site) < get_site_reactions_rate(cur_rates, site)
        rx = linear_search(get_site_reactions_rate(cur_rates, site), rand(rng) * get_site_reactions_rate(cur_rates, site))
        p.next_jump = SpatialJump(site, rx, site)
    else
        species_to_diffuse = linear_search(get_site_diffusions_iterator(cur_rates, site), rand(rng) * get_site_diffusions_rate(cur_rates, site))
        n = rand(rng,1:num_neighbors(spatial_system, site))
        target_site = nth_neighbor(grid,site,n)
        p.next_jump = SpatialJump(site, species_to_diffuse, target_site)
    end
end

# execute one jump, changing the system state
function execute_jumps!(p::NSMJumpAggregation, integrator, u, params, t)
    # execute jump
    u = update_state!(p, integrator, u)

    # update current jump rates and times
    update_dependent_rates_and_draw_new_firing_times!(p, u, params, t)
    nothing
end


######################## SSA specific helper routines ########################
"""
reevaluate all rates, recalculate tentative site firing times, and reinit the priority queue
"""
function fill_rates_and_get_times!(aggregation::NRMJumpAggregation, u, t)
    @unpack majumps, cur_rates, diffusion_constants, spatial_system = aggregation
    @unpack reaction_rates, diffusion_rates = cur_rates
    num_sites = number_of_sites(spatial_system)
    num_majumps = get_num_majumps(majumps)
    num_species = length(u[:,1]) #NOTE assumes u is a matrix with ith column being the ith site

    @assert cur_rates.reaction_rates_sum == zeros(typeof(cur_rates.reaction_rates_sum[1]),num_sites)
    @assert cur_rates.diffusion_rates_sum == zeros(typeof(cur_rates.diffusion_rates_sum[1]),num_sites)

    pqdata = Vector{typeof(t)}(undef, num_sites)
    for site in 1:num_sites
        #reactions
        for rx in 1:num_majumps
            rate = evalrxrate(u[:,site], rx, majumps)
            set_site_reaction_rate!(cur_rates, site, rx, rate)
        end
        #diffusions
        for species in 1:num_species
            rate = u[species,site]*diffusion_constants[species,site]
            set_site_diffusion_rate!(cur_rates, site, species, rate)
        end
        pqdata[site] = t + randexp(aggregation.rng) / get_site_rate(spatial_rates, site)
    end

    aggregation.pq = MutableBinaryMinHeap(pqdata)
    nothing
end

"""
    update_dependent_rates_and_draw_new_firing_times!(p, u, t)

recalculate jump rates for jumps that depend on the just executed jump (p.prev_jump)
"""
function update_dependent_rates_and_draw_new_firing_times!(p, u, t)
    jump = p.prev_jump
    site = jump.site
    if is_diffusion(p, jump)
        update_rates_after_diffusion!(p, u, t, site, jump.target_site, jump.index)
        #TODO draw new times
    else
        update_rates_after_reaction!(p, u, t, site, reaction_id_from_jump(p,jump))
        # draw new firing time for site
        site_rate = get_site_rate(cur_rates, site)
        if site_rate > zero(typeof(site_rate))
            update!(p.pq, site, t + randexp(p.rng) / site_rate)
        else
            update!(p.pq, site, typemax(t))
        end
    end
end

######################## helper routines for all spatial SSAs ########################
function update_rates_after_reaction!(p, u, t, site, reaction_id)
    @inbounds dep_rxs = p.dep_gr[p.reaction_id]
    @unpack cur_rates, ma_jumps = p

    @inbounds for rx in dep_rxs
        rate = evalrxrate(u, reaction_id, ma_jumps)
        set_site_reaction_rate!(cur_rates, site, reaction_id, rate)
    end
end

function update_rates_after_diffusion!(p, u, t, source_site, target_site, species)
    #TODO figure out which reactions depend on the species, update their rates in both sites, draw new times for both sites
    # use var_to_jumps_map from rssa
end

"""
update_state!(p, integrator)

updates state based on p.next_jump
"""
function update_state!(p, integrator)
    jump = p.next_jump
    if is_diffusion(p, jump)
        execute_diffusion!(integrator, jump.site, jump.target_site, jump.index)
    else
        rx_index = reaction_id_from_jump(p,jump)
        executerx!(integrator.u[:,jump.site], rx_index, p.ma_jumps)
    end
    # save jump that was just exectued
    p.prev_jump = jump
    return integrator.u
end

"""
    is_diffusion(p, jump)

true if jump is a diffusion
"""
function is_diffusion(p, jump)
    jump.index <= length(p.diffusion_constants[:,jump.site])
end

"""
    execute_diffusion!(integrator, jump)

documentation
"""
function execute_diffusion!(integrator, source_site, target_site, species)
    integrator.u[species,source_site] -= 1
    integrator.u[species,target_site] += 1
end

"""
    reaction_id_from_jump(p,jump)

return reaction id by subtracting the number of diffusive hops
"""
function reaction_id_from_jump(p,jump)
    jump.index - length(p.diffusion_constants[:,jump.site])
end
