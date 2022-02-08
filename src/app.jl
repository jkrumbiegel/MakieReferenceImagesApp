module MakieReferenceImagesApp
    using HTTP
    using JSON3
    using Sockets
    using GitHub

    export serve

    const ROUTER = HTTP.Router()

    function handle_webhook(req)
        try
            if !HTTP.hasheader(req, "X-Github-Event") || HTTP.header(req, "X-Github-Event") != "workflow_job"
                @info "Not a workflow job."
                return HTTP.Response(200)
            end
            data = JSON3.read(req.body)
            w = data["workflow_job"]
            head_sha = w["head_sha"]
            
            @info "Getting workflow run info at $(w["run_url"])"
            workflow_run = JSON3.read(HTTP.get(w["run_url"]).body)
            workflow_run_name = workflow_run["name"]
            @info "Workflow run name is $workflow_run_name"

            workflow_job_name = w["name"]
            # only do this for the 1.6 matrix entry (or whatever the highest stable version is)
            if !startswith(workflow_job_name, "Julia 1.6")
                @info "Wrong workflow job name $workflow_job_name."
                return HTTP.Response(200)
            end

            if workflow_run_name ∉ ["GLMakie CI", "CairoMakie CI"]
                @info "Wrong workflow run $workflow_run_name."
                return HTTP.Response(200)
            end

            if data["action"] == "completed"
                has_uploaded_artifacts = false
                for step in w["steps"]
                    if step["name"] == "Upload test Artifacts" && step["status"] == "completed" && step["conclusion"] == ["success"]
                        has_uploaded_artifacts = true
                        break
                    end
                end
                @show has_uploaded_artifacts

                if has_uploaded_artifacts
                    authenticate()
                    new_check_run(head_sha;
                        name = workflow_run_name * " Reference Images",
                        title = workflow_run_name * " Reference Images",
                        summary = "Here are the reference images that have high diff scores.",
                        status = "completed",
                        conclusion = "action_required",
                    )
                else
                    authenticate()
                    new_check_run(head_sha;
                        name = workflow_run_name * " Reference Images",
                        title = workflow_run_name * " Reference Images",
                        summary = "No reference images generated.",
                        status = "completed",
                        conclusion = "neutral",
                    )
                end
            elseif data["action"] == "in_progress"
                authenticate()
                new_check_run(head_sha;
                    name = workflow_run_name * " Reference Images",
                    title = workflow_run_name * " Reference Images",
                    summary = "Here, the reference images with high diff scores will show up.",
                    status = "in_progress",
                )
            end
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
        @info "Authenticating..."
        jwtauth = mktemp() do path, io
            write(io, ENV["GITHUB_APP_KEY"])
            close(io)
            GitHub.JWTAuth(
                parse(Int, ENV["GITHUB_APP_ID"]),
                path
            )
        end
        installations = GitHub.installations(jwtauth)
        installation = installations[1][1]
        auth[] = create_access_token(installation, jwtauth)
        @info "Authenticated successfully."
        return
    end

    function new_check_run(head_sha; name, title, summary, images = [], params...)
        @info "Creating new check run at $head_sha"
        GitHub.create_check_run(
            Repo(ENV["GITHUB_TARGET_REPO"]);
            auth = auth[],
            params = Dict(
                :name => name,
                :head_sha => head_sha,
                :output => Dict(
                    :title => title,
                    :summary => summary,
                    :images => images
                ),
                # actions
                # Dict(
                #     "label" => "Update Refimages",
                #     "description" => "Replace the previous reference images.",
                #     "identifier" => "update-reference",
                # )
                pairs(params)...
            )
        )
        return
    end
end