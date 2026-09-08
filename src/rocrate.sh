#!/bin/bash

## @file rocrate.sh

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_encoding_format()
#
# Print a best-guess IANA media type for a packed file, chosen from its base
# name, or nothing when no guess fits. The RO-Crate manifest records the type as
# a File entity's encodingFormat, so a reader knows how to open the file without
# Knit. The guesses cover the file kinds a bundle carries: the provenance
# database, the experiment and job scripts, the JSON lock files, the Spack YAML
# manifests, and the plain-text logs and markers.
#
# @param[in] name The file's base name.
# ------------------------------------------------------------------------------
_knit_rocrate_encoding_format() {
    case "$1" in
        *.db)                        printf 'application/vnd.sqlite3' ;;
        *.sh)                        printf 'text/x-shellscript' ;;
        *.json|*.lock)               printf 'application/json' ;;
        *.yaml|*.yml)                printf 'application/yaml' ;;
        .stdout|.stderr|*.txt|*.log|*.type|*.id) printf 'text/plain' ;;
        *)                           printf '' ;;
    esac
}

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_table_exists()
#
# Test whether a table exists in the database. Used before a "SELECT *" read so a
# per-command table that was registered but never written (no invocation yet)
# does not draw an error.
#
# @param[in] table The table name.
# @return 0 if the table exists, 1 otherwise.
# ------------------------------------------------------------------------------
_knit_rocrate_table_exists() {
    local esc got
    _knit_sql_escape esc "$1"
    got="$(_knit_sqlite3 \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${esc}' LIMIT 1;")"
    [[ -n "${got}" ]]
}

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_outputs_json()
#
# Print, as a JSON array of strings, the normalized output column names of a
# command. The RO-Crate mapping puts a command's inputs (params and flags) in an
# action's "object" and its outputs in the action's "result", so the generator
# needs to know which of a data row's columns are outputs. The names come from
# the command's registration output set and are normalized (hyphens to
# underscores) to match the database column names. An unknown command, or one
# with no outputs, yields the empty array.
#
# @param[in] mangled The mangled command name.
# ------------------------------------------------------------------------------
_knit_rocrate_outputs_json() {
    local mangled="$1"
    local -a names=()
    if [[ -v "_KNIT_CMD_${mangled}_outputs__order" ]]; then
        local out norm
        while IFS= read -r out; do
            [[ -z "${out}" ]] && continue
            norm="$(_knit_name_normalize "${out}")"
            names+=("${norm}")
        done < <(_knit_set_iter "_KNIT_CMD_${mangled}_outputs")
    fi
    if (( ${#names[@]} == 0 )); then
        printf '[]\n'
        return 0
    fi
    # shellcheck disable=SC2016 # $ARGS is a jq variable, not a shell one
    _knit_jq -nc '$ARGS.positional' --args "${names[@]}"
}

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_edges_json()
#
# Print the provenance edges, as a JSON array of objects, one per edge, read
# straight from the __provenance__ table with sqlite's JSON output. The bootstrap
# subtree is filtered out (an edge naming "bootstrap" at either end), so the crate
# describes the science, not the plumbing. The empty array is printed when the
# table is absent or holds no non-bootstrap edge.
# ------------------------------------------------------------------------------
_knit_rocrate_edges_json() {
    if ! _knit_rocrate_table_exists "${_KNIT_PROV_TABLE}"; then
        printf '[]\n'
        return 0
    fi
    local tbl out
    _knit_db_sql_ident tbl "${_KNIT_PROV_TABLE}"
    out="$(_knit_sqlite3 -json \
        "SELECT source_id, source_name, target_id, target_name, edge_type, start_time, end_time FROM ${tbl} WHERE source_name != 'bootstrap' AND target_name != 'bootstrap';")"
    [[ -z "${out}" ]] && out="[]"
    printf '%s\n' "${out}"
}

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_rows_json()
#
# Print the recorded data rows, as a JSON array of objects, one per row, drawn
# from every per-command table that is both registered in this run and present in
# the database. Each object carries the row id, its table and owning command, the
# command's output column names, and the row's full column map ("cols"), so the
# generator can turn a row into an action's PropertyValues and split them into
# inputs and outputs. A table with no rows contributes nothing.
# ------------------------------------------------------------------------------
_knit_rocrate_rows_json() {
    local -a parts=()
    local table cmd mangled outputs_json rows_json tbl_ident
    for table in "${!_KNIT_DB_REGISTERED_TABLES[@]}"; do
        _knit_rocrate_table_exists "${table}" || continue
        cmd="${_KNIT_DB_REGISTERED_TABLES[${table}]}"
        mangled="$(_knit_command_mangle "${cmd}")"
        outputs_json="$(_knit_rocrate_outputs_json "${mangled}")"
        _knit_db_sql_ident tbl_ident "${table}"
        rows_json="$(_knit_sqlite3 -json "SELECT * FROM ${tbl_ident};")"
        [[ -z "${rows_json}" ]] && rows_json="[]"
        # shellcheck disable=SC2016 # $rows etc. are jq variables, not shell ones
        parts+=("$(_knit_jq --argjson rows "${rows_json}" --arg table "${table}" \
            --arg command "${cmd}" --argjson outputs "${outputs_json}" -n \
            '$rows | map({id: (.id // ""), table: $table, command: $command, outputs: $outputs, cols: .})')")
    done
    if (( ${#parts[@]} == 0 )); then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "${parts[@]}" | _knit_jq -s 'add // []'
}

# ------------------------------------------------------------------------------
# @fn _knit_rocrate_files_json()
#
# Print, as a JSON array of objects, one entry per packed file, describing it for
# the RO-Crate data entities. Each entry holds the packed relative path, the
# @id it takes in the crate (a trailing "/" for a directory), the base name, a
# directory flag, a guessed encodingFormat, whether it is the experiment script,
# and — for a file under a job directory — the job's id (so an action can list its
# own logs as results). The manifest file itself is never described as a data
# entity, so it is skipped here.
#
# @param[in] root The absolute experiment root.
# @param[in] script_rel The experiment script's path relative to the root.
# @param[in] job_rel The job root's path relative to the root ("jobs" by default).
# @param[in] ... The packed relative paths.
# ------------------------------------------------------------------------------
_knit_rocrate_files_json() {
    local root="$1" script_rel="$2" job_rel="$3"; shift 3
    local rel src name dir fmt
    local nl=$'\n' us=$'\x1f'
    local stream=""
    for rel in "$@"; do
        [[ -z "${rel}" ]] && continue
        [[ "${rel}" == "ro-crate-metadata.json" ]] && continue
        _knit_bundle_source src "${root}" "${rel}"
        name="${rel##*/}"
        if [[ -d "${src}" ]]; then dir=1; else dir=0; fi
        fmt="$(_knit_rocrate_encoding_format "${name}")"
        stream+="${rel}${us}${name}${us}${dir}${us}${fmt}${nl}"
    done
    # shellcheck disable=SC2016 # $script_rel etc. are jq variables, not shell ones
    printf '%s' "${stream}" | _knit_jq -R -s \
        --arg script_rel "${script_rel}" --arg job_rel "${job_rel}" '
        split("\n") | map(select(length > 0)) | map(split("\u001f"))
        | map({ path: .[0], name: .[1], dir: (.[2] == "1"),
                encodingFormat: (if .[3] == "" then null else .[3] end) })
        | map(. + {
            path_id: (if .dir then (.path + "/") else .path end),
            is_script: (.path == $script_rel),
            job_id: (if ($job_rel != "" and (.path | startswith($job_rel + "/")))
                     then (.path[($job_rel | length) + 1:] | split("/")[0])
                     else null end) })'
}

# ------------------------------------------------------------------------------
# @fn _knit_bundle_rocrate_generate()
#
# Write the RO-Crate manifest (ro-crate-metadata.json) for the experiment. The
# manifest is JSON-LD in the RO-Crate 1.1 / Process Run Crate vocabulary: a
# metadata descriptor, a root Dataset that conforms to the profile and lists the
# packed files (hasPart) and the recorded actions (mentions), a File or Dataset
# data entity per packed path, a SoftwareApplication per distinct command, one
# CreateAction per provenance node, and the PropertyValue entities for the rows'
# columns. The action graph comes from the __provenance__ edges: a "call" edge
# links the caller's result to the callee action; a "used_by" edge links the
# consumer's object to the setup or resource action; a "produced" edge links the
# producer's result to the artifact. Row columns become PropertyValues, split
# into the action's object (inputs) and result (outputs); "native_cmd" becomes
# the action's description and "state" its actionStatus.
#
# The manifest describes exactly the given packed paths, so the same generator
# serves "knit bundle --ro-crate" (the files travel with it) and "knit export
# ro-crate" (the manifest alone, describing the files in place).
#
# @param[in] output The path to write, or "-" for standard output.
# @param[in] root The absolute experiment root.
# @param[in] ... The packed relative paths the manifest must describe.
# ------------------------------------------------------------------------------
_knit_bundle_rocrate_generate() {
    local output="$1" root="$2"; shift 2
    local -a rels=("$@")

    local project
    _knit_metadata_get project "__project__"
    [[ -z "${project}" ]] && project="${KNIT_SCRIPT_NAME%.sh}"

    local author_name="${USER:-Experiment author}"
    local date_pub
    date_pub="$(date -u +%Y-%m-%d)"

    local script_rel="${KNIT_SCRIPT_PATH#"${root}/"}"

    # The job root's relative name matches what collection packed under: the
    # stripped path when the root is inside the tree, else the canonical "jobs".
    local job_root job_rel
    _knit_job_root job_root
    if [[ "${job_root}" == "${root}/"* ]]; then
        job_rel="${job_root#"${root}/"}"
    else
        job_rel="jobs"
    fi

    local files_json edges_json rows_json
    files_json="$(_knit_rocrate_files_json "${root}" "${script_rel}" "${job_rel}" "${rels[@]}")"
    edges_json="$(_knit_rocrate_edges_json)"
    rows_json="$(_knit_rocrate_rows_json)"

    # The graph is assembled entirely in jq: it derives the nodes from the edges,
    # attaches timing, splits row columns into inputs and outputs, and emits every
    # entity. Keeping the logic in one program avoids building nested JSON by hand.
    # shellcheck disable=SC2016 # $edges etc. are jq variables, not shell ones
    local prog='
        def keepcol: .key != "id" and .key != "native_cmd" and .key != "state"
            and .value != null and (.value | tostring) != "";
        ( ([ $edges[] | {id: .source_id, name: .source_name} ]
          + [ $edges[] | {id: .target_id, name: .target_name} ])
          | map(select(.id != null and .id != "")) | unique_by(.id) ) as $nodes
        | ( $nodes | map(.id) ) as $nodeIds
        | ( [ $edges[]
              | select(.edge_type == "call" and .target_id != null and .target_id != "" and .start_time != null)
              | {key: .target_id, value: {start: .start_time, end: .end_time}} ]
            | from_entries ) as $timing
        | ( [ $rows[] | select(.id as $i | $nodeIds | index($i)) ] ) as $noderows
        | ( [ $noderows[] | {key: .id, value: .} ] | from_entries ) as $rowById
        | ( [ $noderows[] as $r | ($r.cols | to_entries[]) | select(keepcol)
              | {"@id": ("#pv-" + $r.id + "-" + .key), "@type": "PropertyValue",
                 "name": .key, "value": (.value | tostring)} ] ) as $pv_entities
        | ( $nodes | map(
            .id as $id | .name as $name
            | ($rowById[$id]) as $row
            | ($timing[$id]) as $tm
            | (($row.outputs) // []) as $outs
            | ( [ $edges[] | select(.edge_type == "call" and .source_id == $id and .target_id != null and .target_id != "") | {"@id": ("#action-" + .target_id)} ]
              + [ $edges[] | select(.edge_type == "produced" and .source_id == $id and .target_id != null and .target_id != "") | {"@id": ("#action-" + .target_id)} ]
              + [ $files[] | select(.job_id == $id) | {"@id": .path_id} ]
              + [ if $row == null then empty else ($row.cols | to_entries[]) as $e | select(($e | keepcol) and ($outs | index($e.key))) | {"@id": ("#pv-" + $id + "-" + $e.key)} end ]
              ) as $result
            | ( [ $edges[] | select(.edge_type == "used_by" and .target_id == $id and .source_id != null and .source_id != "") | {"@id": ("#action-" + .source_id)} ]
              + [ if $row == null then empty else ($row.cols | to_entries[]) as $e | select(($e | keepcol) and (($outs | index($e.key)) | not)) | {"@id": ("#pv-" + $id + "-" + $e.key)} end ]
              ) as $object
            | {"@id": ("#action-" + $id), "@type": "CreateAction", "name": $name,
               "instrument": {"@id": ("#cmd-" + $name)}, "agent": {"@id": $author_id}}
              + (if $tm != null then {"startTime": ($tm.start | floor | todate)} else {} end)
              + (if $tm != null and $tm.end != null then {"endTime": ($tm.end | floor | todate)} else {} end)
              + (if $row != null and (($row.cols.native_cmd) // "") != "" then {"description": $row.cols.native_cmd} else {} end)
              + (if $row != null and (($row.cols.state) // "") != "" then {"actionStatus": {"@id": (
                    if $row.cols.state == "completed" then "http://schema.org/CompletedActionStatus"
                    elif $row.cols.state == "killed" or $row.cols.state == "failed" then "http://schema.org/FailedActionStatus"
                    else "http://schema.org/ActiveActionStatus" end)}} else {} end)
              + (if ($object | length) > 0 then {"object": $object} else {} end)
              + (if ($result | length) > 0 then {"result": $result} else {} end)
          )) as $actions
        | ( $files | map(
            if .is_script then
              {"@id": .path_id, "@type": ["File", "SoftwareSourceCode"], "name": .name,
               "programmingLanguage": {"@id": "#bash"}}
              + (if .encodingFormat != null then {"encodingFormat": .encodingFormat} else {} end)
            elif .dir then
              {"@id": .path_id, "@type": "Dataset", "name": .name}
            else
              {"@id": .path_id, "@type": "File", "name": .name}
              + (if .encodingFormat != null then {"encodingFormat": .encodingFormat} else {} end)
            end) ) as $data_entities
        | ( $nodes | map(.name) | unique
            | map({"@id": ("#cmd-" + .), "@type": "SoftwareApplication", "name": .}) ) as $apps
        | { "@context": $context,
            "@graph": (
              [ {"@id": "ro-crate-metadata.json", "@type": "CreativeWork",
                 "conformsTo": {"@id": $crate_profile}, "about": {"@id": "./"}},
                {"@id": "./", "@type": "Dataset", "name": $name, "description": $description,
                 "datePublished": $date, "conformsTo": {"@id": $run_profile},
                 "author": {"@id": $author_id},
                 "hasPart": ($data_entities | map({"@id": .["@id"]})),
                 "mentions": ($actions | map({"@id": .["@id"]}))},
                {"@id": "#bash", "@type": "ComputerLanguage", "name": "Bash"},
                {"@id": $author_id, "@type": "Person", "name": $author_name},
                {"@id": $run_profile, "@type": "CreativeWork", "name": "Process Run Crate"} ]
              + $apps + $data_entities + $pv_entities + $actions ) }'

    local manifest
    manifest="$(_knit_jq -n \
        --argjson edges "${edges_json}" \
        --argjson rows "${rows_json}" \
        --argjson files "${files_json}" \
        --arg context "https://w3id.org/ro/crate/1.1/context" \
        --arg crate_profile "https://w3id.org/ro/crate/1.1" \
        --arg run_profile "https://w3id.org/ro/wfrun/process/0.5" \
        --arg name "${project}" \
        --arg description "Knit experiment: ${project}." \
        --arg author_id "#person-local" \
        --arg author_name "${author_name}" \
        --arg date "${date_pub}" \
        "${prog}")" \
        || knit_fatal "bundle: failed to build the RO-Crate manifest."

    if [[ "${output}" == "-" ]]; then
        printf '%s\n' "${manifest}"
    else
        printf '%s\n' "${manifest}" > "${output}" \
            || knit_fatal "bundle: failed to write \"%s\"." "${output}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_export_rocrate()
#
# Body of "knit export ro-crate": write the RO-Crate manifest alone, with no
# archive and no copied files. It describes the experiment's on-disk files by
# their current relative paths, using the same default contents "knit bundle"
# would pack, so it is the cheap way to inspect or regenerate the manifest in
# place. The command is read-only: it declares no table and takes
# knit_without_provenance.
#
# @param[in] ... The command invocation arguments.
# ------------------------------------------------------------------------------
_knit_export_rocrate() {
    local output
    output="$(knit_get_parameter "output" "$@")" || output="./ro-crate-metadata.json"
    [[ -z "${output}" ]] && output="./ro-crate-metadata.json"

    local root
    _knit_experiment_root root

    # Rebuild the extern map from scratch: collection fills it while resolving any
    # out-of-tree root, exactly as "knit bundle" does.
    _KNIT_BUNDLE_EXTERN=()

    # shellcheck disable=SC2034 # read by _knit_bundle_collect through a nameref
    local -A bundle_opts=(
        [no_knit]="false"
        [no_db]="false"
        [no_job_logs]="false"
        [no_job_scripts]="false"
        [include_job_content]="false"
        [no_artifacts]="false"
        [include_all_resources]="false"
        [include_resources]=""
    )

    local -a candidates=() paths=()
    _knit_bundle_collect candidates bundle_opts "${root}"
    _knit_bundle_prune_paths paths "${root}" "${candidates[@]}"

    _knit_bundle_rocrate_generate "${output}" "${root}" "${paths[@]}"

    [[ "${output}" != "-" ]] \
        && knit_info "Wrote RO-Crate manifest to %s" "${output}"
    return 0
}

# ------------------------------------------------------------------------------
# Registration of the export command family. "export" is the namespace for format
# serializers that render a view of the graph without packing the payload files;
# "export ro-crate" is its first member. Both need a bootstrapped experiment (they
# read .knit/knit.db), so neither is marked knit_usable_before_bootstrap. They
# record nothing: no table and knit_without_provenance.
# ------------------------------------------------------------------------------
knit_register export knit_empty \
    "Export a view of the experiment in a standard format."
_knit_is_builtin
knit_without_provenance
knit_done

knit_register "export:ro-crate" _knit_export_rocrate \
    "Write the RO-Crate manifest (ro-crate-metadata.json) alone, no archive."
_knit_is_builtin
knit_without_provenance
knit_with_optional "output:path" "./ro-crate-metadata.json" \
    "Where to write the manifest (- for standard output)."
knit_done
