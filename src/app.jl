module MakieReferenceImagesApp
    using HTTP
    using JSON3
    using Sockets
    using GitHub

    export serve

    const ROUTER = HTTP.Router()

    function handle_webhook(req)
        try
            data = JSON3.read(req.body)
            
            workflow_run = data["workflow_run"]
            head_sha = workflow_run["head_sha"]
            new_check_run(head_sha)
        catch e
            showerror(stdout, e, catch_backtrace())
            println()
            return HTTP.Response(200, "Something went wrong.")
        end
        return HTTP.Response(200, "Ok.")
    end

    HTTP.@register(ROUTER, "POST", "/", handle_webhook)

    function serve(port; socket = Sockets.localhost)
        @info "Starting server at port $port"
        HTTP.serve(ROUTER, socket, port)
    end

    auth = Ref{Any}()
    function authenticate()
        jwtauth = GitHub.JWTAuth(ENV["GITHUB_APP_ID"], ENV["GITHUB_APP_KEY"])
        installations = GitHub.installations(jwtauth)
        installation = installations[1][1]
        auth[] = create_access_token(installation, jwtauth)
        return
    end

    function new_check_run(head_sha)
        @info "Creating new check run"
        r = GitHub.create_check_run(
            Repo(ENV["GITHUB_TARGET_REPO"]);
            auth = auth[],
            params = Dict(
                "name" => "Reference Images",
                "head_sha" => head_sha,
                "output" => Dict(
                    "title" => "Reference Images",
                    "summary" => "Reference images summary.",
                    # "images" => [
                    #     # GitHub.Image("Reference vs recorded", "http://...", "Reference vs recorded.")
                    # ],
                ),
                "actions" => [
                    Dict(
                        "label" => "Update Refimages",
                        "description" => "Replace the previous reference images.",
                        "identifier" => "update-reference",
                    )
                ]
            )
        )
    end
end