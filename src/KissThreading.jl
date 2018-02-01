module KissThreading

export trandjump, TRNG, tmap!

function trandjump(rng = MersenneTwister(0), gpt=1)
    n = Threads.nthreads()
    rngjmp = randjump(rng, n*(gpt+1))
    reshape(rngjmp, gpt+1)[1:gpt, :]
end

const TRNG = trandjump()

function tmap!(f::Function, dst::AbstractVector, src::AbstractVector)
    if length(src) != length(dst)
        throw(ArgumentError("src and dst vectors must have the same length"))
    end
    
    i = Threads.Atomic{Int}(1)
    Threads.@threads for j in 1:Threads.nthreads()
        while true
            k = Threads.atomic_add!(i, 1)
            if k ≤ length(src)
                dst[k] = f(src[k])
            else
                break
            end
        end
    end
end

end

