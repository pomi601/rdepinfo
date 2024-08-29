#!/usr/bin/env bash

set -euo pipefail               # sane options for bash scripts

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
MY_R="source('$SCRIPT_DIR/rinfo.R'); "

if ! RSCRIPT=$(command -v Rscript); then
    echo "Rscript not found. Exiting."
    exit 1
fi

OPT_ALL_REPOS=""
OPT_TIME="FALSE"

usage()
{
    echo "Usage: $0 <command> [options]"
    echo
    echo "Commands:"
    echo
    echo "  depends <pkg>      Print immediate dependencies of pkg, one per line."
    echo "  depends-full <pkg> Print recursive dependencies of pkg, one per line."
    echo "  dump-packages      Print essential package information in DCF for all"
    echo "                     packages. Slow."
    echo "  repos              Print configured R repositories, one per line."
    echo
    echo "Options:"
    echo
    echo "  --all-repos        Load all known package repositories. Slow."
    echo "  --time             Including timing information to stderr."
}

repos()
{
    "$RSCRIPT" -e "$MY_R cat(unlist(options('repos')), '\n')"
}

known_repos()
{
    "$RSCRIPT" -e "$MY_R known_repos()"
}

depends_flat() {
    if [[ -n "$OPT_ALL_REPOS" ]]; then
        "$RSCRIPT" -e "$MY_R load_all_repos(); depend_list('$1', recursive = FALSE)"
    else
        "$RSCRIPT" -e "$MY_R depend_list('$1', recursive = FALSE)"
    fi
}

depends_full() {
    if [[ -n "$OPT_ALL_REPOS" ]]; then
        "$RSCRIPT" -e "$MY_R load_all_repos(); depend_list('$1', recursive = TRUE)"
    else
        "$RSCRIPT" -e "$MY_R depend_list('$1', recursive = TRUE)"
    fi
}

dump_packages() {
    if [[ -n "$OPT_ALL_REPOS" ]]; then
        "$RSCRIPT" -e "$MY_R load_all_repos(); dump_available_packages(timing = $OPT_TIME)"
    else
        "$RSCRIPT" -e "$MY_R dump_available_packages(timing = $OPT_TIME)"
    fi
}

#
# parse: parse command line arguments
#
parse()
{
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all-repos )
                OPT_ALL_REPOS="yes"
                ;;

            -h | --help )
                usage
                exit 0
                ;;

            --time )
                OPT_TIME="TRUE"
                ;;

            -* )
                echo "Unknown option: $1"
                usage
                exit 1
                ;;

            * )
                # command word
                ;;
        esac
        shift
    done
}

# parse command line arguments
parse "$@"

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        "depends" )
            depends_flat "$2"
            exit $?
            ;;

        "depends-full" )
            depends_full "$2"
            exit $?
            ;;

        "dump-packages" )
            dump_packages
            exit $?
            ;;

        "known-repos" )
            known_repos
            exit $?
            ;;

        "repos" )
            repos
            exit $?
            ;;

        -b | --bind | -f | --file | -p | --port | --target | -t | --tag )
            # skip option with argument
            shift
            ;;

        -* )
            # skip single options
            ;;

        * )
            echo "ERROR: unknown command: $1"
            usage ;;
    esac
    shift
done
