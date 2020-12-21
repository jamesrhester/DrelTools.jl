using Documenter, DrelTools 

makedocs(sitename="dREL Tools documentation",
	  format = Documenter.HTML(
				   prettyurls = get(ENV,"CI",nothing) == "true"
				   ),
         pages = [
             "Overview" => "index.md",
             "Guide" => "guide.md",
             "API" => "api.md"
             ],
         #doctest = :fix
	  )

deploydocs(
    repo = "github.com/jamesrhester/DrelTools.jl.git",
)
