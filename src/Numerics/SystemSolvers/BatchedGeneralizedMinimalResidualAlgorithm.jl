export BatchedGeneralizedMinimalResidualAlgorithm

# TODO: Determine whether we should use PermutedDimsArray. Since permutedims!()
#       internally creates a PermutedDimsArray and calls _copy!() on it,
#       directly using a PermutedDimsArray might be much more efficient.
#       This might make it possible to eliminate initnewbasisvec and
#       lastbasisvec; another way to get rid of them would be to let a
#       DGModel execute batched operations. Here is how the PermutedDimsArray
#       version could work:
#     perm = invperm((batchdimindices..., remainingdimindices...))
#     batchsize = prod(dims[[batchdimindices...]])
#     nbatches = prod(dims[[remainingdimindices...]])
#     ΔQ = similar(Q)
#     ΔQs = reshape(
#         PermutedDimsArray(reshape(realview(ΔQ), dims), perm),
#         (batchsize, nbatches)
#     )
#     krylovbasis = ntuple(i -> similar(Q), M + 1)
#     krylovbases = ntuple(
#         i -> reshape(
#             PermutedDimsArray(reshape(realview(krylovbasis[i]), dims), perm),
#             (batchsize, nbatches)
#         ),
#         M + 1
#     )

# A useful struct that can transform an array into a batched format and back.
# If forward_reshape is the same as the array's original size, the reshape()
# calls do nothing, and only the permutedims!() calls have any effect.
# Otherwise, the reshape() calls make new arrays with the same underlying data.
# If the dimensions are not permuted (forward_permute == backward_permute), the
# permutedims!() calls just call copyto!(). If unbatched is already in batched
# form, reshape() does nothing and permutedims!() calls copyto!(), which is
# quite inefficient; it would be better to make batched and unbatched the same
# array in this situation.
# TODO: Maybe write an edge case to handle the last situation more efficiently.
struct Batcher{T}
    forward_reshape::T
    forward_permute::T
    backward_reshape::T
    backward_permute::T
end
function Batcher(forward_reshape, forward_permute)
    return Batcher(
        forward_reshape,
        forward_permute,
        forward_reshape[[forward_permute...]],
        invperm(forward_permute),
    )
end
function batch!(batched, unbatched, b::Batcher)
    reshaped_batched = reshape(batched, b.backward_reshape)
    reshaped_unbatched = reshape(unbatched, b.forward_reshape)
    permutedims!(reshaped_batched, reshaped_unbatched, b.forward_permute)
    return nothing
end
function unbatch!(unbatched, batched, b::Batcher)
    reshaped_batched = reshape(batched, b.backward_reshape)
    reshaped_unbatched = reshape(unbatched, b.forward_reshape)
    permutedims!(reshaped_unbatched, reshaped_batched, b.backward_permute)
    return nothing
end

"""
    BatchedGeneralizedMinimalResidualAlgorithm(
        preconditioner::Union{AbstractPreconditioner, Nothing} = nothing,
        atol::Union{AbstractFloat, Nothing} = nothing,
        rtol::Union{AbstractFloat, Nothing} = nothing,
        groupsize::Union{Int, Nothing} = nothing,
        coupledstates::Union{Bool, Nothing} = nothing,
        dims::Union{Dims, Nothing} = nothing,
        batchdimindices::Union{Dims, Nothing} = nothing,
        M::Union{Int, Nothing} = nothing,
        maxrestarts::Union{Int, Nothing} = nothing,
    )

Constructor for the `BatchedGeneralizedMinimalResidualAlgorithm`, which solves
an equation of the form `f(Q) = rhs`, where `f` is assumed to be a linear
function of `Q`.
    
If the equation can be broken up into smaller independent linear systems of
equal size, this algorithm can solve those linear systems in parallel, using
the restarted Generalized Minimal Residual method of Saad and Schultz (1986) to
solve each system.

## References

 - [Saad1986](@cite)

# Keyword Arguments
- `preconditioner`: right preconditioner; defaults to `NoPreconditioner`
- `atol`: absolute tolerance; defaults to `eps(eltype(Q))`
- `rtol`: relative tolerance; defaults to `√eps(eltype(Q))`
- `groupsize`: group size for kernel abstractions; defaults to `256`
- `coupledstates`: only used when `f` contains a `DGModel`; indicates whether
    the states in the `DGModel` are coupled to each other; defaults to `true`
- `dims`: dimensions from which to select batch dimensions; does not need to
    match the actual dimensions of `Q`, but must have the property that
    `prod(dims) == length(Q)`; defaults to `size(Q)` when `f` does not use a
    `DGModel`, `(npoints, nstates, nelems)` when `f` uses a `DGModel` with
    `EveryDirection`, and `(nhorzpoints, nvertpoints, nstates, nvertelems,
    nhorzelems)` when `f` uses a `DGModel` with `HorizontalDirection` or
    `VerticalDirection`; default value will be used unless `batchdimindices` is
    also specified
- `batchdimindices`: indices of dimensions in `dims` that form each batch; is
    assumed to define batches that form independent linear systems; defaults to
    `Tuple(1:ndims(Q))` when `f` does not use a `DGModel`, `(1, 2, 3)` or
    `(1, 3)` when `f` uses a `DGModel` with `EveryDirection` (the former for
    coupled states and the latter for uncoupled states), `(1, 3, 5)` or
    `(1, 5)` when `f` uses a `DGModel` with `HorizontalDirection`, and
    `(2, 3, 4)` or `(2, 4)` when `f` uses a `DGModel` with `VerticalDirection`;
    default value will be used unless `dims` is also specified
- `M`: number of steps after which the algorithm restarts, and number of basis
    vectors in each Kyrlov subspace; defaults to `min(20, batchsize)`, where
    `batchsize` is the number of elements in each batch
- `maxrestarts`: maximum number of times the algorithm can restart; defaults to
    `cld(batchsize, M) - 1`, so that the maximum number of steps the algorithm
    can take is no less than `batchsize`, while also being as close to
    `batchsize` as possible
"""
struct BatchedGeneralizedMinimalResidualAlgorithm <: KrylovAlgorithm
    preconditioner
    atol
    rtol
    groupsize
    coupledstates
    dims
    batchdimindices
    M
    maxrestarts
    function BatchedGeneralizedMinimalResidualAlgorithm(;
        preconditioner::Union{AbstractPreconditioner, Nothing} = nothing,
        atol::Union{AbstractFloat, Nothing} = nothing,
        rtol::Union{AbstractFloat, Nothing} = nothing,
        groupsize::Union{Int, Nothing} = nothing,
        coupledstates::Union{Bool, Nothing} = nothing,
        dims::Union{Dims, Nothing} = nothing,
        batchdimindices::Union{Dims, Nothing} = nothing,
        M::Union{Int, Nothing} = nothing,
        maxrestarts::Union{Int, Nothing} = nothing,
    )
        @checkargs("be positive", arg -> arg > 0, atol, rtol, groupsize, M)
        @checkargs("be nonnegative", arg -> arg >= 0, maxrestarts)
        @checkargs(
            "contain positive values",
            arg -> length(arg) > 0 && minimum(arg) > 0, dims, batchdimindices,
        )
        @checkargs(
            "contain unique indices", arg -> allunique(arg), batchdimindices,
        )
    
        if xor(isnothing(dims), isnothing(batchdimindices))
            @warn string(
                "Both dims and batchdimindices must be specified in order to ",
                "override their default values.",
            )
        end
        if !isnothing(dims) && !isnothing(batchdimindices)
            @assert(maximum(batchdimindices) <= length(dims), string(
                "batchdimindices must contain the indices of dimensions in ",
                "dims, $dims, but it was set to $batchdimindices",
            ))
        end
    
        return new(
            preconditioner,
            atol,
            rtol,
            groupsize,
            coupledstates,
            dims,
            batchdimindices,
            M,
            maxrestarts,
        )
    end
end

function defaultbatches(Q, f!::Any, coupledstates)
    @warn string(
        "All computations will be done on a single batch.\nIf this was not ",
        "intended, consider using a GeneralizedMinimalResidualAlgorithm ",
        "instead of a BatchedGeneralizedMinimalResidualAlgorithm.",
    )
    return size(Q), Tuple(1:ndims(Q))
end

defaultbatches(Q, jvp!::JacobianVectorProduct, coupledstates) =
    defaultbatches(Q, jvp!.f!, coupledstates)

function defaultbatches(Q, dg::DGModel, coupledstates)
    direction = dg.direction
    grid = dg.grid
    topology = grid.topology
    N = polynomialorders(grid)
    nvertpoints = N[end] + 1
    nhorzpoints = length(N) == 3 ? (N[1] + 1) * (N[2] + 1) : N[1] + 1
    nstates = size(Q)[2] # This could be obtained from dg with number_states.
    nelems = length(topology.realelems)
    nvertelems = topology.stacksize
    nhorzelems = div(nelems, nvertelems)

    if isa(direction, EveryDirection)
        dims = (nhorzpoints * nvertpoints, nstates, nelems)
        if coupledstates
            @warn string(
                "DGModel uses EveryDirection and has coupled states, so all ",
                "computations will be done on a single batch.\nTo use ",
                "multiple batches, either limit the directionality or set ",
                "coupledstates = false.\nIf this is not possible, consider ",
                "using a GeneralizedMinimalResidualAlgorithm instead of a ",
                "BatchedGeneralizedMinimalResidualAlgorithm.",
            )
            batchdimindices = (1, 2, 3)
        else
            batchdimindices = (1, 3)
        end
    else
        dims = (nhorzpoints, nvertpoints, nstates, nvertelems, nhorzelems)
        if isa(direction, HorizontalDirection)
            batchdimindices = coupledstates ? (1, 3, 5) : (1, 5)
        else # VerticalDirection
            batchdimindices = coupledstates ? (2, 3, 4) : (2, 4)
        end
    end

    return dims, batchdimindices
end

struct BatchedGeneralizedMinimalResidualSolver{BT, PT, AT, BAT, BMT, FT} <:
        IterativeSolver
    batcher::BT           # batcher that can transform, e.g., initnewbasisvec
                          # to initnewbasisvecs
    preconditioner::PT    # right preconditioner
    lastbasisvec::AT      # container for last Krylov basis vectors in
                          # unbatched form
    initnewbasisvec::AT   # container for initial values of new Krylov basis
                          # vectors in unbatched form
    initnewbasisvecs::BAT # container for initial value of new Krylov basis
                          # vector of each batch
    krylovbases::BMT      # container for Krylov basis of each batch
    g0s::BAT              # container for right-hand side of least squares
                          # problem of each batch
    Hs::BMT               # container for Hessenberg matrix of each batch
    Ωs::BAT               # container for Givens rotation matrix of each batch
    atol::FT              # absolute tolerance
    rtol::FT              # relative tolerance
    groupsize::Int        # group size for kernel abstractions
    batchsize::Int        # number of elements in each batch
    nbatches::Int         # number of batches
    M::Int                # number of steps after which the algorithm restarts
    maxrestarts::Int      # maximum number of times the algorithm can restart
end

function IterativeSolver(
    algorithm::BatchedGeneralizedMinimalResidualAlgorithm,
    Q,
    f!,
    rhs,
)
    check_krylov_args(Q, rhs)
    if !isnothing(algorithm.dims)
        @assert(prod(dims) == length(Q), string(
            "dims must contain the dimensions of an array with the same ",
            "length as Q, $(length(Q)), but it was set to $dims",
        ))
    end
    FT = eltype(Q)

    preconditioner = isnothing(algorithm.preconditioner) ?
        NoPreconditioner() : algorithm.preconditioner
    atol = isnothing(algorithm.atol) ? eps(FT) : FT(algorithm.atol)
    rtol = isnothing(algorithm.rtol) ? √eps(FT) : FT(algorithm.rtol)
    groupsize = isnothing(algorithm.groupsize) ? 256 : algorithm.groupsize
    coupledstates = isnothing(algorithm.coupledstates) ?
        true : algorithm.coupledstates
    
    dims, batchdimindices =
        isnothing(algorithm.dims) || isnothing(algorithm.batchdimindices) ?
        defaultbatches(Q, f!, coupledstates) :
        (algorithm.dims, algorithm.batchdimindices)
    remainingdimindices = Tuple(setdiff(1:length(dims), batchdimindices))
    batchsize = prod(dims[[batchdimindices...]])
    nbatches = prod(dims[[remainingdimindices...]])

    M = isnothing(algorithm.M) ? min(20, batchsize) : algorithm.M
    maxrestarts = isnothing(algorithm.maxrestarts) ?
        cld(length(Q), M) - 1 : algorithm.maxrestarts # Change length(Q) to batchsize after comparison testing.

    rvQ = realview(Q)
    return BatchedGeneralizedMinimalResidualSolver(
        Batcher(dims, (batchdimindices..., remainingdimindices...)),
        preconditioner,
        similar(Q),
        similar(Q),
        similar(rvQ, batchsize, nbatches),
        similar(rvQ, batchsize, M + 1, nbatches),
        similar(rvQ, M + 1, nbatches),
        similar(rvQ, M + 1, M, nbatches),
        similar(rvQ, 2 * M, nbatches),
        atol,
        rtol,
        groupsize,
        batchsize,
        nbatches,
        M,
        maxrestarts,
    )
end

atol(solver::BatchedGeneralizedMinimalResidualSolver) = solver.atol
rtol(solver::BatchedGeneralizedMinimalResidualSolver) = solver.rtol
maxiters(solver::BatchedGeneralizedMinimalResidualSolver) = solver.maxrestarts + 1

function residual!(
    solver::BatchedGeneralizedMinimalResidualSolver,
    threshold,
    iters,
    Q,
    f!,
    rhs,
    args...;
)
    initnewbasisvec = solver.initnewbasisvec
    initnewbasisvecs = solver.initnewbasisvecs
    krylovbases = solver.krylovbases
    g0s = solver.g0s
    device = array_device(Q)
    
    # Compute the residual and store its batches in initnewbasisvecs[:, :].
    f!(initnewbasisvec, Q, args...)
    initnewbasisvec .= rhs .- initnewbasisvec
    batch!(initnewbasisvecs, realview(initnewbasisvec), solver.batcher)

    # Calculate krylovbases[:, 1, :] and g0s[:, :] in batches.
    event = Event(device)
    event = batched_residual!(device, solver.groupsize)(
        initnewbasisvecs,
        krylovbases,
        g0s,
        solver.M,
        solver.batchsize;
        ndrange = solver.nbatches,
        dependencies = (event,),
    )
    wait(device, event)

    # Check whether the algorithm has already converged.
    residual_norm = maximum(view(g0s, 1, :)) # TODO: Make this norm(view(g0s, 1, :)), since the overall norm is the norm of the batch norms.
    has_converged = check_convergence(residual_norm, threshold, iters)

    return residual_norm, has_converged
end

function initialize!(
    solver::BatchedGeneralizedMinimalResidualSolver,
    threshold,
    iters,
    args...;
)
    return residual!(solver, threshold, iters, args...)
end

function doiteration!(
    solver::BatchedGeneralizedMinimalResidualSolver,
    threshold,
    iters,
    Q,
    f!,
    rhs,
    args...;
)
    preconditioner = solver.preconditioner
    lastbasisvec = solver.lastbasisvec
    initnewbasisvec = solver.initnewbasisvec
    initnewbasisvecs = solver.initnewbasisvecs
    krylovbases = solver.krylovbases
    g0s = solver.g0s
    Hs = solver.Hs
    Ωs = solver.Ωs
    device = array_device(Q)

    has_converged = false
    m = 0
    while !has_converged && m < solver.M
        m += 1

        # Unbatch the previous Krylov basis vector.
        unbatch!(
            realview(lastbasisvec),
            view(krylovbases, :, m, :),
            solver.batcher,
        )

        # Apply the right preconditioner to the previous Krylov basis vector.
        preconditioner_solve!(preconditioner, lastbasisvec)

        # Apply the linear operator to get the initial value of the current
        # Krylov basis vector.
        f!(initnewbasisvec, lastbasisvec, args...)

        # Batch the initial value of the current Krylov basis vector.
        batch!(initnewbasisvecs, realview(initnewbasisvec), solver.batcher)

        # Calculate krylovbases[:, m + 1, :], g0s[m:m + 1, :],
        # Hs[1:m + 1, m, :], and Ωs[2 * m - 1:2 * m, :] in batches.
        event = Event(device)
        event = batched_arnoldi_iteration!(device, solver.groupsize)(
            initnewbasisvecs,
            krylovbases,
            g0s,
            Hs,
            Ωs,
            m,
            solver.batchsize;
            ndrange = solver.nbatches,
            dependencies = (event,),
        )
        wait(device, event)
        
        # Check whether the algorithm has converged.
        has_converged = check_convergence(
            maximum(abs, view(g0s, m + 1, :)), # TODO: Make this norm(view(g0s, m + 1, :)), for the same reason as above.
            threshold,
            iters,
        )
    end

    # Temporarily use initnewbasisvec and initnewbasisvecs as containers for
    # the update vectors.
    ΔQ = initnewbasisvec
    ΔQs = initnewbasisvecs

    # Calculate ΔQs[:, :] in batches, overriding g0s[:, :] in the process.
    event = Event(device)
    event = batched_update!(device, solver.groupsize)(
        krylovbases,
        g0s,
        Hs,
        ΔQs,
        m,
        solver.batchsize;
        ndrange = solver.nbatches,
        dependencies = (event,),
    )
    wait(device, event)

    # Unbatch the update vector.
    unbatch!(realview(ΔQ), ΔQs, solver.batcher)

    # Unapply the right preconditioner.
    preconditioner_solve!(preconditioner, ΔQ)

    # Update the solution vector.
    Q .+= ΔQ

    # Restart if the algorithm did not converge.
    has_converged && return has_converged, m
    _, has_converged, =
        residual!(solver, threshold, iters, Q, f!, rhs, args...)
    return has_converged, m
end

@kernel function batched_residual!(
    initnewbasisvecs,
    krylovbases,
    g0s,
    M,
    batchsize,
)
    b = @index(Global)
    FT = eltype(g0s)

    @inbounds begin
        # Set the right-hand side vector g0s[:, b] to ∥r₀∥₂ e₁, where e₁ is the
        # unit vector along the first axis and r₀ is the initial residual of
        # batch b, which is already stored in initnewbasisvecs[:, b].
        for m in 1:M + 1
            g0s[m, b] = zero(FT)
        end
        for i in 1:batchsize
            g0s[1, b] += initnewbasisvecs[i, b]^2
        end
        g0s[1, b] = sqrt(g0s[1, b])

        # Set the first Krylov basis vector krylovbases[:, 1, b] to the
        # normalized form of initnewbasisvecs[:, b].
        for i in 1:batchsize
            krylovbases[i, 1, b] = initnewbasisvecs[i, b] / g0s[1, b]
        end
    end
end

@kernel function batched_arnoldi_iteration!(
    initnewbasisvecs,
    krylovbases,
    g0s,
    Hs,
    Ωs,
    m,
    batchsize,
)
    b = @index(Global)
    FT = eltype(g0s)

    @inbounds begin
        # Initialize the new Krylov basis vector krylovbases[:, m + 1, b] to
        # initnewbasisvecs[:, b].
        for i in 1:batchsize
            krylovbases[i, m + 1, b] = initnewbasisvecs[i, b]
        end

        # Use a modified Gram-Schmidt procedure to generate a new column of the
        # Hessenberg matrix, Hs[1:m, m, b], and make krylovbases[:, m + 1, b]
        # orthogonal to the previous Krylov basis vectors.
        for n in 1:m
            Hs[n, m, b] = zero(FT)
            for i in 1:batchsize
                Hs[n, m, b] += krylovbases[i, m + 1, b] * krylovbases[i, n, b]
            end
            for i in 1:batchsize
                krylovbases[i, m + 1, b] -= Hs[n, m, b] * krylovbases[i, n, b]
            end
        end

        # Set Hs[m + 1, m, b] to the norm of krylovbases[:, m + 1, b].
        Hs[m + 1, m, b] = zero(FT)
        for i in 1:batchsize
            Hs[m + 1, m, b] += krylovbases[i, m + 1, b]^2
        end
        Hs[m + 1, m, b] = sqrt(Hs[m + 1, m, b])

        # Normalize krylovbases[:, m + 1, b].
        for i in 1:batchsize
            krylovbases[i, m + 1, b] /= Hs[m + 1, m, b]
        end

        # TODO: Switch the negative signs on the sines after testing.

        # Apply the previous Givens rotations stored in Ωs[:, b] to the new
        # column of the Hessenberg matrix, Hs[1:m, m, b].
        for n in 1:(m - 1)
            cos = Ωs[2 * n - 1, b]
            sin = Ωs[2 * n, b]
            temp = -sin * Hs[n, m, b] + cos * Hs[n + 1, m, b]
            Hs[n, m, b] = cos * Hs[n, m, b] + sin * Hs[n + 1, m, b]
            Hs[n + 1, m, b] = temp
        end

        # Compute a new Givens rotation so that Hs[m + 1, m, b] is zeroed out:
        #     |  cos sin | |   Hs[m, m, b]   |  = | Hs[m, m, b]' |
        #     | -sin cos | | Hs[m + 1, m, b] |  = |      0       |
        cos = Hs[m, m, b]
        sin = Hs[m + 1, m, b]
        temp = sqrt(cos^2 + sin^2)
        cos /= temp
        sin /= temp
        
        # Apply the new Givens rotation to Hs[1:m + 1, m, b].
        Hs[m, m, b] = temp
        Hs[m + 1, m, b] = zero(FT)

        # Apply the new Givens rotation to the r.h.s. vector g0s[1:m + 1, b].
        temp = -sin * g0s[m, b] + cos * g0s[m + 1, b]
        g0s[m, b] = cos * g0s[m, b] + sin * g0s[m + 1, b]
        g0s[m + 1, b] = temp

        # Store the new Givens rotation in Ωs[:, b].
        Ωs[2 * m - 1, b] = cos
        Ωs[2 * m, b] = sin
    end
end

@kernel function batched_update!(
    krylovbases,
    g0s,
    Hs,
    ΔQs,
    m,
    batchsize,
)
    b = @index(Global)
    FT = eltype(g0s)

    @inbounds begin
        # Set g0s[1:m, b] to UpperTriangular(H[1:m, 1:m, b]) \ g0[1:m, b]. This
        # corresponds to the vector of coefficients y that minimizes the
        # residual norm ∥rhs - f(∑ₙ yₙ Ψₙ)∥₂, where Ψₙ is the n-th of the m
        # Krylov basis vectors.
        for n in m:-1:1
            g0s[n, b] /= Hs[n, n, b]
            for l in 1:(n - 1)
                g0s[l, b] -= Hs[l, n, b] * g0s[n, b]
            end
        end

        # Set ΔQs[:, b] to the GMRES solution vector ∑ₙ yₙ Ψₙ.
        for i in 1:batchsize
            ΔQs[i, b] = zero(FT)
        end
        for n in 1:m
            for i in 1:batchsize
                ΔQs[i, b] += g0s[n, b] * krylovbases[i, n, b]
            end
        end
    end
end