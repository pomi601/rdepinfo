repos <- function() {
  cat(unlist(options("repos")), "\n")
}

known_repos <- function() {
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

dump_available_packages <- function(timing = FALSE) {
  fields <- c("Package", "Version", "Depends", "Imports", "LinkingTo")

  ap_time <- system.time(ap <- available.packages()[, fields])["elapsed"]
  if (timing) {
    cat("available.packages: ", ap_time, "\n", sep = "", file = stderr())
  }

  loop_time <- system.time(
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
  )["elapsed"]

  if (timing) {
    cat("output: ", loop_time, "\n", sep = "", file = stderr())
  }
}
