module LowStorageRungeKuttaMethod
export LowStorageRungeKutta2N
export LSRK54CarpenterKennedy, LSRK144NiegemannDiehlBusch

using GPUifyLoops
include("LowStorageRungeKuttaMethod_kernels.jl")

using ..ODESolvers
ODEs = ODESolvers
using ..SpaceMethods

"""
    LowStorageRungeKutta2N(f, RKA, RKB, RKC, Q; dt, t0 = 0)

This is a time stepping object for explicitly time stepping the differential
equation given by the right-hand-side function `f` with the state `Q`, i.e.,

```math
  \\dot{Q} = f(Q, t)
```

with the required time step size `dt` and optional initial time `t0`.  This
time stepping object is intended to be passed to the `solve!` command.

The constructor builds a low-storage Runge-Kutta scheme using 2N
storage based on the provided `RKA`, `RKB` and `RKC` coefficient arrays.

The available concrete implementations are:

  - [`LSRK54CarpenterKennedy`](@ref)
  - [`LSRK144NiegemannDiehlBusch`](@ref)
"""
struct LowStorageRungeKutta2N{F, T, RT, AT, Nstages} <: ODEs.AbstractODESolver
  "time step"
  dt::Array{RT,1}
  "time"
  t::Array{RT,1}
  "rhs function"
  rhs!::F
  "Storage for RHS during the LowStorageRungeKutta update"
  dQ::AT
  "low storage RK coefficient vector A (rhs scaling)"
  RKA::NTuple{Nstages, RT}
  "low storage RK coefficient vector B (rhs add in scaling)"
  RKB::NTuple{Nstages, RT}
  "low storage RK coefficient vector C (time scaling)"
  RKC::NTuple{Nstages, RT}

  function LowStorageRungeKutta2N(rhs!::F, RKA, RKB, RKC,
                                  Q::AT; dt, t0=0) where {F,AT<:AbstractArray}

    T = eltype(Q)
    RT = real(T)
    dt = [dt]
    t0 = [t0]

    dQ = similar(Q)
    fill!(dQ, 0)
    new{F, T, RT, AT, length(RKA)}(dt, t0, rhs!, dQ, RKA, RKB, RKC)
  end
end

ODEs.updatedt!(lsrk::LowStorageRungeKutta2N, dt) = lsrk.dt[1] = dt

function ODEs.dostep!(Q, lsrk::LowStorageRungeKutta2N, param, timeend,
                      adjustfinalstep)
  time, dt = lsrk.t[1], lsrk.dt[1]
  if adjustfinalstep && time + dt > timeend
    dt = timeend - time
    @assert dt > 0
  end
  RKA, RKB, RKC = lsrk.RKA, lsrk.RKB, lsrk.RKC
  rhs!, dQ = lsrk.rhs!, lsrk.dQ

  rv_Q = ODEs.realview(Q)
  rv_dQ = ODEs.realview(dQ)

  threads = 256
  blocks = div(length(rv_Q) + threads - 1, threads)

  for s = 1:length(RKA)
    rhs!(dQ, Q, param, time + RKC[s] * dt, increment = true)
    # update solution and scale RHS
    @launch(ODEs.device(Q), threads=threads, blocks=blocks,
            update!(rv_dQ, rv_Q, RKA[s%length(RKA)+1], RKB[s], dt))
  end
  if dt == lsrk.dt[1]
    lsrk.t[1] += dt
  else
    lsrk.t[1] = timeend
  end

end

"""
    LSRK54CarpenterKennedy(f, Q; dt, t0 = 0)

This function returns a [`LowStorageRungeKutta2N`](@ref) time stepping object
for explicitly time stepping the differential
equation given by the right-hand-side function `f` with the state `Q`, i.e.,

```math
  \\dot{Q} = f(Q, t)
```

with the required time step size `dt` and optional initial time `t0`.  This
time stepping object is intended to be passed to the `solve!` command.

This uses the fourth-order, low-storage, Runge--Kutta scheme of Carpenter
and Kennedy (1994) (in their notation (5,4) 2N-Storage RK scheme).

### References

    @TECHREPORT{CarpenterKennedy1994,
      author = {M.~H. Carpenter and C.~A. Kennedy},
      title = {Fourth-order {2N-storage} {Runge-Kutta} schemes},
      institution = {National Aeronautics and Space Administration},
      year = {1994},
      number = {NASA TM-109112},
      address = {Langley Research Center, Hampton, VA},
    }
"""
function LSRK54CarpenterKennedy(F, Q::AT; dt=nothing, t0=0) where {AT <: AbstractArray}
  T = eltype(Q)
  RT = real(T)

  RKA = (RT(0),
         RT(-567301805773  // 1357537059087),
         RT(-2404267990393 // 2016746695238),
         RT(-3550918686646 // 2091501179385),
         RT(-1275806237668 // 842570457699 ))

  RKB = (RT(1432997174477 // 9575080441755 ),
         RT(5161836677717 // 13612068292357),
         RT(1720146321549 // 2090206949498 ),
         RT(3134564353537 // 4481467310338 ),
         RT(2277821191437 // 14882151754819))

  RKC = (RT(0),
         RT(1432997174477 // 9575080441755),
         RT(2526269341429 // 6820363962896),
         RT(2006345519317 // 3224310063776),
         RT(2802321613138 // 2924317926251))

  LowStorageRungeKutta2N(F, RKA, RKB, RKC, Q; dt=dt, t0=t0)
end

"""
    LSRK144NiegemannDiehlBusch((f, Q; dt, t0 = 0)

This function returns a [`LowStorageRungeKutta2N`](@ref) time stepping object
for explicitly time stepping the differential
equation given by the right-hand-side function `f` with the state `Q`, i.e.,

```math
  \\dot{Q} = f(Q, t)
```

with the required time step size `dt` and optional initial time `t0`.  This
time stepping object is intended to be passed to the `solve!` command.

This uses the fourth-order, 14-stage, low-storage, Runge--Kutta scheme of
Niegemann, Diehl, and Busch (2012) with optimized stability region

### References

    @article{niegemann2012efficient,
      title={Efficient low-storage Runge--Kutta schemes with optimized stability regions},
      author={Niegemann, Jens and Diehl, Richard and Busch, Kurt},
      journal={Journal of Computational Physics},
      volume={231},
      number={2},
      pages={364--372},
      year={2012},
      publisher={Elsevier}
    }
"""
function LSRK144NiegemannDiehlBusch(F::Union{Function, AbstractSpaceMethod},
                                    Q::AT; dt=nothing, t0=0) where {AT <: AbstractArray}
  T = eltype(Q)
  RT = real(T)

  RKA = (RT(0),
         RT(-0.7188012108672410),
         RT(-0.7785331173421570),
         RT(-0.0053282796654044),
         RT(-0.8552979934029281),
         RT(-3.9564138245774565),
         RT(-1.5780575380587385),
         RT(-2.0837094552574054),
         RT(-0.7483334182761610),
         RT(-0.7032861106563359),
         RT( 0.0013917096117681),
         RT(-0.0932075369637460),
         RT(-0.9514200470875948),
         RT(-7.1151571693922548))

  RKB = (RT(0.0367762454319673),
         RT(0.3136296607553959),
         RT(0.1531848691869027),
         RT(0.0030097086818182),
         RT(0.3326293790646110),
         RT(0.2440251405350864),
         RT(0.3718879239592277),
         RT(0.6204126221582444),
         RT(0.1524043173028741),
         RT(0.0760894927419266),
         RT(0.0077604214040978),
         RT(0.0024647284755382),
         RT(0.0780348340049386),
         RT(5.5059777270269628))

  RKC = (RT(0),
         RT(0.0367762454319673),
         RT(0.1249685262725025),
         RT(0.2446177702277698),
         RT(0.2476149531070420),
         RT(0.2969311120382472),
         RT(0.3978149645802642),
         RT(0.5270854589440328),
         RT(0.6981269994175695),
         RT(0.8190890835352128),
         RT(0.8527059887098624),
         RT(0.8604711817462826),
         RT(0.8627060376969976),
         RT(0.8734213127600976))

  LowStorageRungeKutta2N(F, RKA, RKB, RKC, Q; dt=dt, t0=t0)
end

end
