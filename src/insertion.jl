export HierarchicalNSW
export knn_search
export Neighbor
export NeighborSet

mutable struct HierarchicalNSW{T, TF, V <: AbstractVector{<:AbstractVector{TF}}, M}
    lgraph::LayeredGraph{T}#Vector{SimpleGraph{T}}
    data::V
    ep::T
    ep_lock::Mutex
    vlp::VisitedListPool
    metric::M#Metric
    m_L::Float64
    efConstruction::Float64 #size of dynamic candidate list
    indices
end

function HierarchicalNSW(data;
        metric=Euclidean(),
        indices=eachindex(data),
        M = 10, #5 to 48
        maxM = M,
        maxM0 = 2M,
        m_L = 1/log(M),
        efConstruction = 100,
        threaded=false)
    N = maximum(indices)
    T = N <= typemax(UInt32) ? UInt32 : UInt64
    lgraph = LayeredGraph{T}(N, maxM0,maxM)
    ep = T(0)
    TF = eltype(data[1])
    visited = VisitedListPool(1,N)
    hnsw = HierarchicalNSW{T,TF,typeof(data),typeof(metric)}(lgraph, data,ep,Mutex(), visited, metric, m_L,efConstruction,indices)

    levels = [get_random_level(hnsw) for i ∈ 1:maximum(indices)]
    if threaded == true
        println("multithreading does not work yet")
        #Threads.@threads for i ∈ 1:maximum(indices)#indices
        #    insert_point!(hnsw, i, levels[i])
        #end
    else
        #This index thing is wrong
        for i ∈ 1:maximum(indices)#indices
            insert_point!(hnsw, i, levels[i])
        end
    end
    return hnsw
end


get_enter_point(hnsw::HierarchicalNSW) = hnsw.ep
set_enter_point!(hnsw::HierarchicalNSW, ep) = hnsw.ep = ep
get_top_layer(hnsw::HierarchicalNSW) = length(hnsw.lgraph)
get_random_level(hnsw) = floor(Int, -log(rand())* hnsw.m_L) + 1

distance(hnsw::HierarchicalNSW, i, j) = @inbounds evaluate(hnsw.metric, hnsw.data[i], hnsw.data[j])
distance(hnsw::HierarchicalNSW, i, q::AbstractVector) = @inbounds evaluate(hnsw.metric, hnsw.data[i], q)
distance(hnsw::HierarchicalNSW, q::AbstractVector, j) = @inbounds evaluate(hnsw.metric, hnsw.data[j], q)


function insert_point!(
        hnsw::HierarchicalNSW, #multilayer graph
        q, #new element (index)
        l = get_random_level(hnsw)
        #M, #number of established connections
        )
    lock(hnsw.ep_lock)
        ep = get_enter_point(hnsw)
        L =  get_top_layer(hnsw)  #top layer of hnsw
        add_vertex!(hnsw.lgraph, q, l)
        if ep == 0 #this needs to be locked
            set_enter_point!(hnsw, q)
            unlock(hnsw.ep_lock)
            return nothing
        end
    unlock(hnsw.ep_lock)
    epN = Neighbor(ep, distance(hnsw, ep, q))
    #Find nearest point within each layer and traverse down
    for level ∈ L:-1:l+1
        #TODO: better implementation for upper layers where ef=1
        W = search_layer(hnsw, q, epN, 1,level)
        epN = nearest(W) #nearest element from q in W
    end
    for level ∈ min(L,l):-1:1
        #println("inserting $q on layer $level")
        #println("enterpoint is $epN")
        W = search_layer(hnsw, q, epN, hnsw.efConstruction, level)
        W = neighbor_heuristic(hnsw, level, W)
        add_connections!(hnsw, level, q, W)
        #println("adding connections to $q : $(W.neighbor)")
        #println("resulting connections")
        #println(hnsw.lgraph.linklist)
        epN = nearest(W)
    end
    if l > L
        set_enter_point!(hnsw, q) #set enter point for hnsw to q
    end
    return nothing
end

function search_layer(
        hnsw,
        q, # Query point
        ep, # enter point + distance
        ef, # number of elements to return
        level)
    lg = hnsw.lgraph
    vl = get_list(hnsw.vlp)
    visit!(vl, ep) #visited elements
    C = NeighborSet(ep) #set of candidates
    W = NeighborSet(ep) #dynamic list of found nearest neighbors
    while length(C) > 0
        c = pop_nearest!(C) # from q in C
        if c.dist > furthest(W).dist
            break
            #This is the stopping condition.
            #All points are initially both in C and W
            #If the above condition is met, then W is already long enough
            #AND due to "c = pop_nearest!(C)" we know that
            #all points in W (closer than c) have been investigated

            # We therefore assume that this link will not have any connections
            # closer to q that have not been visited
        end
        lock(lg.locklist[c.idx])
            for e ∈ neighbors(lg, c.idx, level)  #Update C and W
                if !isvisited(vl, e)
                    visit!(vl, e)
                    dist =  distance(hnsw,q,e)
                    eN = Neighbor(e, dist)
                    f = furthest(W)
                    if eN.dist < f.dist || length(W) < ef
                        insert!(C, eN)
                        insert!(W, eN)
                        if length(W) > ef
                            pop_furthest!(W)
                        end
                    end
                end
            end
        unlock(lg.locklist[c.idx])
    end
    release_list(hnsw.vlp, vl)
    return W #ef closest neighbors
end

#Alg 5

function knn_search(
        hnsw::HierarchicalNSW{T}, #multilayer graph
        q, # query
        K, #number of nearest neighbors to return
        ef # size of dynamic list
        ) where {T}
    @assert length(q)==length(hnsw.data[1])
    ep = get_enter_point(hnsw)
    ep = Neighbor(ep, distance(hnsw, q, ep))
    L = get_top_layer(hnsw) #layer of ep , top layer of hnsw
    for l_c ∈ L:-1:2 # Iterate from top to second lowest
        ep = search_layer(hnsw, q, ep, 1, l_c)[1]
        #TODO: better upper layer implementation here as well
    end
    W = search_layer(hnsw, q, ep, ef, 1)
    list = nearest(W, K)
    idx = map(x->x.idx, list)
    dist = map(x->x.dist, list)
    return idx, dist# K nearest elements to q
end

function knn_search(hnsw::HierarchicalNSW{T,TF}, #multilayer graph
        q::AbstractVector{<:AbstractVector}, # query
        K, #number of nearest neighbors to return
        ef # size of dynamic list
        ) where {T,TF}
    idxs = Vector{Vector{T}}(undef,length(q))
    dists = Vector{Vector{TF}}(undef,length(q))
    ef = max(K, ef)
    for n = 1:length(q)
        idxs[n], dists[n] = knn_search(hnsw, q[n], K, ef)
    end
    idxs, dists
end

function neighbor_heuristic(
        hnsw,
        level,
        W) # candidate elements
    M = max_connections(hnsw.lgraph, level)
    if length(W) <= M return W end
    R = typeof(W)() #Selected Neighbors
    W_d = typeof(W)() #Temporarily discarded candidates

    for e ∈ W.neighbor
        if length(R) >= M break end
        #Compute distances to already selected points
        good = true
        for r ∈ R.neighbor
            if e.dist > distance(hnsw, e.idx, r.idx)
                good=false
                break
            end
        end
        if good#e is closer to q compared to any element from R
            insert!(R, e) # I know it comes first. Possible Op. `pushfirst!`
        else
            insert!(W_d, e)
        end
    end
    for w ∈ W_d.neighbor
        if length(R) >= M break end
        insert!(R, w)
    end
    return R
end
