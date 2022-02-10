module MakieReferenceImagesApp
    using HTTP
    using JSON3
    using Sockets
    using GitHub
    import Downloads
    import ZipFile

    export serve

    const ROUTER = HTTP.Router()

    function handle_webhook(req)
        try
            if !HTTP.hasheader(req, "X-Github-Event") || HTTP.header(req, "X-Github-Event") != "workflow_run"
                @info "Ignoring event that is not a workflow run."
                return HTTP.Response(200)
            end
            data = JSON3.read(req.body)
            workflow_run = data["workflow_run"]
            head_sha = workflow_run["head_sha"]
            
            workflow_run_name = workflow_run["name"]

            if workflow_run_name ∉ ["GLMakie CI", "CairoMakie CI"]
                @info "Ignoring workflow run $workflow_run_name."
                return HTTP.Response(200)
            else
                @info "Processing workflow run $workflow_run_name"
            end

            if data["action"] != "completed"
                @info "Ignoring workflow run that is not completed."
                return HTTP.Response(200)
            end

            workflow_run_id = workflow_run["id"]

            artifacts = get_artifacts_list(workflow_run_id)
            if isempty(artifacts)
                error("No artifacts for workflow $workflow_run_id.")
            end

            artifact = get_right_artifact(artifacts)
            if artifact === nothing
                error("Artifacts found, but not the right artifact, instead:\n $artifacts.")
            end

            refimage_dir = download_and_extract_workflow_artifact(artifact, workflow_run_id)

            # this block adds the first five images to the check run for test purposes
            # until the recorded images store a score list
            i = 0
            pngfiles = String[]
            for (root, dirs, files) in walkdir(refimage_dir)
                for file in files
                    i >= 5 && break
                    endswith(file, ".png") || continue
                    push!(pngfiles, normpath(joinpath(relpath(root, refimage_dir), file)))
                    i += 1
                end
            end

            baseurl = "https://makie-reference-images.herokuapp.com"
            images = map(pngfiles) do file
                GitHub.Image(
                    file,
                    "$baseurl/$workflow_run_id/$(HTTP.URIs.escapepath(file))",
                    "Random score: $(round(rand(), digits = 3))"
                )
            end

            authenticate()
            new_check_run(head_sha;
                name = workflow_run_name * " Reference Images",
                title = workflow_run_name * " Reference Images",
                summary = "Here are the reference images that have high diff scores.",
                status = "completed",
                conclusion = "action_required",
                images = images,
            )
        catch e
            showerror(stdout, e, catch_backtrace())
            println()
            return HTTP.Response(200, "Something went wrong.")
        end
        return HTTP.Response(200)
    end

    HTTP.@register(ROUTER, "POST", "/", handle_webhook)

    function serve(port; socket = Sockets.localhost)
        @info "Starting server at port $port"
        HTTP.serve(ROUTER, socket, port)
    end

    auth = Ref{Any}()
    function authenticate()
        @info "Authenticating..."
        jwtauth = get_jwtauth()
        installations = GitHub.installations(jwtauth)
        installation = installations[1][1]
        auth[] = create_access_token(installation, jwtauth)
        @info "Authenticated successfully."
        return
    end

    function get_jwtauth()
        jwtauth = mktemp() do path, io
            write(io, ENV["GITHUB_APP_KEY"])
            close(io)
            GitHub.JWTAuth(
                parse(Int, ENV["GITHUB_APP_ID"]),
                path
            )
        end
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

    const workflow_artifactfolder = Ref{String}()
    function artifact_folder()
        if !isassigned(workflow_artifactfolder)
            workflow_artifactfolder[] = mktempdir()
        end
        workflow_artifactfolder[]
    end

    function get_artifacts_list(workflow_run_id; repo = ENV["GITHUB_TARGET_REPO"])
        artifacts_url = "https://api.github.com/repos/$repo/actions/runs/$workflow_run_id/artifacts"
        @info "Getting artifact info from $artifacts_url"
        artifact_info = JSON3.read(HTTP.get(artifacts_url).body)
        artifact_info["artifacts"]
    end

    function get_right_artifact(artifacts)
        ia = findfirst(artifacts) do a
            startswith(a["name"], "ReferenceImages") && endswith(a["name"], "1.6")
        end

        ia === nothing ? nothing : artifacts[ia]
    end

    function download_and_extract_workflow_artifact(artifact, workflow_run_id)

        headers = Dict{String, String}()
        authenticate()
        GitHub.authenticate_headers!(headers, auth[])

        artifact_url = artifact["archive_download_url"]
        @info "Downloading artifact at $artifact_url"
        zip_path = Downloads.download(artifact_url, headers = headers)
        @info "Downloaded artifact."

        refimage_dir = make_refimage_dir(workflow_run_id)
        unzip(zip_path, refimage_dir)
        return refimage_dir
    end

    function make_refimage_dir(workflow_run_id)
        path = joinpath(artifact_folder(), string(workflow_run_id))
        if isdir(path)
            rm(path, recursive = true)
        end
        mkdir(path)
        path
    end

    function unzip(file, exdir = "")
        @info "Extracting zip file $file"
        fileFullPath = isabspath(file) ?  file : joinpath(pwd(),file)
        basePath = dirname(fileFullPath)
        outPath = (exdir == "" ? basePath : (isabspath(exdir) ? exdir : joinpath(pwd(),exdir)))
        isdir(outPath) ? "" : mkdir(outPath)
        zarchive = ZipFile.Reader(fileFullPath)
        for f in zarchive.files
            fullFilePath = joinpath(outPath,f.name)
            if (endswith(f.name,"/") || endswith(f.name,"\\"))
                mkdir(fullFilePath)
            else
                write(fullFilePath, read(f))
            end
        end
        close(zarchive)
        @info "Extracted zip file"
    end
    
    function serve_artifact_files(req)
        req.target == "/" && return HTTP.Response(404)
        file = HTTP.unescapeuri(req.target[2:end])
        filepath = normpath(joinpath(artifact_folder(), file))
        # check that we don't go outside of the artifact folder
        if !startswith(filepath, artifact_folder())
            @info "$file leads to $filepath which is outside of the artifact folder."
            return HTTP.Response(404)
        end

        rel = relpath(filepath, artifact_folder())
        run_id_str = splitpath(rel)[1]
        run_id = tryparse(Int, run_id_str)

        if run_id === nothing
            @info "$run_id_str can't be parsed into an integer run id"
            return HTTP.Response(404)
        end

        if !isdir(joinpath(artifact_folder(), run_id_str))
            @info "Requested file from run $run_id_str which doesn't exist on disk yet. Downloading reference images..."
            as = get_artifacts_list(run_id)
            isempty(as) && error("No artifacts available")
            a = get_right_artifact(as)
            a === nothing && error("Artifacts available, but not the right artifact.")
            download_and_extract_workflow_artifact(a, run_id)
        else
            @info "Folder $run_id_str exists."
        end

        if !isfile(filepath)
            @info "$filepath does not exist."
            return HTTP.Response(404)
        else
            @info "$filepath exists."
            return HTTP.Response(200, read(filepath))
        end
    end
    
    HTTP.@register(ROUTER, "GET", "/", serve_artifact_files)
end