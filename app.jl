include("src/app.jl")
port = parse(Int, ARGS[1])
MakieReferenceImagesApp.serve(port; socket = "0.0.0.0")
