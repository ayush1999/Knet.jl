"""
REWRITE:
back(r::Net,ygold,loss) computes the gradients of weights and
activations according to the given loss function and gold output.
ygold represents an individual item minibatch that may or may not be
an element of a sequence.  The seq keyword argument determines which:
initback sets incr=true for par if seq, back pops from stack if seq.
The loss gradient of the output, ygrad, is computed using
loss(ypred,ygold,ygrad).  ypred is retrieved from r.out[N] where N is
the index of the last op.  ygrad is written to r.dif[N].  If r.op[N]
has multiple outputs (toincr[N]), r.dif[N] is incremented.  If the
optional loss argument is not provided, ygold is used as the loss
gradient.  If ygold=nothing means the loss gradient from the output is
taken to be 0.  Gradient computation proceeds backwards from N..1.

"""
function back(f::Net, ygold=nothing, loss=copyloss; seq=false, getdx=false, o...)
    getdx = getdxbool(getdx, ninputs(f)); dx=Any[]
    initback(f, ygold, loss, getdx, seq)
    gotreturn = false
    gotinputs = 0
    for n = length(f):-1:1
        skipped(f,n,seq) && continue
        y = get(f,n)
        get(y,:grad) || continue # :grad means we need the gradient of the output of this operation, does not mean go back on this operation. but no :grad means no need to go back.
        yout = (!seq ? y.out : stack_output(f,n))
        if !gotreturn
            gotreturn = true
            if ygold == nothing # represents zero gradient
                get(y,:incr) || (y.dif = nothing)
            else
                !isreturn(y) && Base.warn_once("ygold specified when there is no return")
                if get(y,:incr)
                    loss(yout, ygold, y.tmp; o...) # loss needs o... for e.g. mask
                    y.dif = axpy!(1,y.tmp,y.dif0)
                else
                    y.dif = loss(yout, ygold, y.dif0; o...)
                end
            end
        elseif isreturn(y)
            error("Got return in non-final instruction")
        end
        if y.dif == nothing
            for x in input_registers(f,y)
                get(x,:grad) && !get(x,:incr) && (x.dif = nothing)
            end
        else
            xx = input_registers(f,y)
            xdif = difs(xx)
            xout = get1(!seq ? outs(xx) : stack_inputs(f,n))
            back(y.op, y.dif, xdif...; x=xout, y=yout, o...)
            for x in xx
                x.dif = (get(x,:incr) ? axpy!(1, x.tmp, x.dif0) :
                         get(x,:grad) ? x.dif0 : nothing)
            end
            if get(y,:incr) && !isa(y.op, Par)
                fillsync!(y.dif,0)
            end
        end
        if isa(y.op,Input)
            getdx[end-gotinputs] && unshift!(dx, y.dif)
            gotinputs += 1
        end
    end
    seq && (f.sp -= length(f))  # this way f.stack[f.sp+n] gives the output of n'th op
    return get1(dx)
end


sback(f::Net, ygold=nothing, loss=copyloss; o...)=back(f,ygold,loss;o...,seq=true)

# For FNNs we can tell whether an op was skipped using the :forw flag.
# For RNNs the :forw flag may change through the iterations, so we check the stack.
skipped(f::Net,n::Int,seq::Bool)=(seq ? f.stack[f.sp+n]==:skip : !get(get(f,n),:forw))

# We assume f.reg[end].out is saved in f.stack[f.sp]
stack_output(f::Net,n::Int)=f.stack[f.sp - length(f) + n]

# For inputs the situation is a bit more complicated.
# We want to use their values prior to n'th op.
function stack_inputs(f::Net,n::Int)
    r = get(f,n)
    back_reads_x(r.op) || return nothing
    a = r.argv
    x = cell(length(a))
    @inbounds for i=1:length(a)
        if a[i] < n
            x[i] = f.stack[f.sp - length(f) + a[i]]
        elseif f.sp > length(f)
            x[i] = f.stack[f.sp - 2*length(f) + a[i]]
        else
            x[i] = nothing
        end
    end
end


function sback_delete(f::Net, ygold=nothing, loss=copyloss; getdx=false, o...)
    getdx = getdxbool(getdx, ninputs(f))
    initback(f, ygold, loss, getdx) # TODO: rethink lastforw==lastback in a seq context
    gotreturn = false

    for n = length(f):-1:1
        s = pop!(f)
        s == nothing && continue
        (y, xsave, ysave) = s
        @assert y === get(f,n)
        get(y,:grad) || continue # :grad means we need the gradient of the output of this operation, does not mean go back on this operation. but no :grad means no need to go back.
        
        if !gotreturn
            gotreturn = true
            if ygold == nothing # represents zero gradient
                get(y,:incr) || (y.dif = nothing)
            else
                !isreturn(y) && Base.warn_once("ygold specified when there is no return")
                ysave == nothing && error("return value was not saved")
                if get(y,:incr)
                    loss(ysave, ygold, y.tmp; o...) # loss needs o... for e.g. mask
                    y.dif = axpy!(1,y.tmp,y.dif0)
                else
                    y.dif = loss(ysave, ygold, y.dif0; o...)
                end
            end
        elseif isreturn(y)
            error("Got return in non-final instruction")
        end

        xx = input_registers(f,y)
        if y.dif == nothing
            for x in xx
                get(x,:grad) && !get(x,:incr) && (x.dif = nothing)
            end
        else
            xdif = inputdifs(f,y)  # map too slow? map(x->(!get(x,:grad) ? nothing : get(x,:incr) ? x.tmp : x.dif0), xx)
            back(y.op, y.dif, xdif...; x=get1(xsave), y=ysave, o...)
            for x in xx
                x.dif = (get(x,:incr) ? axpy!(1, x.tmp, x.dif0) :
                         get(x,:grad) ? x.dif0 : nothing)
            end
            if get(y,:incr) && !isa(y.op, Par)
                # what if y.op=Arr?  then it will have no inputs, thus :grad=:incr=false
                # where does Par.dif get zeroed out? at reset!
                fillsync!(y.dif,0)
            end
        end
    end

    if any(getdx)
        dx = Any[]; nx = 0
        for p in registers(f)
            isa(p.op,Input) && getdx[nx+=1] && push!(dx, p.dif)
        end
        return get1(dx)
    end
end

# this is used when no loss fn specified, in which case we assume ygold is actually ygrad
copyloss(ypred,ygold,ygrad;o...)=(ygrad===ygold ? ygrad : copysync!(ygrad,ygold))

# turn various forms of getdx into boolean vector
function getdxbool(getdx, n)
    (isa(getdx, Vector{Bool}) && length(getdx)==n ? getdx :
     isa(getdx, Bool) ? fill(getdx, n) :
     isa(getdx, Vector{Int}) ? (tmp=falses(n);tmp[getdx]=true;tmp) :
     isa(getdx, Int) ? (tmp=falses(n);tmp[getdx]=true;tmp) :
     error("getdx=$getdx ninputs=$(n)"))
end

# This is extremely slow:
#get1(x)=(!isempty(methods(length, (typeof(x),))) && length(x)==1?x[1]:x)
get1(x)=(x==nothing?x:length(x)==1?x[1]:x)

### DEAD CODE:

# # back(r::Net,dy::Vector) for a sequence
# function back(r::Net, dy::Vector, dx...; a...)
#     dxi = map(x->(x==nothing ? x : x[end]), dx)
#     initback(r, dy[end], dxi...; seq=true, a...)
#     for i=length(dy):-1:1
#         dxi = map(x->(x==nothing ? x : x[i]), dx)
#         back(r, dy[i], dxi...; seq=true, a...)
#     end
# end

# DONE: truncated bptt
# - go forward k1 steps, run back for k2, update, recover state
# - if k1==k2 we just need the keepstate option to forw
# - if k1>k2 the stack won't be cleared
# - if k1<k2 the stack will be overdrawn

    # for i = ninputs(r):-1:1
    #     n = i+N
    #     r.tosave[n] && pop(r,n)                                    # ; r.tosave[n] && dbg(r,:out,n)
    #     dx == nothing || copysync!(dx[i], r.dif[n])
    # end

    # if dx != ()
    #     lastinput = 0
    #     for n = 1:N
    #         isa(r.op[n], Input) || continue
    #         copysync!(dx[lastinput += 1], r.dif[n])
    #     end
    # end