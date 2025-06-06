export GraphSpace, GraphAgent
using Graphs: nv, ne

#######################################################################################
# Basic space definition
#######################################################################################
struct GraphSpace{G} <: DiscreteSpace
    graph::G
    stored_ids::Vector{Vector{Int}}
end

"""
    GraphSpace(graph::AbstractGraph)
Create a `GraphSpace` instance that is underlined by an arbitrary graph from
[Graphs.jl](https://github.com/JuliaGraphs/Graphs.jl).
`GraphSpace` represents a space where each node (i.e. position) of a graph can hold an
arbitrary amount of agents, and each agent can move between the nodes of the graph.
The position type for this space is `Int`, use [`GraphAgent`](@ref) for convenience.

`GraphSpace` inherits from `DiscreteSpace` and all functions for [`DiscreteSpace`](@ref DiscreteSpace_exclusives)
are available. On top of that, `Graphs.nv` and `Graphs.ne` can be used in a model
with a `GraphSpace` to obtain the number of nodes or edges in the graph.
The underlying graph can be altered using [`add_vertex!`](@ref) and [`rem_vertex!`](@ref).

An example using `GraphSpace` is [SIR model for the spread of COVID-19](@ref).

!!! note "Not for social networks!"
    `GraphSpace` is not intended for "social-network-like" agent based
    modelling, where each agent is equivalent with a node of a network/graph and
    the graph represents connections between agents. Rather, `GraphSpace` is
    suitable for when the coordinates of spatial locations are not as important as the
    connections between them. `GraphSpace` is suited for e.g., modelling cities
    where each can host many agents.

    If you want to make a "social-network" like simulation, see [the integration with
    Graphs.jl example](@ref social_networks). Typically you won't need a space structure at all!


## Distance specification

In functions like [`nearby_ids`](@ref), distance for `GraphSpace` means
the degree of neighbors in the graph (thus distance is always an integer).
For example, for `r=2` includes first and second degree neighbors.
For 0 distance, the search occurs only on the origin node.

In functions like [`nearby_ids`](@ref) the keyword `neighbor_type=:default` can be used
to select differing neighbors depending on the underlying graph directionality type.
- `:default` returns neighbors of a vertex (position). If graph is directed, this is
  equivalent to `:out`. For undirected graphs, all options are equivalent to `:out`.
- `:all` returns both `:in` and `:out` neighbors.
- `:in` returns incoming vertex neighbors.
- `:out` returns outgoing vertex neighbors.
"""
function GraphSpace(graph::G) where {G <: AbstractGraph}
    agent_positions = [Int[] for _ in 1:nv(graph)]
    return GraphSpace{G}(graph, agent_positions)
end

function Base.show(io::IO, s::GraphSpace)
    print(io, "GraphSpace with $(nv(s.graph)) positions and $(ne(s.graph)) edges")
end

"""
    GraphAgent <: AbstractAgent
The minimal agent struct for usage with [`GraphSpace`](@ref).
It has an additional `pos::Int` field. See also [`@agent`](@ref).
"""
@agent struct GraphAgent(NoSpaceAgent)
    pos::Int
end

#######################################################################################
# Agents.jl space API
#######################################################################################
random_position(model::ABM{<:GraphSpace}) = rand(abmrng(model), 1:nv(model))

function remove_agent_from_space!(a::AbstractAgent, model::ABM{<:GraphSpace})
    agentpos = a.pos
    ids = ids_in_position(agentpos, model)
    ai = findfirst(id -> id == a.id, ids)
    isnothing(ai) && error(lazy"Tried to remove agent with ID $(a.id) from the space, but that agent is not on the space")
    deleteat!(ids, ai)
    return a
end

function add_agent_to_space!(agent::AbstractAgent, model::ABM{<:GraphSpace})
    push!(ids_in_position(agent.pos, model), agent.id)
    return agent
end

# The following is for the discrete space API:
npositions(space::GraphSpace) = nv(space.graph)
positions(space::GraphSpace) = 1:npositions(space)
ids_in_position(n::Integer, model::ABM{<:GraphSpace}) = ids_in_position(n, abmspace(model))
ids_in_position(n::Integer, space::GraphSpace) = space.stored_ids[n]

# NOTICE: The return type of `ids_in_position` must support `length` and `isempty`!

#######################################################################################
# Neighbors
#######################################################################################
function nearby_ids(pos::Int, model::ABM{<:GraphSpace}, r = 1; kwargs...)
    np = nearby_positions(pos, model, r; kwargs...)
    vcat(abmspace(model).stored_ids[pos], abmspace(model).stored_ids[np]...)
end

# This function is here purely because of performance reasons
function nearby_ids(agent::AbstractAgent, model::ABM{<:GraphSpace}, r = 1; kwargs...)
    all = nearby_ids(agent.pos, model, r; kwargs...)
    filter!(i -> i ≠ agent.id, all)
end

function nearby_positions(
    position::Int,
    model::ABM{<:GraphSpace};
    neighbor_type::Symbol = :default,
)
    @assert neighbor_type ∈ (:default, :all, :in, :out)
    if neighbor_type == :default
        Graphs.neighbors(abmspace(model).graph, position)
    elseif neighbor_type == :in
        Graphs.inneighbors(abmspace(model).graph, position)
    elseif neighbor_type == :out
        Graphs.outneighbors(abmspace(model).graph, position)
    else
        Graphs.all_neighbors(abmspace(model).graph, position)
    end
end

#######################################################################################
# Mutable graph functions
#######################################################################################
export rem_vertex!, add_vertex!, add_edge!, rem_edge!

"""
    rem_vertex!(model::ABM{<:GraphSpace}, n::Int)
Remove node (i.e. position) `n` from the model's graph. All agents in that node are removed from the model.

**Warning:** Graphs.jl (and thus Agents.jl) swaps the index of the last node with
that of the one to be removed, while every other node remains as is. This means that
when doing `rem_vertex!(n, model)` the last node becomes the `n`-th node while the previous
`n`-th node (and all its edges and agents) are deleted.
"""
function Graphs.rem_vertex!(model::ABM{<:GraphSpace}, n::Int)
    for id in copy(ids_in_position(n, model))
        remove_agent!(model[id], model)
    end
    V = nv(model)
    success = Graphs.rem_vertex!(abmspace(model).graph, n)
    n > V && error("Node number exceeds amount of nodes in graph!")
    s = abmspace(model).stored_ids
    s[V], s[n] = s[n], s[V]
    pop!(s)
end

"""
    add_vertex!(model::ABM{<:GraphSpace})
Add a new node (i.e. possible position) to the model's graph and return it.
You can connect this new node with existing ones using [`add_edge!`](@ref).
"""
function Graphs.add_vertex!(model::ABM{<:GraphSpace})
    add_vertex!(abmspace(model).graph)
    push!(abmspace(model).stored_ids, Int[])
    return nv(model)
end

"""
    add_edge!(model::ABM{<:GraphSpace},  args...; kwargs...)
Add a new edge (relationship between two positions) to the graph.
Returns a boolean, true if the operation was successful.

`args` and `kwargs` are directly passed to the `add_edge!` dispatch that acts the underlying graph type.
"""
Graphs.add_edge!(model::ABM{<:GraphSpace}, args::Vararg{Any, N}; kwargs...) where {N} = add_edge!(abmspace(model).graph, args...; kwargs...)

"""
    rem_edge!(model::ABM{<:GraphSpace}, n, m)
Remove an edge (relationship between two positions) from the graph.
Returns a boolean, true if the operation was successful.
"""
Graphs.rem_edge!(model::ABM{<:GraphSpace}, n, m) = rem_edge!(abmspace(model).graph, n, m)
