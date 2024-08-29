repos <- function() {
  cat(unlist(options("repos")), "\n")
}

known_repos <- function () {
  repos <- unlist(c(
    utils:::findCRANmirror(type = "src"),
    utils:::.get_repositories()$URL
  ))
  repos <- repos[repos != "@CRAN@"]
  cat(repos, sep = "\n")
}

depend_list <- function(pkg, recursive = FALSE) {
  ap <- available.packages()
  res <- utils:::.make_dependency_list(c(pkg), ap, recursive = recursive)
  cat(unlist(res), sep = "\n")
}

load_all_repos <- function() {
  ## TODO: should there be a smarter way to load all known
  ## repositories?
  setRepositories(ind = 1:nrow(utils:::.get_repositories()))
}

dump_available_packages <- function() {
  ap <- available.packages()
  for (i in seq_len(nrow(ap))) {
    cat("Package: ", ap[i, "Package"], "\n", sep = "")
    cat("Version: ", ap[i, "Version"], "\n", sep = "")

    field <- "Depends"
    data <- ap[i, field]
    if (!is.na(data)) {
      data <- gsub("\\\n", "", data)
      cat(field, ": ", data, "\n", sep = "")
    }

    field <- "Imports"
    data <- ap[i, field]
    if (!is.na(ap[i, field])) {
      data <- gsub("\\\n", "", data)
      cat(field, ": ", data, "\n", sep = "")
    }

    field <- "LinkingTo"
    data <- ap[i, field]
    if (!is.na(ap[i, field])) {
      data <- gsub("\\\n", "", data)
      cat(field, ": ", data, "\n", sep = "")
    }

    cat("\n", sep = "")
  }
}








## REPOS <- c("https://cran.stat.auckland.ac.nz", "https://rforge.net")
## PKGS <- c("TESTUNIQUE611")
## AP <- available.packages(repos = REPOS)
## DL <- utils:::.make_dependency_list(PKGS, AP, recursive = TRUE)
## TDL <- utils:::.make_dependency_list(unlist(DL), AP, recursive = TRUE)
## utils:::.find_install_order(unique(unlist(DL)), TDL)

## AP[PKGS, "Imports"]
## AP["ggplot2", "Version"]



## AP <- available.packages()
