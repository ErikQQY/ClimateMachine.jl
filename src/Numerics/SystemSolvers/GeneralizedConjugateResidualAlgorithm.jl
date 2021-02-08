#### Generalized Conjugate Residual Solver

export GeneralizedConjugateResidualAlgorithm

"""
    GeneralizedConjugateResidualAlgorithm(;
        preconditioner::Union{AbstractPreconditioner, Nothing} = nothing,
        atol::Union{Real, Nothing} = nothing,
        rtol::Union{Real, Nothing} = nothing,
        groupsize::Union{Int, Nothing} = nothing,
        M::Union{Int, Nothing} = nothing,
        maxrestarts::Union{Int, Nothing} = nothing,
        sarrays::Union{Bool, Nothing} = nothing,
    )

Constructor for a `GeneralizedConjugateResidualAlgorithm`, which solves an
equation of the form `f(Q) = rhs`, where `f` is assumed to be a linear function
of `Q` that can be represented by an invertible Hermitian matrix, and where
`rhs` is assumed to be nonzero.

This algorithm uses the restarted Generalized Conjugate Residual method of
Eisenstat (1983).

# Keyword Arguments
- `preconditioner`: unused; defaults to NoPreconditioner
- `atol`: absolute tolerance; defaults to `eps(eltype(Q))`
- `rtol`: relative tolerance; defaults to `√eps(eltype(Q))`
- `groupsize`: group size for kernel abstractions; defaults to `256`
- `M`: number of steps after which the algorithm restarts, and number of basis
    vectors in the Kyrlov subspace; defaults to `min(20, length(Q))`
- `maxrestarts`: maximum number of times the algorithm can restart; defaults to
    `cld(length(Q), M) - 1`, so that the maximum number of steps the algorithm
    can take is no less than `length(Q)`, while also being as close to
    `length(Q)` as possible
- `sarrays`: whether to use statically sized arrays; defaults to `true`

## References

 - [Eisenstat1983](@cite)
"""
struct GeneralizedConjugateResidualAlgorithm <: KrylovAlgorithm
    preconditioner
    atol
    rtol
    groupsize
    M
    maxrestarts
    sarrays
    function GeneralizedConjugateResidualAlgorithm(;
        preconditioner::Union{AbstractPreconditioner, Nothing} = nothing,
        atol::Union{Real, Nothing} = nothing,
        rtol::Union{Real, Nothing} = nothing,
        groupsize::Union{Int, Nothing} = nothing,
        M::Union{Int, Nothing} = nothing,
        maxrestarts::Union{Int, Nothing} = nothing,
        sarrays::Union{Bool, Nothing} = nothing,
    )
        @checkargs("be positive", arg -> arg > 0, atol, rtol, groupsize, M)
        @checkargs("be nonnegative", arg -> arg >= 0, maxrestarts)
        return new(preconditioner, atol, rtol, groupsize, M, maxrestarts, sarrays)
    end
end

struct GeneralizedConjugateResidualSolver{PT, FT, AT1, AT2, AT3} <: IterativeSolver
    preconditioner::PT
    residual::AT1
    L_residual::AT1         # L(residual)
    p::AT2                  # descent direction
    L_p::AT2                # L(p): linear operator applied to p
    α::AT3                  # descent update weights
    normsq::AT3             # stores ||L_p||^2
    atol::FT                # relative tolerance
    rtol::FT                # absolute tolerance
    groupsize::Int          # group size for kernel abstractions
    M::Int                  # number of steps after which the algorithm restarts
    maxrestarts::Int        # maximum number of times the algorithm can restart
end

function IterativeSolver(
    algorithm::GeneralizedConjugateResidualAlgorithm,
    Q,
    f!,
    rhs,
)
    check_krylov_args(Q, rhs)
    FT = eltype(Q)

    preconditioner = isnothing(algorithm.preconditioner) ? NoPreconditioner() :
        algorithm.preconditioner
    atol = isnothing(algorithm.atol) ? eps(FT) : FT(algorithm.atol)
    rtol = isnothing(algorithm.rtol) ? √eps(FT) : FT(algorithm.rtol)
    groupsize = isnothing(algorithm.groupsize) ? 256 : algorithm.groupsize
    M = isnothing(algorithm.M) ? min(20, length(Q)) : algorithm.M
    maxrestarts = isnothing(algorithm.maxrestarts) ?
        cld(length(Q), M) - 1 : algorithm.maxrestarts
    sarrays = isnothing(algorithm.sarrays) ? true : algorithm.sarrays

    return GeneralizedConjugateResidualSolver(
        preconditioner,
        similar(Q),
        similar(Q),
        ntuple(i -> similar(Q), M),
        ntuple(i -> similar(Q), M),
        sarrays ? (@MArray zeros(FT, M)) : zeros(FT, M),
        sarrays ? (@MArray zeros(FT, M)) : zeros(FT, M),
        atol,
        rtol,
        groupsize,
        M,
        maxrestarts,
    )
end

atol(solver::GeneralizedConjugateResidualSolver) = solver.atol
rtol(solver::GeneralizedConjugateResidualSolver) = solver.rtol
maxiters(solver::GeneralizedConjugateResidualSolver) = solver.maxrestarts + 1

function residual!(
    solver::GeneralizedConjugateResidualSolver,
    threshold,
    iters,
    Q,
    f!,
    rhs,
    args...,
)
    residual_norm = norm(solver.residual, weighted_norm)
    converged = check_convergence(residual_norm, threshold, iters)
    return residual_norm, converged
end

function initialize!(
    solver::GeneralizedConjugateResidualSolver,
    threshold,
    iters,
    Q,
    f!,
    rhs,
    args...,
)
    residual = solver.residual
    p = solver.p
    L_p = solver.L_p

    @assert size(Q) == size(residual)
    
    f!(residual, Q, args...)
    residual .-= rhs
    residual_norm, converged = residual!(solver, threshold, iters, Q, f!, rhs, args...)

    # initialize descent direction
    if !converged
        p[1] .= residual
        f!(L_p[1], p[1], args...)
    end
    
    return residual_norm, converged
end

function doiteration!(
    solver::GeneralizedConjugateResidualSolver,
    threshold,
    iters,
    Q,
    f!,
    rhs,
    args...;
)
    residual = solver.residual
    p = solver.p
    L_residual = solver.L_residual
    L_p = solver.L_p
    normsq = solver.normsq
    α = solver.α
    M = solver.M
    
    k = 1
    for outer k in 1:M
        # update Q
        normsq[k] = norm(L_p[k], weighted_norm)^2
        β = -dot(residual, L_p[k], weighted_norm) / normsq[k]

        Q .+= β * p[k]
        residual .+= β * L_p[k]

        # convergence check
        residual_norm, converged = residual!(solver, threshold, iters, Q, f!, rhs, args...)
        if converged return converged, k end

        # update descent direction
        f!(L_residual, residual, args...)

        for l in 1:k
            α[l] = -dot(L_residual, L_p[l], weighted_norm) / normsq[l]
        end

        if k < M
            rv_nextp = realview(p[k + 1])
            rv_L_nextp = realview(L_p[k + 1])
        else # restart
            rv_nextp = realview(p[1])
            rv_L_nextp = realview(L_p[1])
        end

        rv_residual = realview(residual)
        rv_p = realview.(p)
        rv_L_p = realview.(L_p)
        rv_L_residual = realview(L_residual)

        groupsize = solver.groupsize
        FT = eltype(α)

        event = Event(array_device(Q))
        event = linearcombination!(array_device(Q), groupsize)(
            rv_nextp,
            (one(FT), α[1:k]...),
            (rv_residual, rv_p[1:k]...),
            false;
            ndrange = length(rv_nextp),
            dependencies = (event,),
        )

        event = linearcombination!(array_device(Q), groupsize)(
            rv_L_nextp,
            (one(FT), α[1:k]...),
            (rv_L_residual, rv_L_p[1:k]...),
            false;
            ndrange = length(rv_nextp),
            dependencies = (event,),
        )
        wait(array_device(Q), event)
    end

    return false, k
end