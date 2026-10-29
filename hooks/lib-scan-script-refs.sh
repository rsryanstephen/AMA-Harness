#!/usr/bin/env bash
# Shared by the DB write gates (mongo-write-gate.sh, psql-write-gate.sh).
#
# Those gates read the COMMAND TEXT to decide whether a write is happening. That misses the
# most common shape in this harness: the write sits inside a script file and the command is
# just `bash scratch/foo.sh`. Not an exotic evasion -- inline-loop-gate.sh and
# multiline-string-gate.sh both push commands INTO script files, so it is the shape the
# harness recommends. Confirmed live 2026-09-11: a qa `updateOne` ran unchallenged from a
# scratch script, and the same route reaches production.
#
# Scope is deliberately narrow (user decision, 2026-09-11): only files under a repo
# `scratch/` directory or under the session scratchpad root are read. Those are where
# throwaway DB scripts actually live. A committed application script is not scanned -- this
# guards ad-hoc agent work, it is not a general static analyser, and reading arbitrary paths
# named on every Bash call is a cost nobody asked for.
#
#   scan_referenced_scripts "<command text>"   -> echoes the contents of each scannable file
#                                                 the command references (empty if none)
#
# NOTE for callers: do NOT apply heredoc scoping (`${cmd%%<<*}`) to the returned text. That
# trick strips a heredoc BODY from a command line because a commit message is data, not code
# -- but inside a script file the heredoc body IS the code (e.g. the JS eval handed to
# docdb-query.sh, which is exactly where the write lives).

# Biggest file worth reading; a throwaway DB script is never near this.
SCAN_MAX_BYTES="${SCAN_MAX_BYTES:-65536}"

# Is this path one we are willing to open?
_scan_path_allowed() {
    case "$1" in
        # Repo scratch dirs, either separator.
        */scratch/*|*\\scratch\\*) return 0 ;;
        # Session scratchpad (Claude Code temp root), either separator.
        */Temp/claude/*|*\\Temp\\claude\\*) return 0 ;;
        */temp/claude/*|*\\temp\\claude\\*) return 0 ;;
        *) return 1 ;;
    esac
}

scan_referenced_scripts() {
    local cmd="$1" tok cleaned out='' had_glob=''

    # Cheap pre-check: nothing that looks like a scannable root, do no work at all.
    case "$cmd" in
        *scratch*|*Temp/claude*|*Temp\\claude*|*temp/claude*) : ;;
        *) return 0 ;;
    esac

    # Split on whitespace WITHOUT pathname expansion -- an unquoted $cmd would otherwise
    # glob against the cwd, making what this gate sees depend on what happens to be on disk.
    case "$-" in *f*) had_glob='' ;; *) had_glob=1; set -f ;; esac

    for tok in $cmd; do
        # Strip surrounding quotes and trailing shell punctuation.
        cleaned="${tok%\"}"; cleaned="${cleaned#\"}"
        cleaned="${cleaned%\'}"; cleaned="${cleaned#\'}"
        cleaned="${cleaned%;}"; cleaned="${cleaned%,}"; cleaned="${cleaned%)}"

        # $HOME and ~ ARE resolvable, and must be resolved: short-path-gate.sh tells every
        # session to write scratch paths as "$HOME/..." rather than the 8.3 form, so the
        # harness's own path rule was steering commands into the one shape this scanner
        # could not read. Confirmed live 2026-09-15 -- a script running CREATE/ALTER TABLE
        # was invoked as `bash "$HOME/AppData/Local/Temp/claude/.../x.sh"` and passed both
        # DB gates untouched. Same class as the bypass this file was written for: one gate
        # recommends a shape another gate is blind to.
        case "$cleaned" in
            '$HOME'/*)   cleaned="$HOME/${cleaned#\$HOME/}" ;;
            '${HOME}'/*) cleaned="$HOME/${cleaned#\$\{HOME\}/}" ;;
            '~'/*)       cleaned="$HOME/${cleaned#\~/}" ;;
        esac

        # Anything STILL unexpanded cannot be resolved here -- skip rather than guess. The
        # caller's own "could not resolve the environment" handling covers it.
        case "$cleaned" in
            *'$'*|*'`'*|*'*'*|*'?'*) continue ;;
        esac

        _scan_path_allowed "$cleaned" || continue
        [ -f "$cleaned" ] || continue

        out="$out
$(head -c "$SCAN_MAX_BYTES" "$cleaned" 2>/dev/null)"
    done

    [ -n "$had_glob" ] && set +f

    printf '%s' "$out"
}
