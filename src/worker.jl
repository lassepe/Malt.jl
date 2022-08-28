using Logging
using Serialization
using Sockets

## Allow catching InterruptExceptions
Base.exit_on_sigint(false)

# ## TODO: Don't use a global Logger. Use one for dev, and one for user code (handled by Pluto)
# global_logger(ConsoleLogger(stderr, Logging.Debug))

function main()
    # Use the same port hint as Distributed
    port_hint = 9000 + (getpid() % 1000)
    port, server = listenany(port_hint)

    # Write port number to stdout to let main process know where to send requests
    @debug(port)
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
                msg = deserialize(sock)
                @debug(msg)
                handle(Val(msg.header), sock, msg)
            end
        catch InterruptException
            # Rethrow interrupt in the latest task
            @debug("Caught interrupt!")
            if latest isa Task && !istaskdone(latest)
                Base.throwto(latest, InterruptException)
            end
            continue
        end
    end
    @debug("Closed server socket. Bye!")
end


function handle(::Val{:call}, socket, msg)
    body = msg.body # Don't use destructuring to support v1.6
    try
        result = body.f(body.args...; body.kwargs...)
        # @debug("Result", result)
        serialize(socket, (status=:ok, result=(msg.send_result ? result : nothing)))
    catch e
        # @debug("Exception!", e)
        serialize(socket, (status=:err, result=e))
    finally
        close(socket)
    end
end

function handle(::Val{:remote_do}, socket, msg)
    body = msg.body
    try
        # @debug("Remote do:", body)
        body.f(body.args...; body.kwargs...)
    finally
        close(socket)
    end
end

function handle(::Val{:channel}, socket, msg)
    channel = eval(msg.body)
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
