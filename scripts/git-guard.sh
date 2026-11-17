#!/usr/bin/env bash
# Guards the git CLI inside the container so it can work on the mounted
# repository but cannot push anything to a remote.
#
# Commits, branches, merges and pulls are all allowed - only publishing to a
# remote is blocked. Run "git push" on the host instead.
set -uo pipefail

# The real git lives next to this script, one directory up and out of PATH.
# Fall back to the system binary if the image was built without the move.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_GIT="${GIT_REAL_PATH:-$SELF_DIR/../libexec/git}"
if [ ! -x "$REAL_GIT" ]; then
    REAL_GIT="/usr/bin/git"
fi

# Subcommands that write to a remote. "push" is the normal one, "send-pack" is
# the plumbing version underneath it.
BLOCKED="push send-pack"

# Keep the original arguments: the scan below consumes them, but the real git
# has to receive them untouched.
args=("$@")

block_push() {
    {
        echo "git $1 is disabled inside the ai-container."
        echo "The repository is your own on the host - run it there instead."
        echo "Set GIT_ALLOW_PUSH=1 to override this for a single command."
    } >&2
    exit 1
}

if [ "${GIT_ALLOW_PUSH:-}" = "1" ]; then
    exec "$REAL_GIT" "${args[@]}"
fi

# Find the subcommand: the first argument that is not a global option, or the
# value of a global option that takes one.
subcommand=""
while [ $# -gt 0 ]; do
    case "$1" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
            shift 2
            continue
            ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
            shift
            continue
            ;;
        -*)
            shift
            continue
            ;;
        *)
            subcommand="$1"
            break
            ;;
    esac
done

if [ -n "$subcommand" ]; then
    for blocked in $BLOCKED; do
        if [ "$subcommand" = "$blocked" ]; then
            block_push "$subcommand"
        fi
    done

    # "git remote update --push" publishes to the remote without using "push"
    if [ "$subcommand" = "remote" ]; then
        for arg in "${args[@]}"; do
            case "$arg" in
                push|--push)
                    block_push "remote update --push"
                    ;;
            esac
        done
    fi
fi

exec "$REAL_GIT" "${args[@]}"
