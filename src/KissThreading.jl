module KissThreading

using Random: MersenneTwister
using Future: randjump
using Core.Compiler: return_type

export trandjump, TRNG, tmap, tmap!, tmapreduce, getrange

"""
    trandjump(rng = MersenneTwister(0); jump=big(10)^20)

Return a vector of copies of `rng`, which are advanced by different multiples
of `jump`. Effectively this produces statistically independent copies of `rng`
suitable for multi threading. See also [`Random.randjump`](@ref).
"""
function trandjump end

_randjump(rng, n, jump=big(10)^20) = accumulate(randjump, [jump for i in 1:n], init = rng)

function trandjump(rng = MersenneTwister(0); jump=big(10)^20)
    n = Threads.nthreads()
    rngjmp = Vector{MersenneTwister}(undef, n)
    for i in 1:n
        rngjmp[i] = randjump(rng, jump*i)
    end
    rngjmp
end

const TRNG = trandjump()

"""
    TRNG

A vector of statistically independent random number generators. Useful of threaded code:
```julia
rng = TRNG[Threads.threadid()]
rand(rng)
```
"""
TRNG

default_batch_size(n) = min(n, round(Int, 10*sqrt(n)))

struct Mapper
    atomic::Threads.Atomic{Int}
    len::Int
end

@inline function (mapper::Mapper)(batch_size, f, dst, src...)
    ld = mapper.len
    atomic = mapper.atomic
    Threads.@threads for j in 1:Threads.nthreads()
        while true
            k = Threads.atomic_add!(atomic, 1)
            batch_start = 1 + (k-1) * batch_size
            batch_end = min(k * batch_size, ld)
            batch_start > ld && break
            batch_map!(batch_start:batch_end, f, dst, src...)
        end
    end
    dst
end

@inline function batch_map!(range, f, dst, src...)
    @inbounds for j in range
        dst[j] = f(getindex.(src, j)...)
    end
end

function _doc_threaded_version(f)
    """Threaded version of [`$f`](@ref). The workload is divided into chunks of length `batch_size`
    and processed by the threads. For very cheap `f` it can be advantageous to increase `batch_size`."""
end

"""
    tmap!(f, dst::AbstractArray, src::AbstractArray...; batch_size=1)

$(_doc_threaded_version(map!))
"""
function tmap!(f, dst::AbstractArray, src::AbstractArray...; batch_size=1)
    ld = length(dst)
    if (ld, ld) != extrema(length.(src))
        throw(ArgumentError("src and dst vectors must have the same length"))
    end
    atomic = Threads.Atomic{Int}(1)
    mapper = Mapper(atomic, ld)
    mapper(batch_size, f, dst, src...)
end

"""
    tmap(f, src::AbstractArray...; batch_size=1)

$(_doc_threaded_version(map))
"""
function tmap(f, src::AbstractArray...; batch_size=1)
    g = Base.Generator(f,src...)
    T = Base.@default_eltype(g)
    dst = similar(first(src), T)
    tmap!(f, dst, src..., batch_size=batch_size)
end

struct MapReducer{T}
    r::Base.RefValue{T}
    atomic::Threads.Atomic{Int}
    lock::Threads.SpinLock
    len::Int
end

@inline function (mapreducer::MapReducer{T})(batch_size, f, op, src...) where T
    atomic = mapreducer.atomic
    lock = mapreducer.lock
    len = mapreducer.len
    Threads.@threads for j in 1:Threads.nthreads()
        k = Threads.atomic_add!(atomic, batch_size)
        k > len && continue
        y = f(getindex.(src, k)...)
        r = convert(T, y)
        range = (k + 1) : min(k + batch_size - 1, len)
        r = batch_mapreduce(r, range, f, op, src...)
        k = Threads.atomic_add!(atomic, batch_size)
        while k ≤ len
            range = k : min(k + batch_size - 1, len)
            r = batch_mapreduce(r, range, f, op, src...)
            k = Threads.atomic_add!(atomic, batch_size)
        end
        Threads.lock(lock)
        mapreducer.r[] = op(mapreducer.r[], r)
        Threads.unlock(lock)
    end
    mapreducer.r[]
end

"""
    tmapreduce(f, op, src::AbstractArray...; init, batch_size=default_batch_size(length(src[1])))

$(_doc_threaded_version(mapreduce))

Warning: In contrast to `Base.mapreduce` it is assumed that `op` must be commutative. Otherwise
the result is undefined.
"""
function tmapreduce end

function tmapreduce(f, op, src::AbstractArray...; init, batch_size=default_batch_size(length(src[1])))
    T = get_reduction_type(init, f, op, src...)
    _tmapreduce(T, init, batch_size, f, op, src...)
end

function tmapreduce(::Type{T}, f, op, src::AbstractArray...; init, batch_size=default_batch_size(length(src[1]))) where T
    _tmapreduce(T, init, batch_size, f, op, src...)
end

@inline function _tmapreduce(::Type{T}, init, batch_size, f, op, src...) where T
    lss = extrema(length.(src))
    lss[1] == lss[2] || throw(ArgumentError("src vectors must have the same length"))

    atomic = Threads.Atomic{Int}(1)
    lock = Threads.SpinLock()
    len = lss[1]
    mapreducer = MapReducer{T}(Base.RefValue{T}(init), atomic, lock, len)
    return mapreducer(batch_size, f, op, src...)
end

@inline function get_reduction_type(init, f, op, src...)
    Tx = return_type(f, Tuple{eltype.(src)...})
    Trinit = return_type(op, Tuple{typeof(init), Tx})
    Tr = return_type(op, Tuple{Trinit, Tx})
    Tr === Union{} ? typeof(init) : Tr
end

@inline function batch_mapreduce(r, range, f, op, src...)
    @inbounds for i in range
        r = op(r, f(getindex.(src, i)...))
    end
    r
end

"""
    getrange(n)

Partition the range `1:n` into `Threads.nthreads()` subranges and return the one corresponding to `Threads.threadid()`.
Useful for splitting a workload among multiple threads. See also the `TiledIteration` package for more advanced variants.
"""
function getrange(n)
    tid = Threads.threadid()
    nt = Threads.nthreads()
    d , r = divrem(n, nt)
    from = (tid - 1) * d + min(r, tid - 1) + 1
    to = from + d - 1 + (tid ≤ r ? 1 : 0)
    from:to
end

end
