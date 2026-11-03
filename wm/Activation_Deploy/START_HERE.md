# Activation demo: EC2 deployment package

`cg-activation-2fb2da1.tar.gz` is the deployable package of the source-to-semantic activation demo for the wealth
manager reference model: the activation tooling and the taxonomy, data product and semantic model content it reads,
with no generated output and no credentials. It is self-sufficient: unpacked anywhere, `_tools/activation/compile/build_all.py`
runs the whole chain (sources, mappings, conformed tables, derivations, proof, semantic layer, tests, states).

To deploy, follow `README.md` in this folder from step 1 (the Claude API key in SSM Parameter Store) and step 3 (the
CloudFormation stack), after uploading the tarball to a bucket you own:

```bash
aws s3 cp cg-activation-2fb2da1.tar.gz s3://my-bucket/cg-activation/
```

Step 2 (`make_package.sh`) rebuilds the tarball from the source repository and is not needed here. The app runs without
a Claude key: the build, the certified queries and the verified demo questions are unaffected; free-text questions and
the mapping assistant fall back to their deterministic paths and say so.
