# Activation demo: Databricks package

Loads the source-to-semantic activation demo into a Databricks workspace from the UI alone (no CLI). The data is
synthetic. Everything deployed is generated from the confirmed source mappings.

| File | What it is |
|---|---|
| `cg_activation_databricks_9f2082f4_uncommitted.zip` | The package: a `Setup` notebook, the pipeline SQL, Unity Catalog and semantic layer statements, a Genie space, a dashboard |
| `cg_activation_extracts.zip` | The synthetic source extracts: 103 CSV files, 76 MB unpacked |

## Load it

1. Workspace > your folder > Import > the package zip. It unpacks to a folder `cg_activation_databricks`.
2. Open `Setup` in that folder, attach serverless compute, Run all. The first run creates the catalog `distribution`
   (or the one named in the Catalog option), its schemas and a volume, then stops and asks for the extracts.
3. Catalog > the catalog > `landing` > `extracts` > Upload to this volume > `cg_activation_extracts.zip`. Run all again.

The second run unpacks the extracts, creates and runs two pipelines (bronze, silver and gold; then quality), sets tags,
creates the semantic and metric views, a Genie space and a dashboard, and ends by comparing the load with the local
build: row counts of 255 datasets, the quality scorecard and 19 verified answers.

`README.md` inside the package describes the notebook's options (another catalog, enforced column masks, relaxing
expectations, skipping tags) and what differs from a production deployment.

## Status

Built 2026-11-16. Not yet run on a Databricks workspace: the SQL was checked by local Spark for names and columns, and the
notebook was dry-run against stand-ins. Expect some first-run fixes; if a step fails, the notebook prints the statement
and the error, and every step can be run again.
