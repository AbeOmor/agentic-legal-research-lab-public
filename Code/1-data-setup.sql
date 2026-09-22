\set ON_ERROR_STOP on
\pset pager off
\timing on

-- Companion to 1-data-setup.ipynb.
--
-- Run this file with psql from the Code directory so the relative CSV path
-- resolves correctly:
--
--   cd "Code"
--   set -a
--   source ../.env
--   set +a
--   PGPASSWORD="$AZURE_PG_PASSWORD" psql \
--     "host=$AZURE_PG_HOST port=$AZURE_PG_PORT dbname=$AZURE_PG_NAME user=$AZURE_PG_USER sslmode=${AZURE_PG_SSLMODE:-require}" \
--     -f 1-data-setup.sql
--
-- To validate the connection and parameter-group prerequisites without
-- rebuilding anything, add: -v DRY_RUN=true
--
-- The script is destructive to the lab objects: it rebuilds public.cases,
-- public.temp_cases, public.case_opinion_chunks, case_graph, and the indexes.

\if :{?DRY_RUN}
\else
  \set DRY_RUN false
\endif

\echo
\echo '=== 1. Load Azure OpenAI settings from the shell environment ==='

\getenv AZURE_OPENAI_ENDPOINT AZURE_OPENAI_ENDPOINT
\getenv AZURE_OPENAI_DEPLOYMENT AZURE_OPENAI_DEPLOYMENT
\getenv AZURE_OPENAI_KEY AZURE_OPENAI_KEY
\getenv AZURE_EMBED_DEPLOYMENT AZURE_EMBED_DEPLOYMENT
\getenv AZURE_API_VERSION AZURE_API_VERSION

\if :{?AZURE_OPENAI_ENDPOINT}
\else
  \echo 'AZURE_OPENAI_ENDPOINT is missing. Export the variables from ../.env first.'
  \quit
\endif
\if :{?AZURE_OPENAI_DEPLOYMENT}
\else
  \echo 'AZURE_OPENAI_DEPLOYMENT is missing. Export the variables from ../.env first.'
  \quit
\endif
\if :{?AZURE_OPENAI_KEY}
\else
  \echo 'AZURE_OPENAI_KEY is missing. Export the variables from ../.env first.'
  \quit
\endif
\if :{?AZURE_EMBED_DEPLOYMENT}
\else
  \echo 'AZURE_EMBED_DEPLOYMENT is missing. Export the variables from ../.env first.'
  \quit
\endif
\if :{?AZURE_API_VERSION}
\else
  \echo 'AZURE_API_VERSION is missing. Export the variables from ../.env first.'
  \quit
\endif

\set CHAT_MODEL_ALIAS lab-chat
\set EMBED_MODEL_ALIAS lab-embedding
\set PIPELINE_NAME case_opinion_embedding_pipeline
\set EMBED_DIMS 1536

SELECT current_database() AS database_name,
       current_user AS database_user,
       version() AS server_version;

\echo
\echo '=== 2. Verify HorizonDB extension and preload configuration ==='

SELECT current_setting('azure.extensions', true) AS allowed_extensions,
       current_setting('shared_preload_libraries', true) AS preloaded_libraries;

DO $$
DECLARE
    extension_name text;
    allowed text[] := regexp_split_to_array(
        coalesce(current_setting('azure.extensions', true), ''),
        '\s*,\s*'
    );
    preloaded text[] := regexp_split_to_array(
        coalesce(current_setting('shared_preload_libraries', true), ''),
        '\s*,\s*'
    );
BEGIN
    FOREACH extension_name IN ARRAY ARRAY[
        'azure_ai', 'vector', 'age', 'pg_diskann', 'pg_textsearch'
    ]
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_extension WHERE extname = extension_name
        ) THEN
            RAISE NOTICE '% is already installed', extension_name;
        ELSIF NOT EXISTS (
            SELECT 1 FROM pg_available_extensions WHERE name = extension_name
        ) THEN
            RAISE EXCEPTION
                'Required extension % is unavailable on this cluster',
                extension_name;
        ELSIF NOT extension_name = ANY(allowed) THEN
            RAISE EXCEPTION
                'Add % to azure.extensions in the connected HorizonDB parameter group',
                extension_name;
        ELSE
            EXECUTE format('CREATE EXTENSION %I CASCADE', extension_name);
            RAISE NOTICE '% installed', extension_name;
        END IF;
    END LOOP;

    FOREACH extension_name IN ARRAY ARRAY['age', 'pg_textsearch']
    LOOP
        IF NOT extension_name = ANY(preloaded) THEN
            RAISE EXCEPTION
                'Add % to shared_preload_libraries, reconnect the parameter group, and wait for the cluster restart',
                extension_name;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_durable'
    ) THEN
        RAISE NOTICE 'pg_durable is already installed';
    ELSIF 'pg_durable' = ANY(allowed)
          AND 'pg_durable' = ANY(preloaded) THEN
        EXECUTE 'CREATE EXTENSION pg_durable CASCADE';
        RAISE NOTICE 'pg_durable installed';
    ELSE
        RAISE NOTICE
            'pg_durable is optional; add it to azure.extensions and shared_preload_libraries for df.instances history';
    END IF;
END
$$;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN (
    'azure_ai', 'vector', 'age', 'pg_diskann', 'pg_textsearch', 'pg_durable'
)
ORDER BY extname;

\if :DRY_RUN
  \echo
  \echo 'DRY_RUN complete: connection, extension availability, and preload settings are valid.'
  \quit
\endif

\echo
\echo '=== 3. Register the lab chat and embedding model aliases ==='

SELECT model_registry.model_remove(alias)
FROM model_registry.model_list_all()
WHERE alias IN (:'CHAT_MODEL_ALIAS', :'EMBED_MODEL_ALIAS');

SELECT model_registry.model_add(
    :'CHAT_MODEL_ALIAS',
    :'AZURE_OPENAI_ENDPOINT',
    :'AZURE_OPENAI_DEPLOYMENT',
    :'AZURE_OPENAI_DEPLOYMENT',
    :'AZURE_API_VERSION',
    'subscription-key',
    :'AZURE_OPENAI_KEY'
);

SELECT model_registry.model_add(
    :'EMBED_MODEL_ALIAS',
    :'AZURE_OPENAI_ENDPOINT',
    :'AZURE_EMBED_DEPLOYMENT',
    :'AZURE_EMBED_DEPLOYMENT',
    :'AZURE_API_VERSION',
    'subscription-key',
    :'AZURE_OPENAI_KEY'
);

SELECT alias, endpoint, deployment_name, model_name, api_version, auth_type
FROM model_registry.model_list_all()
WHERE alias IN (:'CHAT_MODEL_ALIAS', :'EMBED_MODEL_ALIAS')
ORDER BY alias;

\echo
\echo '=== 4. Stop the old pipeline and rebuild the relational source tables ==='

SELECT ai.drop_pipeline(:'PIPELINE_NAME')
FROM ai.list_pipelines()
WHERE name = :'PIPELINE_NAME';

DROP TABLE IF EXISTS public.case_opinion_chunks CASCADE;
DROP TABLE IF EXISTS public.cases CASCADE;
DROP TABLE IF EXISTS public.temp_cases;

CREATE TABLE public.cases (
    id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    name text,
    decision_date date,
    court_level text,
    opinion text
);

CREATE TABLE public.temp_cases (
    data jsonb
);

\echo 'Loading ../Dataset/cases.csv with client-side psql \copy...'
\copy public.temp_cases(data) FROM '../Dataset/cases.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO public.cases (
    id,
    name,
    decision_date,
    court_level,
    opinion
)
SELECT
    (data #>> '{id}')::integer,
    data #>> '{name_abbreviation}',
    (data #>> '{decision_date}')::date,
    data #>> '{court,name}',
    array_to_string(
        ARRAY(
            SELECT jsonb_path_query(
                temp_cases.data,
                '$.casebody.opinions[*].text'
            ) #>> '{}'
        ),
        E'\n\n'
    )
FROM public.temp_cases;

SELECT setval(
    pg_get_serial_sequence('public.cases', 'id'),
    coalesce(max(id), 1),
    max(id) IS NOT NULL
)
FROM public.cases;

SELECT count(*) AS loaded_cases
FROM public.cases;

\echo
\echo '=== 5. Build and run the manual chunk-and-embed AI Pipeline ==='

CREATE TABLE public.case_opinion_chunks (
    doc_id integer,
    chunk_index integer,
    chunk_text text,
    embedding vector(1536),
    metadata jsonb,
    court_level text,
    decision_date date
);

CREATE INDEX idx_case_opinion_chunks_doc_id
ON public.case_opinion_chunks (doc_id);

CREATE INDEX idx_case_opinion_chunks_court_date
ON public.case_opinion_chunks (court_level, decision_date);

SELECT ai.create_pipeline(
    name => :'PIPELINE_NAME',
    source => ai.table_source(
        table_name => 'cases',
        schema_name => 'public'
    ),
    steps => ARRAY[
        ai.chunk(
            input => 'opinion',
            chunk_size => 512,
            method => 'token',
            overlap => 64
        ),
        ai.embed(
            input => 'chunk_text',
            model => :'EMBED_MODEL_ALIAS',
            dimensions => :EMBED_DIMS
        )
    ],
    trigger => 'manual',
    sink => ai.table_sink(
        table_name => 'case_opinion_chunks',
        schema_name => 'public'
    )
);

SELECT ai.explain(:'PIPELINE_NAME');
SELECT ai.run(:'PIPELINE_NAME');

DO $$
DECLARE
    state text := '';
    attempt integer;
    chunk_rows bigint;
    embedded_rows bigint;
BEGIN
    FOR attempt IN 1..180 LOOP
        SELECT lower(coalesce(last_run_status, ''))
        INTO state
        FROM ai.status('case_opinion_embedding_pipeline')
        LIMIT 1;

        SELECT count(*), count(embedding)
        INTO chunk_rows, embedded_rows
        FROM public.case_opinion_chunks;

        RAISE NOTICE
            'pipeline state=%, sink rows=%, embedded rows=%',
            coalesce(nullif(state, ''), 'pending'),
            chunk_rows,
            embedded_rows;

        EXIT WHEN state IN (
            'completed', 'succeeded', 'failed', 'cancelled', 'error'
        );

        PERFORM pg_sleep(10);
    END LOOP;

    IF state NOT IN ('completed', 'succeeded') THEN
        RAISE EXCEPTION
            'Pipeline did not complete successfully; final state=%',
            coalesce(nullif(state, ''), 'timeout');
    END IF;
END
$$;

\echo
\echo '=== 6. Replace preview pipeline ordinals with source case IDs ==='

DO $$
DECLARE
    mapped_docs bigint;
    mapping_rows bigint;
    pipeline_docs bigint;
    enriched_rows bigint;
BEGIN
    WITH probes AS MATERIALIZED (
        SELECT DISTINCT ON (doc_id)
               doc_id AS pipeline_doc_id,
               btrim(regexp_replace(chunk_text, '[[:space:]]+', ' ', 'g')) AS normalized
        FROM public.case_opinion_chunks
        WHERE chunk_text IS NOT NULL
        ORDER BY doc_id, chunk_index
    ),
    sources AS MATERIALIZED (
        SELECT id, court_level, decision_date,
               btrim(regexp_replace(opinion, '[[:space:]]+', ' ', 'g')) AS normalized
        FROM public.cases
    ),
    mapping AS MATERIALIZED (
        SELECT
            probes.pipeline_doc_id,
            cases.id AS case_id,
            cases.court_level,
            cases.decision_date
        FROM probes
        JOIN sources AS cases
          ON probes.normalized <> ''
         AND position(probes.normalized IN cases.normalized) > 0
    )
    SELECT
        count(DISTINCT pipeline_doc_id),
        count(*),
        (SELECT count(DISTINCT doc_id) FROM public.case_opinion_chunks)
    INTO mapped_docs, mapping_rows, pipeline_docs
    FROM mapping;

    IF mapped_docs <> pipeline_docs OR mapping_rows <> pipeline_docs THEN
        RAISE EXCEPTION
            'Could not uniquely map pipeline documents: mapped=%, candidates=%, expected=%',
            mapped_docs,
            mapping_rows,
            pipeline_docs;
    END IF;

    WITH probes AS MATERIALIZED (
        SELECT DISTINCT ON (doc_id)
               doc_id AS pipeline_doc_id,
               btrim(regexp_replace(chunk_text, '[[:space:]]+', ' ', 'g')) AS normalized
        FROM public.case_opinion_chunks
        WHERE chunk_text IS NOT NULL
        ORDER BY doc_id, chunk_index
    ),
    sources AS MATERIALIZED (
        SELECT id, court_level, decision_date,
               btrim(regexp_replace(opinion, '[[:space:]]+', ' ', 'g')) AS normalized
        FROM public.cases
    ),
    mapping AS MATERIALIZED (
        SELECT
            probes.pipeline_doc_id,
            cases.id AS case_id,
            cases.court_level,
            cases.decision_date
        FROM probes
        JOIN sources AS cases
          ON probes.normalized <> ''
         AND position(probes.normalized IN cases.normalized) > 0
    )
    UPDATE public.case_opinion_chunks AS chunks
    SET doc_id = mapping.case_id,
        metadata = jsonb_build_object(
            'source_case_id',
            mapping.case_id
        ),
        court_level = mapping.court_level,
        decision_date = mapping.decision_date
    FROM mapping
    WHERE chunks.doc_id = mapping.pipeline_doc_id;

    GET DIAGNOSTICS enriched_rows = ROW_COUNT;
    RAISE NOTICE 'Enriched % chunk rows', enriched_rows;
END
$$;

\echo
\echo '=== 7. Verify the source-to-sink data contract ==='

WITH checks AS (
    SELECT
        (SELECT count(*) FROM public.cases) AS source_cases,
        (SELECT count(*) FROM public.case_opinion_chunks) AS chunk_rows,
        (
            SELECT count(*)
            FROM public.case_opinion_chunks
            WHERE embedding IS NULL
        ) AS null_embeddings,
        (
            SELECT count(*)
            FROM public.case_opinion_chunks
            WHERE chunk_text IS NULL OR btrim(chunk_text) = ''
        ) AS empty_chunks,
        (
            SELECT count(*)
            FROM public.case_opinion_chunks
            WHERE court_level IS NULL OR decision_date IS NULL
        ) AS missing_filter_metadata,
        (
            SELECT count(*)
            FROM public.cases AS cases
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.case_opinion_chunks AS chunks
                WHERE chunks.doc_id = cases.id
            )
        ) AS source_cases_without_chunks,
        (
            SELECT count(*)
            FROM public.case_opinion_chunks AS chunks
            LEFT JOIN public.cases AS cases
              ON cases.id = chunks.doc_id
            WHERE cases.id IS NULL
        ) AS orphaned_chunks,
        (
            SELECT count(*)
            FROM public.case_opinion_chunks AS chunks
            JOIN public.cases AS cases
              ON cases.id = chunks.doc_id
            WHERE chunks.court_level IS DISTINCT FROM cases.court_level
               OR chunks.decision_date IS DISTINCT FROM cases.decision_date
        ) AS metadata_mismatches
)
SELECT *
FROM checks;

SELECT vector_dims(embedding) AS dimensions,
       count(*) AS rows
FROM public.case_opinion_chunks
WHERE embedding IS NOT NULL
GROUP BY vector_dims(embedding)
ORDER BY dimensions;

\echo
\echo '=== 8. Rebuild the Apache AGE citation graph ==='

SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION public.create_case_in_case_graph(
    case_id text,
    name text,
    decision_date text,
    court_level text,
    opinion text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = ag_catalog
AS $function$
DECLARE
    props ag_catalog.agtype;
BEGIN
    props := agtype_build_map(
        'case_id', case_id,
        'name', name,
        'decision_date', decision_date,
        'court_level', court_level,
        'opinion', opinion
    );

    EXECUTE $sql$
        SELECT *
        FROM cypher(
            'case_graph',
            $cypher$
                CREATE (:case {
                    case_id: $case_id,
                    name: $name,
                    decision_date: $decision_date,
                    court_level: $court_level,
                    opinion: $opinion
                })
            $cypher$,
            $1
        ) AS (node agtype)
    $sql$
    USING props;
END
$function$;

CREATE OR REPLACE FUNCTION public.create_case_link_in_case_graph(
    id_from text,
    id_to text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = ag_catalog
AS $function$
DECLARE
    props ag_catalog.agtype;
BEGIN
    props := agtype_build_map(
        'id_from', id_from,
        'id_to', id_to
    );

    EXECUTE $sql$
        SELECT *
        FROM cypher(
            'case_graph',
            $cypher$
                MATCH (source:case), (target:case)
                WHERE source.case_id = $id_from
                  AND target.case_id = $id_to
                CREATE (source)-[edge:REF]->(target)
                RETURN edge
            $cypher$,
            $1
        ) AS (edge agtype)
    $sql$
    USING props;
END
$function$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ag_catalog.ag_graph
        WHERE name = 'case_graph'
    ) THEN
        PERFORM ag_catalog.drop_graph('case_graph', true);
    END IF;

    PERFORM ag_catalog.create_graph('case_graph');
END
$$;

DO $$
DECLARE
    source_case record;
BEGIN
    FOR source_case IN
        SELECT
            id::text AS case_id,
            name,
            decision_date::text,
            court_level,
            opinion
        FROM public.cases
    LOOP
        PERFORM public.create_case_in_case_graph(
            source_case.case_id,
            source_case.name,
            source_case.decision_date,
            source_case.court_level,
            source_case.opinion
        );
    END LOOP;
END
$$;

DO $$
DECLARE
    citation record;
    edge_count bigint := 0;
BEGIN
    FOR citation IN
        WITH edges AS (
            SELECT
                source_row.data #>> '{id}' AS id_from,
                target_row.data #>> '{id}' AS id_to
            FROM public.temp_cases AS source_row
            LEFT JOIN LATERAL
                jsonb_array_elements(source_row.data -> 'cites_to')
                AS citation_entry ON true
            LEFT JOIN LATERAL
                jsonb_array_elements_text(citation_entry -> 'case_ids')
                AS cited(case_id) ON true
            JOIN public.temp_cases AS target_row
              ON cited.case_id = target_row.data #>> '{id}'
        )
        SELECT id_from, id_to
        FROM edges
    LOOP
        PERFORM public.create_case_link_in_case_graph(
            citation.id_from,
            citation.id_to
        );
        edge_count := edge_count + 1;
    END LOOP;

    RAISE NOTICE 'Created % citation edges', edge_count;
END
$$;

SELECT *
FROM cypher(
    'case_graph',
    $$
        MATCH (node:case)
        RETURN count(node) AS node_count
    $$
) AS (node_count agtype);

SELECT *
FROM cypher(
    'case_graph',
    $$
        MATCH ()-[edge:REF]->()
        RETURN count(edge) AS edge_count
    $$
) AS (edge_count agtype);

\echo
\echo '=== 9. Build the BM25 index ==='

SET search_path = public, ag_catalog, "$user";

DROP INDEX IF EXISTS public.idx_cases_bm25;

CREATE INDEX idx_cases_bm25
ON public.cases
USING bm25 (opinion)
WITH (text_config = 'english');

SELECT id,
       name,
       opinion <@> 'water leaking' AS bm25_score
FROM public.cases
ORDER BY opinion <@> 'water leaking'
LIMIT 5;

\echo
\echo '=== 10. Build the DiskANN index ==='

DROP INDEX IF EXISTS public.idx_case_opinion_chunks_diskann;

DO $$
BEGIN
    BEGIN
        EXECUTE $ddl$
            CREATE INDEX idx_case_opinion_chunks_diskann
            ON public.case_opinion_chunks
            USING diskann (embedding vector_cosine_ops)
            WITH (spherical_quantized = true)
        $ddl$;
        RAISE NOTICE 'Built DiskANN with spherical quantization';
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE
                'Spherical quantization unavailable (%); using full precision',
                SQLERRM;
            EXECUTE $ddl$
                CREATE INDEX idx_case_opinion_chunks_diskann
                ON public.case_opinion_chunks
                USING diskann (embedding vector_cosine_ops)
            $ddl$;
    END;
END
$$;

SELECT index_class.relname AS index_name,
       index_state.indisvalid,
       index_state.indisready,
       pg_get_indexdef(index_state.indexrelid) AS definition
FROM pg_index AS index_state
JOIN pg_class AS index_class
  ON index_class.oid = index_state.indexrelid
WHERE index_class.relname = 'idx_case_opinion_chunks_diskann';

\echo
\echo '=== Data setup complete ==='
\echo 'Next: open 2-app-development.ipynb or run 3-diagnostics.ipynb.'
