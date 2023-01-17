using Logging
using Serialization
using Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

# ## TODO:
# ## * Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto)
# ## * Define a worker specific LogLevel
# global_logger(ConsoleLogger(stderr, Logging.Debug))

function main()
    # Use the same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

    # Write port number to stdout to let main process know where to send requests
    @debug("WORKER: new port", port)
    println(stdout, port)

    serve(server)
end

function serve(server::Sockets.TCPServer)
    # FIXME: This `latest` task isn't a good hack.
    # It only works if the main server is disciplined about the order of requests.
    # That happens to be the case for Pluto, but it's not true in general.
    latest = nothing
    while isopen(server)
        try
            # Wait for new request
            sock = accept(server)
            @debug(sock)

            # Handle request asynchronously
            latest = @async begin
                if !eof(sock)
                    msg = deserialize(sock)
                    if get(msg, :header, nothing) === :interrupt
                        interrupt(latest)
                    else
                        @debug("WORKER: Received message", msg)
                        handle(Val(msg.header), sock, msg)
                    end
                end
            end
        catch InterruptException
            @debug("WORKER: Caught interrupt!")
            interrupt(latest)
            continue
        end
    end
    @debug("WORKER: Closed server socket. Bye!")
end

# Check if task is still running before throwing interrupt
interrupt(t::Task) = istaskdone(t) || Base.throwto(t, InterruptException)
interrupt(::Nothing) = nothing

function handle(::Val{:call}, socket, msg)
    try
        result = msg.f(msg.args...; msg.kwargs...)
        # @debug("WORKER: Evaluated result", result)
        serialize(socket, (status=:ok, result=(msg.send_result ? result : nothing)))
    catch e
        # @debug("WORKER: Got exception!", e)
        serialize(socket, (status=:err, result=e))
    finally
        close(socket)
    end
end

function handle(::Val{:remote_do}, socket, msg)
    try
        msg.f(msg.args...; msg.kwargs...)
    finally
        close(socket)
    end
end

function handle(::Val{:channel}, socket, msg)
    channel = eval(msg.expr)
    while isopen(channel) && isopen(socket)
        serialize(socket, take!(channel))
    end
    isopen(socket) && close(socket)
    isopen(channel) && close(channel)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
