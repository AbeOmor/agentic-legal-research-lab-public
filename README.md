# PGConf NYC 2026: Build an agentic legal research application with Azure HorizonDB

This lab builds a legal research agent over one Azure HorizonDB instance. PostgreSQL stores the
case corpus, BM25 index, AI Pipeline output, DiskANN index, Apache AGE citation graph, and optional
Mem0 memory.

## Choose your path

The complete lab is a **2-3 hour experience**. Notebook 1 takes about **45 minutes** when its
technical notes are read carefully.

### 60-minute conference fast path

| Time | Run live |
| --- | --- |
| 0-5 min | Open the environment, run Notebook 1 imports/configuration, and connect to HorizonDB |
| 5-10 min | Enable extensions and verify AIMM managed aliases |
| 10-18 min | Load/verify the case corpus |
| 18-27 min | Create and run the chunk-and-embed AI Pipeline |
| 27-34 min | Build the citation graph, BM25 index, and DiskANN index |
| 34-38 min | Run Notebook 2 dependency preflight, imports, and configuration |
| 38-51 min | Define the five agent tools; skip the per-tool smoke tests |
| 51-58 min | Run the flagship five-tool agent |
| 58-60 min | Review the architecture and next steps |

Notebook cells are labeled **🚀 CORE** or **🧭 Optional deep dive**. Optional sections include
incremental agent reassembly, repeated smoke tests, Mem0, Gradio, and forced failover.

## Architecture

```text
Dataset/cases.csv
       |
       v
public.cases -----------------> BM25 index (keyword search)
       |  \
       |   +------------------> Apache AGE case_graph
       |                         (citation expansion)
       |
       +--> AI Pipeline: ai.chunk -> ai.embed(default-embedding)
                    |
                    v
        public.case_opinion_chunks
        - doc_id -> public.cases.id
        - chunk_text
        - embedding vector(1536)
        - court_level, decision_date
                    |
                    v
        DiskANN (filtered semantic search)
```

`public.cases` is authoritative for case metadata, full opinions, BM25, graph traversal, and
`azure_ai.extract`. `public.case_opinion_chunks` is authoritative for vector indexing and semantic
retrieval. Tool 2 ranks chunks, keeps the best chunk per case, then returns unique case IDs for the
graph tool.

## What you build

- Five Microsoft Agent Framework tools:
  - BM25 keyword search with `pg_textsearch`
  - AI Pipeline-backed semantic search with `pgvector` and DiskANN
  - citation traversal with Apache AGE
  - managed in-database extraction with `azure_ai.extract`
  - external weather evidence from Open-Meteo
- AI Model Management aliases for database-side AI:
  - `default-embedding`
  - `default-chat`
  - `default-reranker`
- Optional Mem0 long-term memory in HorizonDB
- Optional Gradio UI and forced-failover exercise

## Repository structure

```text
.
├── .env.sample
├── .gitignore
├── LICENSE
├── README.md
├── requirements.txt
├── Code/
│   ├── 1-data-setup.ipynb
│   ├── 2-app-development.ipynb
│   ├── 3-diagnostics.ipynb
│   └── show_graph.sql
└── Dataset/
    └── cases.csv
```

## Prerequisites

- An Azure HorizonDB instance with these extensions allowed:
  `azure_ai`, `vector`, `pg_diskann`, `pg_textsearch`, and `age`
- **AI Model Management enabled** on the instance
- Visual Studio Code with:
  - Jupyter
  - [PostgreSQL](https://marketplace.visualstudio.com/items?itemName=ms-ossdata.vscode-pgsql)
- Python 3.11+

AI Model Management is a limited preview that requires approval. The conference environment uses
**Australia East**, the region validated for this lab. If you use your own subscription, confirm
feature and region availability before provisioning.

## Configure the environment

The hosted conference environment provides database and Azure credentials on the
**Resources / Environment** tab in the lab instructions pane.

1. Copy `.env.sample` to `.env` if the environment did not create it.
2. Populate the values from the environment tab.
3. Keep `.env` local; it is gitignored.

Notebook 1 uses only `AZURE_PG_*` values. Its embeddings and extraction checks run inside
HorizonDB through managed aliases.

Notebook 2 also uses `AZURE_OPENAI_*` values because Microsoft Agent Framework and Mem0 run in the
application process. Those variables are not used to register database models.

The HorizonDB administrator password is chosen when the cluster is created and cannot be retrieved
later from the Azure portal. In the hosted lab, use the value from the environment tab.

## Python setup and dependency repair

The lab image is expected to contain the dependencies, but Notebook 2 does not assume the image is
healthy. Run its standard-library-only **Part 3.0 dependency preflight** before third-party imports.

If it reports a missing package or the `mark_feature_used` incompatibility, run the exact command it
prints. From the repository root, the equivalent command is:

```bash
python -m pip install -r requirements.txt
```

Then **restart the notebook kernel** and rerun the preflight.

For a local virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate       # Windows PowerShell: .\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Select that interpreter as the notebook kernel in VS Code.

## Connect with the VS Code PostgreSQL extension

1. Select the PostgreSQL elephant icon.
2. Select **+ New Connection** and **Password Authentication**.
3. Enter the values from `.env`:
   - server: `AZURE_PG_HOST`
   - user: `AZURE_PG_USER`
   - password: `AZURE_PG_PASSWORD`
   - database: `AZURE_PG_NAME` (normally `postgres`)
   - port: `AZURE_PG_PORT` (normally `5432`)
4. Save the profile as `legal-research-lab` and connect.

After Notebook 1 creates the pipeline, right-click the database and select
**Pipelines & Workflows > AI Pipelines** to inspect definitions, execution graphs, run status, and
failures. Use **Visualize Schema** for the relational tables and run `Code/show_graph.sql` to open
the AGE result in the graph visualizer.

## Run the lab

### Notebook 1: data setup

[Code/1-data-setup.ipynb](Code/1-data-setup.ipynb) does the following:

1. Connects to HorizonDB and enables extensions.
2. Verifies the AIMM managed aliases and one-shot model calls.
3. Loads `Dataset/cases.csv` into `public.cases`.
4. Creates `public.case_opinion_chunks`.
5. Defines and runs `case_opinion_embedding_pipeline` with `ai.chunk()` and `ai.embed()`.
6. Verifies sink rows, embedding dimensions, and source linkage.
7. Builds the citation graph, BM25 index, and DiskANN index.

### Notebook 2: application development

[Code/2-app-development.ipynb](Code/2-app-development.ipynb) starts with a non-mutating dependency
preflight, then defines the five tools and the flagship agent. The semantic tool:

- creates the query vector with AIMM's `default-embedding`;
- filters pipeline chunks by source-derived court and date fields;
- retrieves candidate chunks with DiskANN;
- retains the best chunk for each unique case;
- joins to `public.cases`;
- preserves case IDs for the keyword + semantic union passed to the graph tool.

Mem0, Gradio, and forced failover remain as optional deep dives.

### Notebook 3: diagnostics

[Code/3-diagnostics.ipynb](Code/3-diagnostics.ipynb) checks:

- extension state and managed aliases;
- pipeline definitions, status, and optional durable run history;
- sink row, chunk, and embedding counts;
- missing and orphaned source/sink links;
- copied filter metadata parity;
- DiskANN index placement, validity, and readiness.

## Current preview references

- [AI Model Management in Azure HorizonDB](https://learn.microsoft.com/azure/horizondb/ai/ai-model-management)
- [AI Pipelines in Azure HorizonDB](https://learn.microsoft.com/azure/horizondb/ai/ai-pipelines)
- [Generate vector embeddings](https://learn.microsoft.com/azure/horizondb/ai/generate-vector-embeddings)
- [DiskANN vector indexing](https://learn.microsoft.com/azure/horizondb/ai/vector-index-diskann)
- [Microsoft Agent Framework](https://microsoft.github.io/agent-framework/)
- [Mem0](https://docs.mem0.ai/)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
