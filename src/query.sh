#!/bin/bash

## @file query.sh

# ------------------------------------------------------------------------------
# @fn _knit_query_read_output_opts()
#
# Read the OUTPUT-OPTS shared by `knit query graph` and `knit query sql` out of a
# command invocation into three caller-named variables. Factored here so both
# query engines parse `--format`/`--header`/`--separator` identically; each then
# translates the values into its own backend's flags (knit-graph's `-<mode>` for
# graph, sqlite3 dot-commands for sql). The format defaults to `list` and the
# header defaults OFF (query output is most often piped elsewhere, where a header
# is noise); the separator defaults to empty (the backend's own default).
#
# @param[out] __knit_ret1 Name of the variable to hold the format value.
# @param[out] __knit_ret2 Name of the variable to hold the header flag ("true"/"false").
# @param[out] __knit_ret3 Name of the variable to hold the separator value.
# @param[in] ... The command invocation arguments to read the options from.
# ------------------------------------------------------------------------------
_knit_query_read_output_opts() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    local -n __knit_ret3=$3
    shift 3
    __knit_ret1="$(knit_get_parameter "format" "$@")"    || __knit_ret1="list"
    __knit_ret2="$(knit_get_parameter "header" "$@")"    || __knit_ret2="false"
    __knit_ret3="$(knit_get_parameter "separator" "$@")" || __knit_ret3=""
}

# ------------------------------------------------------------------------------
# @fn _knit_query_table_alias()
#
# Return, through a caller-named variable, the command name a table is registered
# under when it differs from the table name, or the empty string otherwise. A
# command that overrides its table with knit_with_table (e.g. `submit` -> `jobs`,
# `submit:montecarlo` -> `montecarlo`) has a distinct command-name alias; a
# command whose table is its own name (setups, downloads, plain commands) has
# none. Read from the live registration state (_KNIT_DB_REGISTERED_TABLES), so
# it can never go stale.
#
# @param[out] __knit_ret Name of the variable to hold the alias (empty if none).
# @param[in] table The table name to look up.
# ------------------------------------------------------------------------------
_knit_query_table_alias() {
    local -n __knit_ret=$1
    local table="$2"
    __knit_ret=""
    if [[ -v _KNIT_DB_REGISTERED_TABLES["${table}"] ]]; then
        local cmd="${_KNIT_DB_REGISTERED_TABLES["${table}"]}"
        if [[ "${cmd}" != "${table}" ]]; then
            __knit_ret="${cmd}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# @fn _knit_query_annotate_catalog()
#
# Filter a knit-graph `--catalog` listing read from standard input, annotating it
# with two things read from the live schema: each `table <name>` line whose table
# has a distinct command-name alias gains " (command: <name>)" so users discover
# both spellings of a label, and each `  column <name>` line gains " (<TYPE>)"
# with the column's SQL storage type. Column types are looked up once per table
# (through the stubbable _knit_query_column_types helper) as the table line is
# seen. A TABLE.COLUMN validation line (a single line with no `table `/`  column `
# prefix) is passed through unchanged.
# ------------------------------------------------------------------------------
_knit_query_annotate_catalog() {
    local line table alias col
    local -A types=()
    while IFS= read -r line; do
        if [[ "${line}" == "table "* ]]; then
            table="${line#table }"
            _knit_query_column_types types "${table}"
            _knit_query_table_alias alias "${table}"
            if [[ -n "${alias}" ]]; then
                printf 'table %s (command: %s)\n' "${table}" "${alias}"
                continue
            fi
        elif [[ "${line}" == "  column "* ]]; then
            col="${line#  column }"
            if [[ -v types["${col}"] ]]; then
                printf '  column %s (%s)\n' "${col}" "${types["${col}"]}"
                continue
            fi
        fi
        printf '%s\n' "${line}"
    done
}

# ------------------------------------------------------------------------------
# Registration of the query command group.
#
# `query` commands read the experiment database, so they are NOT usable before
# bootstrap: the central runtime guard refuses them uniformly until the
# experiment is bootstrapped. They are read-only and never recorded (builtins,
# knit_without_provenance, no knit_with_table).
# ------------------------------------------------------------------------------
knit_register query knit_empty \
    "Query the experiment's provenance database (Cypher or SQL)."
_knit_is_builtin
knit_without_provenance
knit_done

# ------------------------------------------------------------------------------
# Registration of 'query catalog'.
# ------------------------------------------------------------------------------
knit_register "query:catalog" _knit_query_catalog \
    "List the database's tables and columns, or validate a reference."
_knit_is_builtin
knit_without_provenance
knit_with_optional "ref:string" "" \
    "TABLE or TABLE.COLUMN reference to show or validate (default: list all)."
# ------------------------------------------------------------------------------
# @fn _knit_query_catalog()
#
# Body of 'query catalog': forward to knit-graph's `--catalog` mode on the
# experiment database and annotate the listing with command-name aliases. With no
# --ref it lists every table and its columns; with a TABLE or TABLE.COLUMN
# reference in --ref it shows that table or validates the column, propagating
# knit-graph's non-zero exit on an unknown reference. Runs on the read-only
# knit-graph binary; the query itself is not recorded.
#
# @param[in] ... The command invocation arguments (an optional --ref TABLE[.COLUMN]).
# @return The exit status of knit-graph.
# ------------------------------------------------------------------------------
_knit_query_catalog() {
    local ref
    ref="$(knit_get_parameter "ref" "$@")"

    local -a cat_args=(--catalog "${_KNIT_DATABASE}")
    [[ -n "${ref}" ]] && cat_args+=("${ref}")

    local output
    output="$(_knit_knit_graph "${cat_args[@]}")" || return "$?"
    _knit_query_annotate_catalog <<< "${output}"
}
knit_done

# ------------------------------------------------------------------------------
# @fn _knit_query_build_names()
#
# Build the name<->table map knit-graph needs (its `--names` SPEC) from the live
# registration state, returned through a caller-named variable. Every registered
# table contributes one `table=command` entry (the command being the demangled
# name knit stores in the provenance `*_name` columns); knit-graph resolves a
# node label through this map to the table it JOINs and the `*_name` value its
# edges carry (see the design's name<->table section). The map is rebuilt on
# every invocation and never persisted, so it can never go stale. Entries are
# sorted for a stable, traceable SPEC. Empty when no table is registered.
#
# @param[out] __knit_ret Name of the variable to hold the newline-separated SPEC.
# ------------------------------------------------------------------------------
_knit_query_build_names() {
    local -n __knit_ret=$1
    local -a entries=()
    local table
    for table in "${!_KNIT_DB_REGISTERED_TABLES[@]}"; do
        entries+=("${table}=${_KNIT_DB_REGISTERED_TABLES[${table}]}")
    done
    if (( ${#entries[@]} == 0 )); then
        __knit_ret=""
        return 0
    fi
    __knit_ret="$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)"
}

# ------------------------------------------------------------------------------
# @fn _knit_query_graph_output_flags()
#
# Translate the shared OUTPUT-OPTS (format/header/separator) into the knit-graph
# output flags, filled into a caller-named array. The format value is a
# query_format enum value that maps 1:1 onto knit-graph's `-<mode>` flag, so no
# lookup table is needed. Header is emitted explicitly (`-header`/`-noheader`)
# because knit-graph defaults it on while knit query defaults it off; a non-empty
# separator adds `-separator <sep>`.
#
# @param[out] __knit_ret Name of the array variable to fill with the knit-graph flags.
# @param[in] format The query_format enum value (e.g. "list", "json").
# @param[in] header "true" to emit a header row, anything else to suppress it.
# @param[in] separator Optional column separator.
# ------------------------------------------------------------------------------
_knit_query_graph_output_flags() {
    local -n __knit_ret=$1
    local format="$2"
    local header="$3"
    local separator="$4"

    __knit_ret=("-${format}")
    if [[ "${header}" == "true" ]]; then
        __knit_ret+=(-header)
    else
        __knit_ret+=(-noheader)
    fi
    [[ -n "${separator}" ]] && __knit_ret+=(-separator "${separator}")
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_query_column_types()
#
# Fill a caller-named associative array with the column name -> SQL storage type
# map of a table, read from the live schema via sqlite's `pragma_table_info`. The
# type is what SQLite records in the schema (e.g. INTEGER, TEXT, REAL), which is
# the universal source: it also covers framework tables (jobs, runs,
# __provenance__) whose columns are not user-declared. Factored out so the
# catalog annotator can enrich each column line and so it is stubbable in unit
# tests. The array is cleared first; an unknown table simply yields no entries.
#
# @param[out] __knit_ret Name of the associative array to fill (name -> type).
# @param[in] table The table name to introspect.
# ------------------------------------------------------------------------------
_knit_query_column_types() {
    # shellcheck disable=SC2178 # nameref to the caller's associative array
    local -n __knit_ret=$1
    local table="$2"
    __knit_ret=()
    local name type
    while IFS='|' read -r name type; do
        [[ -z "${name}" ]] && continue
        __knit_ret["${name}"]="${type}"
    done < <(_knit_sqlite3 \
        "SELECT name, type FROM pragma_table_info('${table}');" 2>/dev/null)
}

# ------------------------------------------------------------------------------
# @fn _knit_query_resolve_extra()
#
# Resolve the --extra source list into the ordered list of database files that
# form the query lens, together with the temporary directories the caller must
# remove after the query. Each comma-separated <src> is one of:
#   - a directory     -> its <dir>/.knit/knit.db is used;
#   - a database file -> used as-is;
#   - a bundle (a .tar.gz or .tgz from `knit bundle`) -> extracted to a fresh
#     temporary directory whose .knit/knit.db is used; the temporary directory is
#     added to the cleanup list.
# The current experiment database (_KNIT_DATABASE) is always the first element,
# so an empty --extra yields exactly [current] and a single-database query is
# unchanged. Extra sources follow in the order given. A source that is neither a
# directory, a database file, nor a bundle, or one that resolves to a database
# that is not readable, is fatal. Empty fields (from a trailing comma) are
# skipped.
#
# @param[out] __knit_ret1 Name of the array to fill with database paths (current first).
# @param[out] __knit_ret2 Name of the array to fill with temporary dirs to remove.
# @param[in] spec The raw --extra value (comma-separated; empty for none).
# ------------------------------------------------------------------------------
_knit_query_resolve_extra() {
    local -n __knit_ret1=$1
    local -n __knit_ret2=$2
    shift 2
    local spec="$1"

    __knit_ret1=("${_KNIT_DATABASE}")
    __knit_ret2=()

    [[ -z "${spec}" ]] && return 0

    local -a sources=()
    IFS=',' read -r -a sources <<< "${spec}"

    local src db tmp
    for src in "${sources[@]}"; do
        [[ -z "${src}" ]] && continue
        if [[ -d "${src}" ]]; then
            db="${src}/.knit/knit.db"
        elif [[ -f "${src}" && ( "${src}" == *.tar.gz || "${src}" == *.tgz ) ]]; then
            tmp="$(mktemp -d "${TMPDIR:-/tmp}/knit.query.XXXXXX")"
            __knit_ret2+=("${tmp}")
            # Extract only the database member: a bundle also carries knit.sh, the
            # experiment script, job logs, and artifacts, none of which a query
            # reads. `knit bundle` stores the member as ".knit/knit.db" (no
            # leading "./"), so name it exactly.
            if ! tar -xzf "${src}" -C "${tmp}" ".knit/knit.db" 2>/dev/null; then
                knit_fatal "knit query --extra: cannot extract .knit/knit.db from bundle \"%s\"." "${src}"
            fi
            db="${tmp}/.knit/knit.db"
        elif [[ -f "${src}" ]]; then
            db="${src}"
        else
            knit_fatal "knit query --extra: source \"%s\" is not a directory, a database file, or a bundle." "${src}"
        fi
        if [[ ! -r "${db}" ]]; then
            knit_fatal "knit query --extra: no readable database at \"%s\" (from source \"%s\")." "${db}" "${src}"
        fi
        __knit_ret1+=("${db}")
    done
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_query_build_lens_preamble()
#
# Build the SQL preamble that turns a _knit_sqlite3 session into the query lens: a
# read-only union over the resolved lens databases. The first database is the
# session's own main schema (it is _KNIT_DATABASE, which _knit_sqlite3 opens), so
# only the extra databases are ATTACHed, each read-only as p1, p2, ... . For every
# command table found in any lens database, a `CREATE TEMP VIEW "<table>"` unions
# that table across every database that has it (a database that lacks the table
# simply contributes no arm). Columns are reconciled from each database's schema:
# the view's column list is the union of the arms' columns, and an arm fills a
# column it lacks with `NULL AS "<col>"`, so script or knit-version drift does not
# break the union.
#
# Two framework tables are handled specially rather than unioned raw. A synthesized
# `platforms` view holds one row per lens database, read from that database's
# metadata (the platform name as id, the fingerprint keys as columns), with a plain
# UNION so identical platforms collapse. The `__provenance__` view unions every
# database's real edges and adds a synthesized `executed` edge from each database's
# platform to every node-table row on it, so a query can go
# `(p:platform)-[:executed]->(n)`.
#
# The returned text is meant to be prepended, in a single _knit_sqlite3
# invocation, to the query that reads the views, because ATTACH and TEMP VIEW are
# session-scoped. The source databases are only read; the views live in the temp
# schema and vanish with the session.
#
# @param[out] __knit_ret Name of the variable to hold the preamble SQL.
# @param[in] ... The lens database paths (index 0 = current/main, rest ATTACHed).
# ------------------------------------------------------------------------------
_knit_query_build_lens_preamble() {
    # shellcheck disable=SC2178 # nameref to the caller's scalar (SQL text)
    local -n __knit_ret=$1
    shift
    local -a dbs=("$@")

    # ATTACH the extra databases read-only, and build the per-schema introspection
    # SELECTs. The first database is already the session's main schema. The
    # `file:...?mode=ro` URI is the only way ATTACH can open read-only; paths from
    # the resolver are plain filesystem paths, so only the SQL-literal quote needs
    # escaping here.
    local -a attach_lines=()
    local -a intro_selects=()
    local k schema esc
    for k in "${!dbs[@]}"; do
        if (( k == 0 )); then
            schema="main"
        else
            schema="p${k}"
            _knit_sql_escape esc "${dbs[k]}"
            attach_lines+=("ATTACH 'file:${esc}?mode=ro' AS ${schema};")
        fi
        intro_selects+=("SELECT '${schema}' AS s, m.name AS t, ti.name AS c, ti.cid AS cid \
FROM ${schema}.sqlite_master m JOIN pragma_table_info(m.name, '${schema}') ti \
WHERE m.type='table' AND m.name NOT LIKE 'sqlite_%'")
    done

    # One introspection pass over the whole lens: (schema, table, column, cid) for
    # every command table. cid orders columns within a table; s keeps a table's
    # own-schema columns ahead of columns only a drifted database adds.
    local intro_sql joined="" i
    for i in "${!intro_selects[@]}"; do
        if (( i == 0 )); then
            joined="${intro_selects[i]}"
        else
            joined+=$'\nUNION ALL\n'"${intro_selects[i]}"
        fi
    done
    intro_sql=""
    (( ${#attach_lines[@]} > 0 )) && printf -v intro_sql '%s\n' "${attach_lines[@]}"
    intro_sql+="${joined} ORDER BY t, s, cid;"

    local intro_out
    intro_out="$(_knit_sqlite3 "${intro_sql}")" \
        || knit_fatal "knit query --extra: could not read the schema of the lens databases."

    # Collect, per table: the schemas that hold it, which columns each holds, and
    # the union column order (first seen wins). metadata and __provenance__ are
    # framework tables handled specially (the platforms view and the provenance
    # view), so their presence per schema is recorded but they are kept out of the
    # command-table structures.
    local -A table_in_schema=() presence=() col_seen=()
    local -A col_order=()
    local -a table_order=()
    local -A table_seen=()
    local -A meta_present=() prov_present=()
    # cid is read only to keep the field alignment; ordering is done in SQL.
    local s t c cid
    # shellcheck disable=SC2034 # cid consumed by read to keep field alignment
    while IFS='|' read -r s t c cid; do
        [[ -z "${t}" ]] && continue
        if [[ "${t}" == "metadata" ]]; then
            meta_present["${s}"]=1
            continue
        fi
        if [[ "${t}" == "__provenance__" ]]; then
            prov_present["${s}"]=1
            continue
        fi
        if [[ -z "${table_seen["${t}"]:-}" ]]; then
            table_seen["${t}"]=1
            table_order+=("${t}")
        fi
        table_in_schema["${s}|${t}"]=1
        presence["${s}|${t}|${c}"]=1
        if [[ -z "${col_seen["${t}|${c}"]:-}" ]]; then
            col_seen["${t}|${c}"]=1
            col_order["${t}"]+="${c}"$'\n'
        fi
    done <<< "${intro_out}"

    # Emit a UNION view per table, each arm listing the union columns in the same
    # order and NULL-filling the ones it lacks.
    local -a stmts=("${attach_lines[@]}")
    local qt qc col sel_joined arms_joined
    local -a ucols sel arms
    for t in "${table_order[@]}"; do
        _knit_sql_quote_identifier qt "${t}"
        mapfile -t ucols <<< "${col_order["${t}"]}"
        arms=()
        for k in "${!dbs[@]}"; do
            if (( k == 0 )); then schema="main"; else schema="p${k}"; fi
            [[ -z "${table_in_schema["${schema}|${t}"]:-}" ]] && continue
            sel=()
            for col in "${ucols[@]}"; do
                [[ -z "${col}" ]] && continue
                _knit_sql_quote_identifier qc "${col}"
                if [[ -n "${presence["${schema}|${t}|${col}"]:-}" ]]; then
                    sel+=("${qc}")
                else
                    sel+=("NULL AS ${qc}")
                fi
            done
            printf -v sel_joined '%s, ' "${sel[@]}"
            arms+=("SELECT ${sel_joined%, } FROM ${schema}.${qt}")
        done
        printf -v arms_joined '%s UNION ALL ' "${arms[@]}"
        stmts+=("CREATE TEMP VIEW ${qt} AS ${arms_joined% UNION ALL };")
    done

    # Synthesize the platforms view: one row per lens database, read from that
    # database's metadata, the platform name as id and the fingerprint keys as
    # columns. A plain UNION collapses identical platform rows; a same-name row
    # whose fingerprint differs survives as a second row (surfaced by a later
    # step). The column<-key mapping mirrors the fingerprint bootstrap records.
    local -a fp_cols=(id profile scheduler launcher arch knit_version)
    local -a fp_keys=(__platform__ __profile__ __scheduler__ __launcher__ __arch__ __knit_version__)
    local -a plat_arms=() psel=()
    local ek
    for k in "${!dbs[@]}"; do
        if (( k == 0 )); then schema="main"; else schema="p${k}"; fi
        [[ -z "${meta_present["${schema}"]:-}" ]] && continue
        psel=()
        for i in "${!fp_cols[@]}"; do
            _knit_sql_quote_identifier qc "${fp_cols[i]}"
            _knit_sql_escape ek "${fp_keys[i]}"
            psel+=("(SELECT value FROM ${schema}.metadata WHERE key='${ek}') AS ${qc}")
        done
        printf -v sel_joined '%s, ' "${psel[@]}"
        plat_arms+=("SELECT ${sel_joined%, }")
    done
    if (( ${#plat_arms[@]} > 0 )); then
        printf -v arms_joined '%s UNION ' "${plat_arms[@]}"
        stmts+=("CREATE TEMP VIEW \"platforms\" AS ${arms_joined% UNION };")
    fi

    # Synthesize the __provenance__ view: the real edges of every database, plus a
    # synthesized "executed" edge from each database's platform to every node-table
    # row on it. A node's target_name is the command name knit-graph resolves the
    # node's label to, so the platform-to-node hop matches a
    # (p:platform)-[:executed]->(n) query. The platform is the edge source, as the
    # used_by convention keeps the relationship a single flat hop.
    local -a prov_arms=()
    local prov_cols="source_id, source_name, target_id, target_name, edge_type, start_time, end_time, alias"
    for k in "${!dbs[@]}"; do
        if (( k == 0 )); then schema="main"; else schema="p${k}"; fi
        [[ -n "${prov_present["${schema}"]:-}" ]] \
            && prov_arms+=("SELECT ${prov_cols} FROM ${schema}.\"__provenance__\"")
    done
    local cmdname ecmd eplat_key
    _knit_sql_escape eplat_key "__platform__"
    for t in "${table_order[@]}"; do
        cmdname="${_KNIT_DB_REGISTERED_TABLES[${t}]:-${t}}"
        _knit_sql_escape ecmd "${cmdname}"
        _knit_sql_quote_identifier qt "${t}"
        for k in "${!dbs[@]}"; do
            if (( k == 0 )); then schema="main"; else schema="p${k}"; fi
            [[ -z "${table_in_schema["${schema}|${t}"]:-}" ]] && continue
            # A node table without an id cannot anchor an edge, and its platform is
            # read from metadata; skip an arm that lacks either.
            [[ -z "${presence["${schema}|${t}|id"]:-}" ]] && continue
            [[ -z "${meta_present["${schema}"]:-}" ]] && continue
            prov_arms+=("SELECT (SELECT value FROM ${schema}.metadata WHERE key='${eplat_key}') AS source_id, 'platform' AS source_name, \"id\" AS target_id, '${ecmd}' AS target_name, 'executed' AS edge_type, NULL AS start_time, NULL AS end_time, NULL AS alias FROM ${schema}.${qt}")
        done
    done
    if (( ${#prov_arms[@]} > 0 )); then
        printf -v arms_joined '%s UNION ALL ' "${prov_arms[@]}"
        stmts+=("CREATE TEMP VIEW \"__provenance__\" AS ${arms_joined% UNION ALL };")
    fi

    local out=""
    (( ${#stmts[@]} > 0 )) && printf -v out '%s\n' "${stmts[@]}"
    # shellcheck disable=SC2178 # nameref to the caller's scalar (SQL text)
    __knit_ret="${out}"
}

# ------------------------------------------------------------------------------
# The query_format enum (shared by 'ai query', 'query graph', and 'query sql') is
# defined in src/ai.sh, which loads before this file, so its type resolves when
# the `format:query_format` parameters below are declared.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Registration of 'query graph'.
# ------------------------------------------------------------------------------
knit_register "query:graph" _knit_query_graph \
    "Run a read-only Cypher query against the provenance database via knit-graph."
_knit_is_builtin
knit_without_provenance
knit_with_required "exec:string" \
    "The Cypher statement to run (passed verbatim to knit-graph)."
knit_with_optional "extra:string" "" \
    "Comma-separated extra sources to query alongside this experiment's database. Each is a directory (its .knit/knit.db is used), a database file, or a bundle (.tar.gz, extracted to a temporary directory). The current database is always included."
knit_with_optional "format:query_format" "list" \
    "Output mode: list, json, box, csv, markdown, table, line, html, ascii, column, tabs." \
    --when '.explain != "true" and .ast != "true"'
knit_with_flag "header" \
    "Add a header row (off by default)." \
    --when '.explain != "true" and .ast != "true"'
knit_with_optional "separator:string" "" \
    "Column separator (defaults to knit-graph's default)." \
    --when '.explain != "true" and .ast != "true"'
knit_with_flag "explain" \
    "Print the generated SQL without running it."
knit_with_flag "ast" \
    "Print the parsed syntax tree (no database needed)." \
    --when '.explain != "true"'
knit_with_extra "Extra arguments forwarded verbatim to knit-graph after --."
# ------------------------------------------------------------------------------
# @fn _knit_query_graph()
#
# Body of 'query graph': run the --exec Cypher statement through knit-graph,
# augmented with the live name<->table map (so a node label may be written as
# either its table name or its command name) and the resolved output flags. With
# --explain knit-graph prints the generated SQL instead of running it; with --ast
# it prints the parse tree (no database, map, or output flags needed).
# --explain and --ast are mutually exclusive. Anything after a trailing `--` is
# forwarded to knit-graph verbatim. knit-graph's exit status is propagated.
#
# @param[in] ... The command invocation arguments, plus optional knit-graph args
#        after `--`.
# @return The exit status of knit-graph.
# ------------------------------------------------------------------------------
_knit_query_graph() {
    local args=("$@")

    # --explain and --ast are mutually exclusive; that is enforced declaratively
    # by the --when constraint on the --ast flag (see the registration above), so
    # no imperative check is needed here.
    local exec_query explain ast
    exec_query="$(knit_get_parameter "exec" "${args[@]}")"
    explain="$(knit_get_parameter "explain" "${args[@]}")" || explain="false"
    ast="$(knit_get_parameter "ast" "${args[@]}")"         || ast="false"

    local extra_index
    extra_index=$(knit_extra_index "${args[@]}")
    local extra=("${args[@]:extra_index}")

    # --ast needs neither the database nor the name map nor output flags.
    if [[ "${ast}" == "true" ]]; then
        _knit_knit_graph --ast "${exec_query}" "${extra[@]}"
        return "$?"
    fi

    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep "${args[@]}"

    local names_spec
    _knit_query_build_names names_spec

    local -a out_flags=()
    _knit_query_graph_output_flags out_flags "${fmt}" "${hdr}" "${sep}"

    local -a kg_args=()
    [[ "${explain}" == "true" ]] && kg_args+=(--explain)
    [[ -n "${names_spec}" ]] && kg_args+=(--names "${names_spec}")
    kg_args+=("${out_flags[@]}")
    kg_args+=("${_KNIT_DATABASE}" "${exec_query}")
    kg_args+=("${extra[@]}")

    _knit_knit_graph "${kg_args[@]}"
}
knit_done

# ------------------------------------------------------------------------------
# Registration of 'query sql'.
# ------------------------------------------------------------------------------
knit_register "query:sql" _knit_query_sql \
    "Run a read-only SQL query against the provenance database."
_knit_is_builtin
knit_without_provenance
knit_with_required "exec:string" \
    "The SQL statement to run (must be read-only)."
knit_with_optional "extra:string" "" \
    "Comma-separated extra sources to query alongside this experiment's database. Each is a directory (its .knit/knit.db is used), a database file, or a bundle (.tar.gz, extracted to a temporary directory). The current database is always included."
knit_with_optional "format:query_format" "list" \
    "Output mode: list, json, box, csv, markdown, table, line, html, ascii, column, tabs."
knit_with_flag "header" \
    "Add a header row (off by default)."
knit_with_optional "separator:string" "" \
    "Column separator (defaults to sqlite3's default)."
# ------------------------------------------------------------------------------
# @fn _knit_query_sql()
#
# Body of 'query sql': run the --exec SQL statement on knit's own read path
# (_knit_sqlite3) with the shared output options shaping the result. The
# statement is rejected unless it is read-only (leading SELECT/WITH/EXPLAIN/PRAGMA
# and no write keyword, via the shared guard) so a query can never mutate the
# provenance database. Output opts are read with the shared reader and translated
# to sqlite3 `.mode`/`.headers`/`.separator` dot-commands by the same helper
# `ai query` uses, so SQL and Cypher results present identically. sqlite3's exit
# status is propagated.
#
# @param[in] ... The command invocation arguments.
# @return The exit status of sqlite3, or fatal on a non-read-only statement.
# ------------------------------------------------------------------------------
_knit_query_sql() {
    local args=("$@")

    local exec_sql
    exec_sql="$(knit_get_parameter "exec" "${args[@]}")"

    if ! _knit_ai_sql_is_readonly "${exec_sql}"; then
        knit_fatal "knit query sql: only read-only statements are allowed (leading SELECT/WITH/EXPLAIN/PRAGMA, no write keywords)."
    fi

    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep "${args[@]}"

    local no_header="true"
    [[ "${hdr}" == "true" ]] && no_header="false"

    local -a mode_args=()
    _knit_ai_query_mode_args mode_args "${fmt}" "${no_header}" "${sep}"

    _knit_sqlite3 "${mode_args[@]}" "${exec_sql}"
}
knit_done
