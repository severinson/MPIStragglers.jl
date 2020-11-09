module MPIutils

using MPI

export WorkerPool, kmap!

struct WorkerPool
    ranks::Vector{Int}
    sreqs::Vector{MPI.Request}
    rreqs::Vector{MPI.Request}
    sepochs::Vector{Int}
    repochs::Vector{Int}
    active::Vector{Bool}
    function WorkerPool(ranks::Vector{<:Integer}, epoch0::Integer=0)
        n = length(ranks)
        new(copy(ranks),
            Vector{MPI.Request}(undef, n), Vector{MPI.Request}(undef, n),
            Vector{Int}(undef, n), fill(epoch0, n),
            zeros(Bool, n))
    end
end

WorkerPool(n::Integer) = WorkerPool(collect(1:n))

"""
    kmap!(sendbuf, recvbuf, isendbuf, irecvbuf, k::Integer, epoch::Integer, pool::WorkerPool, comm::MPI.Comm)

Send the data in `sendbuf` asynchronously (via `MPI.Isend`) to all workers and wait for the fastest `k` workers to respond
(via a corresponding `MPI.Isend`). For iterative algorithms, `epoch` should be the iteration that the data in `sendbuf` corresponds to.

Returns a vector of length equal to the number of workers in the pool, where the `i`-th element is the `epoch` that transmission to 
that worker was initiated at. Similarly to the `MPI.Gather!` function, the elements of `recvbuf` are partitioned into a number of chunks 
equal to the number of workers (hence, the length of `recvbuf` must be divisible by the number of workers) and the data recieved from the
 `j`-th worker is stored in the `j`-th partition.

The buffers `isendbuf` and `irecvbuf` are for internal use by this function only and should never be changed or accessed outside of it.
The length of `isendbuf` must be equal to the length of `sendbuf` multiplied by the number of workers, and `irecvbuf` must have length 
equal to that of `recvbuf`.
"""
function kmap!(sendbuf, recvbuf, isendbuf, irecvbuf, k::Integer, epoch::Integer, pool::WorkerPool, comm::MPI.Comm; tag::Integer=0)
    comm_size = length(pool.ranks)
    0 <= k <= comm_size || throw(ArgumentError("k must be in the range [0, length(pool.ranks)]"))
    length(isendbuf) == comm_size*length(sendbuf) || throw(DimensionMismatch("sendbuf has $(length(sendbuf)) elements, but isendbuf has $(length(isendbuf)) elements when $(comm_size*length(sendbuf)) are needed"))
    length(recvbuf) == length(irecvbuf) || throw(DimensionMismatch("recvbuf has $(length(recvbuf)) elements, but irecvbuf has $(length(irecvbuf)) elements"))
    mod(length(recvbuf), comm_size) == 0 || throw(DimensionMismatch("the length of recvbuf and irecvbuf must be a multiple of the number of workers"))

    # send/receive buffers for each worker
    sl = length(sendbuf)
    rl = div(length(irecvbuf), comm_size)
    isendbufs = [view(isendbuf, (i-1)*sl+1:i*sl) for i in 1:comm_size]
    irecvbufs = [view(irecvbuf, (i-1)*rl+1:i*rl) for i in 1:comm_size]
    recvbufs = [view(recvbuf, (i-1)*rl+1:i*rl) for i in 1:comm_size]

    # start nonblocking transmission of sendbuf to all inactive workers
    # all workers are active after this loop
    for i in 1:length(pool.ranks)
        
        # do nothing with active workers
        if pool.active[i]
            continue
        end

        # worker is inactive
        pool.active[i] = true
        rank = pool.ranks[i]

        # copy send data to a worker-specific buffer to ensure the data isn't changed while sending
        isendbufs[i] .= sendbuf

        # remember at what epoch data was sent
        pool.sepochs[i] = epoch

        # non-blocking send and receive
        pool.sreqs[i] = MPI.Isend(isendbufs[i], rank, tag, comm)
        pool.rreqs[i] = MPI.Irecv!(irecvbufs[i], rank, tag, comm)
    end

    # continually send and receive until we've collected at least k responses from this epoch
    # at least k workers are inactive after this loop
    nrecv = 0
    while nrecv < k
        indices, _ = MPI.Waitsome!(pool.rreqs)
        for i in indices
            rank = pool.ranks[i]

            # store the received data and set the epoch
            recvbufs[i] .= irecvbufs[i]
            pool.repochs[i] = pool.sepochs[i]

            # cleanup the corresponding send request; should return immediately
            MPI.Wait!(pool.sreqs[i])

            # only receives initiated this epoch count towards completion
            if pool.repochs[i] == epoch
                nrecv += 1
                pool.active[i] = false
            else
                isendbufs[i] .= sendbuf 
                pool.sepochs[i] = epoch
                pool.sreqs[i] = MPI.Isend(isendbufs[i], rank, tag, comm)
                pool.rreqs[i] = MPI.Irecv!(irecvbufs[i], rank, tag, comm)
            end
        end
    end

    return pool.repochs
end

end
