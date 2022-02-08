include("src/app.jl")
port = parse(Int, ARGS[1])
@info "Starting server at port $port"
MakieReferenceImagesApp.serve(port)
