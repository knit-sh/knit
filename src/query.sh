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
# @fn _knit_query_catalog_columns()
#
# Print the column names of a table, one per line, in schema (cid) order, read
# from the live schema via sqlite's `pragma_table_info`. An absent table yields
# no output. Errors are silenced so a missing table is simply empty.
#
# @param[in] table The table name to introspect.
# ------------------------------------------------------------------------------
_knit_query_catalog_columns() {
    _knit_sqlite3 "SELECT name FROM pragma_table_info('${1}') ORDER BY cid;" 2>/dev/null
}

# ------------------------------------------------------------------------------
# @fn _knit_query_catalog_is_graph_table()
#
# Return success when the named table exists and participates in the graph: it is
# the edge table `__provenance__`, or it has an `id` column (the uuid7 key that
# ties node rows to edges). This mirrors the node/edge classification the
# transpiler applies, so the catalog lists exactly the queryable entities.
#
# @param[in] table The table name to test.
# ------------------------------------------------------------------------------
_knit_query_catalog_is_graph_table() {
    local table="$1"
    local -a cols=()
    mapfile -t cols < <(_knit_query_catalog_columns "${table}")
    (( ${#cols[@]} == 0 )) && return 1
    [[ "${table}" == "__provenance__" ]] && return 0
    local col
    for col in "${cols[@]}"; do
        [[ "${col}" == "id" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_query_catalog_has_column()
#
# Return success when the table has a column of the given name.
#
# @param[in] table The table name.
# @param[in] want The column name to look for.
# ------------------------------------------------------------------------------
_knit_query_catalog_has_column() {
    local table="$1" want="$2" col
    while IFS= read -r col; do
        [[ "${col}" == "${want}" ]] && return 0
    done < <(_knit_query_catalog_columns "${table}")
    return 1
}

# ------------------------------------------------------------------------------
# @fn _knit_query_catalog_print_table()
#
# Print one table's listing in the raw catalog format the annotator consumes: a
# `table <name>` line followed by one `  column <name>` line per column.
#
# @param[in] table The table name to print.
# ------------------------------------------------------------------------------
_knit_query_catalog_print_table() {
    local table="$1" col
    printf 'table %s\n' "${table}"
    while IFS= read -r col; do
        [[ -z "${col}" ]] && continue
        printf '  column %s\n' "${col}"
    done < <(_knit_query_catalog_columns "${table}")
}

# ------------------------------------------------------------------------------
# @fn _knit_query_catalog_produce()
#
# Produce the raw (un-annotated) catalog listing on standard output. With no
# reference, list every graph table and its columns, sorted by name. With a
# TABLE reference, list that one table. With a TABLE.COLUMN reference (split at
# the last dot), print the reference when the column exists. An unknown table or
# column is reported to stderr and returns non-zero, so the command exits with a
# failure status just as the engine's `--catalog` mode did.
#
# @param[in] ref Empty to list all; else TABLE or TABLE.COLUMN.
# @return Non-zero on an unknown table/column reference.
# ------------------------------------------------------------------------------
_knit_query_catalog_produce() {
    local ref="$1"

    if [[ -z "${ref}" ]]; then
        local table
        while IFS= read -r table; do
            _knit_query_catalog_print_table "${table}"
        done < <(_knit_query_catalog_graph_tables)
        return 0
    fi

    local tname="${ref}" column=""
    if [[ "${ref}" == *.* ]]; then
        tname="${ref%.*}"
        column="${ref##*.}"
    fi

    if ! _knit_query_catalog_is_graph_table "${tname}"; then
        knit_error "knit query catalog: unknown table: %s" "${tname}"
        return 1
    fi
    if [[ -n "${column}" ]]; then
        if _knit_query_catalog_has_column "${tname}" "${column}"; then
            printf '%s.%s\n' "${tname}" "${column}"
        else
            knit_error "knit query catalog: unknown column: %s.%s" \
                "${tname}" "${column}"
            return 1
        fi
    else
        _knit_query_catalog_print_table "${tname}"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# @fn _knit_query_catalog_graph_tables()
#
# Print the names of every graph table in the database, sorted by name. A table
# is enumerated from sqlite_master (user tables only) and kept when
# _knit_query_catalog_is_graph_table accepts it.
# ------------------------------------------------------------------------------
_knit_query_catalog_graph_tables() {
    local table
    while IFS= read -r table; do
        [[ -z "${table}" ]] && continue
        if _knit_query_catalog_is_graph_table "${table}"; then
            printf '%s\n' "${table}"
        fi
    done < <(_knit_sqlite3 \
        "SELECT name FROM sqlite_master WHERE type='table' \
         AND name NOT LIKE 'sqlite_%' ORDER BY name;")
}

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
# Body of 'query catalog': list the experiment database's tables and columns
# itself (from sqlite_master + PRAGMA table_info via _knit_sqlite3), annotated
# with command-name aliases and column types. With no --ref it lists every graph
# table and its columns; with a TABLE or TABLE.COLUMN reference in --ref it shows
# that table or validates the column, returning non-zero on an unknown reference.
# No external engine is used; the query itself is not recorded.
#
# @param[in] ... The command invocation arguments (an optional --ref TABLE[.COLUMN]).
# @return Non-zero on an unknown table/column reference.
# ------------------------------------------------------------------------------
_knit_query_catalog() {
    local ref
    ref="$(knit_get_parameter "ref" "$@")"

    local output status=0
    output="$(_knit_query_catalog_produce "${ref}")" || status=$?
    (( status != 0 )) && return "${status}"
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
# @fn _knit_query_lens_schema()
#
# Run one introspection pass over the lens and return two things the lens builders
# share: the ATTACH statements for the extra databases (the first database is the
# session's own main schema, so only the rest are attached, read-only as p1, p2,
# ...), and the raw `schema|table|column` rows for every table in every lens
# database. metadata and __provenance__ are included in the rows so a caller can
# classify them as it needs. Rows are ordered by table, then schema, then column
# id, so a table's own-schema columns come before columns a drifted database adds.
# The `file:...?mode=ro` URI is the only way ATTACH opens a database read-only;
# paths from the resolver are plain filesystem paths, so only the SQL-literal quote
# needs escaping.
#
# @param[out] __knit_ret1 Name of the array to fill with the ATTACH statements.
# @param[out] __knit_ret2 Name of the variable to fill with the introspection rows.
# @param[in] ... The lens database paths (index 0 = current/main, rest ATTACHed).
# ------------------------------------------------------------------------------
_knit_query_lens_schema() {
    # shellcheck disable=SC2178 # nameref to the caller's array (attach lines)
    local -n __knit_ret1=$1
    # shellcheck disable=SC2178 # nameref to the caller's scalar (rows text)
    local -n __knit_ret2=$2
    shift 2
    local -a dbs=("$@")

    # __knit_attach_lines is __-prefixed on purpose: callers pass their own output
    # array (named "attach_lines") as $1, so a plain local of that name here would
    # be aliased by the __knit_ret1 nameref (the shadow-collision gotcha).
    local -a __knit_attach_lines=()
    local -a intro_selects=()
    local k schema esc
    for k in "${!dbs[@]}"; do
        if (( k == 0 )); then
            schema="main"
        else
            schema="p${k}"
            _knit_sql_escape esc "${dbs[k]}"
            __knit_attach_lines+=("ATTACH 'file:${esc}?mode=ro' AS ${schema};")
        fi
        intro_selects+=("SELECT '${schema}' AS s, m.name AS t, ti.name AS c, ti.cid AS cid \
FROM ${schema}.sqlite_master m JOIN pragma_table_info(m.name, '${schema}') ti \
WHERE m.type='table' AND m.name NOT LIKE 'sqlite_%'")
    done

    local joined="" i
    for i in "${!intro_selects[@]}"; do
        if (( i == 0 )); then
            joined="${intro_selects[i]}"
        else
            joined+=$'\nUNION ALL\n'"${intro_selects[i]}"
        fi
    done
    local intro_sql=""
    (( ${#__knit_attach_lines[@]} > 0 )) && printf -v intro_sql '%s\n' "${__knit_attach_lines[@]}"
    # cid orders columns within a table; it drives ORDER BY but is not output.
    intro_sql+="SELECT s, t, c FROM (${joined}) ORDER BY t, s, cid;"

    __knit_ret1=("${__knit_attach_lines[@]}")
    local rows
    rows="$(_knit_sqlite3 "${intro_sql}")" \
        || knit_fatal "knit query --extra: could not read the schema of the lens databases."
    # shellcheck disable=SC2178 # nameref to the caller's scalar (rows text)
    __knit_ret2="${rows}"
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

    local -a attach_lines=()
    local intro_out
    _knit_query_lens_schema attach_lines intro_out "${dbs[@]}"

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
    local k schema s t c
    while IFS='|' read -r s t c; do
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
    local ek i
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
# @fn _knit_query_build_catalog()
#
# Create a throwaway catalog database whose empty tables mirror the lens's union
# schema, and return its path. knit-graph --explain reads only the catalog schema
# (its tables and columns, an `id TEXT` column marking a node table), so an empty
# union-schema database is enough for it to transpile a Cypher query against the
# lens. This is always synthesized rather than reusing a lens database, because no
# lens database holds the synthesized `platforms` table, and because it reconciles
# a drifted schema into the union all in one place. The caller removes the file.
#
# The catalog declares: every command table with `id TEXT` first and its union
# columns after (a column already named id is not repeated); the `platforms` table
# (id plus the fingerprint columns) when any lens database has metadata; and the
# `__provenance__` edge table. Column storage types other than the id marker do not
# affect transpilation, so non-id columns are declared TEXT.
#
# @param[out] __knit_ret Name of the variable to hold the catalog database path.
# @param[in] ... The lens database paths.
# ------------------------------------------------------------------------------
_knit_query_build_catalog() {
    # shellcheck disable=SC2178 # nameref to the caller's scalar (catalog path)
    local -n __knit_ret=$1
    shift
    local -a dbs=("$@")

    local -a attach_lines=()
    local intro_out
    _knit_query_lens_schema attach_lines intro_out "${dbs[@]}"

    # Union columns per command table (first seen); note whether any database has
    # metadata (so the platforms table is created only when the lens has it).
    local -a table_order=()
    local -A table_seen=() col_seen=() col_order=()
    local meta_seen="" s t c
    while IFS='|' read -r s t c; do
        [[ -z "${t}" ]] && continue
        [[ "${t}" == "metadata" ]] && { meta_seen=1; continue; }
        [[ "${t}" == "__provenance__" ]] && continue
        if [[ -z "${table_seen["${t}"]:-}" ]]; then
            table_seen["${t}"]=1
            table_order+=("${t}")
        fi
        if [[ -z "${col_seen["${t}|${c}"]:-}" ]]; then
            col_seen["${t}|${c}"]=1
            col_order["${t}"]+="${c}"$'\n'
        fi
    done <<< "${intro_out}"

    local -a ddl=() ucols cols
    local qt qc col cols_joined
    for t in "${table_order[@]}"; do
        _knit_sql_quote_identifier qt "${t}"
        mapfile -t ucols <<< "${col_order["${t}"]}"
        cols=('"id" TEXT')
        for col in "${ucols[@]}"; do
            [[ -z "${col}" || "${col}" == "id" ]] && continue
            _knit_sql_quote_identifier qc "${col}"
            cols+=("${qc} TEXT")
        done
        printf -v cols_joined '%s, ' "${cols[@]}"
        ddl+=("CREATE TABLE ${qt} (${cols_joined%, });")
    done
    [[ -n "${meta_seen}" ]] && ddl+=('CREATE TABLE "platforms" ("id" TEXT, "profile" TEXT, "scheduler" TEXT, "launcher" TEXT, "arch" TEXT, "knit_version" TEXT);')
    ddl+=('CREATE TABLE "__provenance__" (source_id TEXT, source_name TEXT, target_id TEXT, target_name TEXT, edge_type TEXT, start_time REAL, end_time REAL, alias TEXT);')

    # __knit_catalog_db is __-prefixed on purpose: the caller passes its own output
    # variable (named "catalog_db") as $1, so a plain local of that name here would
    # be aliased by the __knit_ret nameref (the shadow-collision gotcha).
    local __knit_catalog_db ddl_sql
    __knit_catalog_db="$(mktemp "${TMPDIR:-/tmp}/knit.catalog.XXXXXX")"
    printf -v ddl_sql '%s\n' "${ddl[@]}"
    _knit_run_isolated "${_KNIT_SQLITE_EXE}" "${__knit_catalog_db}" "${ddl_sql}" \
        || knit_fatal "knit query --extra: could not build the lens catalog database."
    # shellcheck disable=SC2178 # nameref to the caller's scalar (catalog path)
    __knit_ret="${__knit_catalog_db}"
}

# ------------------------------------------------------------------------------
# @fn _knit_query_cleanup_tmps()
#
# Remove the temporary directories a lens created (bundle extraction). Empty
# entries are ignored. Called by a query body after the query has run.
#
# @param[in] __knit_tmps Name of the array of temporary directories to remove.
# ------------------------------------------------------------------------------
_knit_query_cleanup_tmps() {
    local -n __knit_tmps=$1
    local d
    for d in "${__knit_tmps[@]}"; do
        [[ -n "${d}" ]] && rm -rf -- "${d}"
    done
}

# ------------------------------------------------------------------------------
# @fn _knit_query_warn_fingerprint_mismatch()
#
# Warn when two lens databases claim the same platform name with different
# fingerprints. Such a pair survives the platforms view's plain UNION as two rows
# with the same id, so a duplicated id is exactly the mismatch. Each mismatched
# platform is reported once; nothing is dropped, so the query still spans every
# database. An unnamed platform (empty id) is not a same-name claim and is ignored.
# The project name is deliberately not checked (a platform may be named per
# machine). Best effort: a failed check query is silent, never fatal.
#
# @param[in] preamble The lens preamble (which creates the platforms view).
# ------------------------------------------------------------------------------
_knit_query_warn_fingerprint_mismatch() {
    local preamble="$1"
    # No platforms view (no lens database had a metadata table) means nothing to
    # check. A bootstrapped experiment always has one, so this only skips on a
    # bare database.
    [[ "${preamble}" == *'CREATE TEMP VIEW "platforms"'* ]] || return 0
    local dups
    dups="$(_knit_sqlite3 "${preamble}
SELECT id FROM platforms WHERE id IS NOT NULL AND id <> '' GROUP BY id HAVING count(*) > 1;")" \
        || return 0
    local name
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        knit_warning "knit query --extra: platform \"%s\" appears with differing fingerprints (profile, scheduler, launcher, architecture, or knit version) across the queried databases; every variant is included in the results." \
            "${name}"
    done <<< "${dups}"
}

# ------------------------------------------------------------------------------
# @fn _knit_query_exec_over_lens()
#
# Run one SQL statement over the query lens assembled from the already-resolved
# lens databases. The lens preamble (ATTACH + TEMP VIEWs) and the statement run in
# a single _knit_sqlite3 session, because the views are session-scoped; the
# statement refers to the lens views by their bare names. Both `query sql` and
# `query graph` route their --extra path through here (graph after transpiling its
# Cypher to SQL), so lens assembly and execution live in one place. Before running
# the query, a same-name/different-fingerprint platform mismatch is surfaced as a
# warning. The caller resolves the databases and cleans up any temporary
# directories afterward. The output flags are sqlite3 dot-commands, so a caller
# shapes the result the same way an ordinary single-database query does.
#
# @param[in] __knit_dbs Name of the array of lens database paths (main first).
# @param[in] sql        The SQL to run over the lens.
# @param[in] ...        sqlite3 output flags (mode/header/separator dot-commands).
# @return The exit status of sqlite3.
# ------------------------------------------------------------------------------
_knit_query_exec_over_lens() {
    local -n __knit_dbs=$1
    shift
    local sql="$1"
    shift
    local -a out_flags=("$@")

    local preamble
    _knit_query_build_lens_preamble preamble "${__knit_dbs[@]}"

    _knit_query_warn_fingerprint_mismatch "${preamble}"

    _knit_sqlite3 "${out_flags[@]}" "${preamble}
${sql}"
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
# forwarded to knit-graph verbatim. Its exit status is propagated.
#
# The query always spans a read-only lens over the current database plus any
# --extra sources (a lens over one database when there is no --extra). knit-graph
# is used only as a transpiler: it --explains the Cypher against a synthesized
# catalog (whose schema mirrors the lens, including the platforms node), and knit
# runs the resulting SQL over the lens itself, so `(p:platform)` works with or
# without --extra and aggregation/ORDER BY/DISTINCT are correct across every
# platform. The names map gains a `platforms=platform` entry so `(p:platform)`
# resolves to the lens's synthesized platforms view. --explain prints that
# transpiled SQL. (--ast is the one path that does not build a lens: it needs no
# database at all.) knit-graph's output modes are byte-identical to sqlite's, so
# routing every query through sqlite does not change the rendered result.
#
# @param[in] ... The command invocation arguments, plus optional knit-graph args
#        after `--`.
# @return The exit status of knit-graph (--ast) or sqlite3 (the lens query).
# ------------------------------------------------------------------------------
_knit_query_graph() {
    local args=("$@")

    # --explain and --ast are mutually exclusive; that is enforced declaratively
    # by the --when constraint on the --ast flag (see the registration above), so
    # no imperative check is needed here.
    local exec_query explain ast extra_spec
    exec_query="$(knit_get_parameter "exec" "${args[@]}")"
    explain="$(knit_get_parameter "explain" "${args[@]}")" || explain="false"
    ast="$(knit_get_parameter "ast" "${args[@]}")"         || ast="false"
    extra_spec="$(knit_get_parameter "extra" "${args[@]}")" || extra_spec=""

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

    # Every query runs over a lens, even with no --extra: a lens over the single
    # current database still synthesizes the platform node and its executed edges,
    # so (p:platform) works without --extra. --extra just widens the lens to more
    # databases. knit-graph is used only to transpile the Cypher against a
    # synthesized catalog; knit runs the resulting SQL over the lens (or prints it
    # for --explain).
    local -a lens_dbs=() lens_tmps=()
    _knit_query_resolve_extra lens_dbs lens_tmps "${extra_spec}"

    # (p:platform) must resolve to the synthesized platforms view.
    if [[ -n "${names_spec}" ]]; then
        names_spec+=$'\nplatforms=platform'
    else
        names_spec="platforms=platform"
    fi

    local catalog_db
    _knit_query_build_catalog catalog_db "${lens_dbs[@]}"

    local -a explain_args=(--explain --names "${names_spec}" \
        "${catalog_db}" "${exec_query}")
    explain_args+=("${extra[@]}")

    local generated_sql status=0
    generated_sql="$(_knit_knit_graph "${explain_args[@]}")" || status=$?
    rm -f -- "${catalog_db}"
    if (( status != 0 )); then
        _knit_query_cleanup_tmps lens_tmps
        return "${status}"
    fi

    if [[ "${explain}" == "true" ]]; then
        printf '%s\n' "${generated_sql}"
        _knit_query_cleanup_tmps lens_tmps
        return 0
    fi

    # Output shaping moves to sqlite3 (the lens runs the SQL), so translate the
    # shared output options to sqlite3 dot-commands as `query sql` does.
    local no_header="true"
    [[ "${hdr}" == "true" ]] && no_header="false"
    local -a mode_args=()
    _knit_ai_query_mode_args mode_args "${fmt}" "${no_header}" "${sep}"

    _knit_query_exec_over_lens lens_dbs "${generated_sql}" "${mode_args[@]}" || status=$?
    _knit_query_cleanup_tmps lens_tmps
    return "${status}"
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
# The statement always runs over a read-only lens spanning the current database
# plus any --extra sources (a lens over one database when there is no --extra),
# so the synthesized `platforms` view and its `executed` edges are queryable with
# or without --extra. It refers to tables by their bare names, which resolve to
# the lens's union views; the real `metadata` table is not shadowed, so it is
# still queryable directly.
#
# @param[in] ... The command invocation arguments.
# @return The exit status of sqlite3, or fatal on a non-read-only statement.
# ------------------------------------------------------------------------------
_knit_query_sql() {
    local args=("$@")

    local exec_sql extra
    exec_sql="$(knit_get_parameter "exec" "${args[@]}")"
    extra="$(knit_get_parameter "extra" "${args[@]}")" || extra=""

    if ! _knit_ai_sql_is_readonly "${exec_sql}"; then
        knit_fatal "knit query sql: only read-only statements are allowed (leading SELECT/WITH/EXPLAIN/PRAGMA, no write keywords)."
    fi

    local fmt hdr sep
    _knit_query_read_output_opts fmt hdr sep "${args[@]}"

    local no_header="true"
    [[ "${hdr}" == "true" ]] && no_header="false"

    local -a mode_args=()
    _knit_ai_query_mode_args mode_args "${fmt}" "${no_header}" "${sep}"

    # shellcheck disable=SC2034 # lens_dbs/lens_tmps are filled and read by nameref
    local -a lens_dbs=() lens_tmps=()
    _knit_query_resolve_extra lens_dbs lens_tmps "${extra}"
    local status=0
    _knit_query_exec_over_lens lens_dbs "${exec_sql}" "${mode_args[@]}" || status=$?
    _knit_query_cleanup_tmps lens_tmps
    return "${status}"
}
knit_done
