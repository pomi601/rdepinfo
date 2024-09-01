check_pkgs <- function(pkgs, names) {
  if (!is.vector(pkgs)) pkgs <- c(pkgs)
  for (pkg in pkgs) {
    if (!pkg %in% names) {
      cat(pkg, " not found.\n", sep = "", file = stderr())
      quit(status = 1)
    }
  }
}

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

## Print dependency packages of pkgs grouped with their dependencies
depend_grouped <- function(pkgs) {
  if (!is.vector(pkgs)) pkgs <- c(pkgs)
  ap <- available.packages()
  names <- rownames(ap)
  check_pkgs(pkgs, names)

  for (pkg in pkgs) {
    res <- unlist(utils:::.make_dependency_list(c(pkg), ap, recursive = TRUE))
    cat(pkg, ":", res, "\n", sep = " ")
    for (pkg in res) {
      check_pkgs(pkg, names)
      depends <- unlist(utils:::.make_dependency_list(pkg, ap, recursive = FALSE))
      cat(pkg, ":", depends, "\n", sep = " ")
    }
  }
}

## Print dependency packages of pkg in build order
depend_ordered <- function(pkg) {
  ap <- available.packages()
  dl <- utils:::.make_dependency_list(c(pkg), ap, recursive = TRUE)
  tdl <- utils:::.make_dependency_list(unlist(dl), ap, recursive = TRUE)
  res <- utils:::.find_install_order(unique(unlist(dl)), tdl)
  cat(res, sep = "\n")
}

## Print package source downloads for pkg and each dependency
depend_urls <- function(pkgs) {
  if (!is.vector(pkgs)) pkgs <- c(pkgs)

  ap <- available.packages()
  names <- rownames(ap)
  check_pkgs(pkgs, names)
  dl <- unlist(utils:::.make_dependency_list(pkgs, ap, recursive = TRUE))

  cat(contrib.url(ap[pkg, "Repository"]), "/", pkg, "_", ap[pkg, "Version"], ".tar.gz", "\n", sep = "")

  check_pkgs(dl, names)
  for (pkg in dl) {
    cat(contrib.url(ap[pkg, "Repository"]), "/", pkg, "_", ap[pkg, "Version"], ".tar.gz", "\n", sep = "")
  }
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
