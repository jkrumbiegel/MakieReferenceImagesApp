include("src/app.jl")
precompile(MakieReferenceImagesApp.serve, (Int,))
precompile(MakieReferenceImagesApp.authenticate, ())
precompile(MakieReferenceImagesApp.new_check_run, (String,))
