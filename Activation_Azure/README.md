# The activation demo on Azure: start here

This folder holds everything needed to put the Data Platform Console on Azure as a password-protected, read-only web
app. You work entirely in the Azure web portal; nothing is installed on your computer.

What you end up with: an `https://...azurecontainerapps.io/` address that asks for a user name and password and then
shows the console. The data is synthetic. The build inside is commit 325f2152: 507,396 certified figures, each proven
against independent truths, as of 2026-09-30.

## What is in this folder

| File | What |
|---|---|
| `cg-activation-azure-325f2152.tar.gz.part-*` | The package, split into pieces under 50 MB (GitHub's file limit). Joined, it is one 240 MB tarball |
| `SHA256SUMS` | The checksum of the joined tarball |
| `README.md` | This page |

Inside the package: the demo's code and finished output (`tree/`), the container definition (`Dockerfile`, `serve.py`),
the Azure template (`main.bicep`), the script that runs the deployment (`deploy.sh`), the check (`smoke.sh`) and a
technical `README.md`.

## Before you start

- An Azure subscription where you can create resources. Your account needs the **Owner** role (or Contributor plus
  User Access Administrator) on the subscription or on the resource group you will use: the deployment gives the app
  permission to pull its own image, and only those roles can grant that.
- Decide three things:
  - a **resource group** name, for example `rg-cg-activation` (it is created if it does not exist);
  - a **registry** name: globally unique, letters and digits only, 5 to 50 characters, for example `cgactivation4821`;
  - the **password** visitors will type. The user name is `demo`.

## Steps

**1. Open Cloud Shell.** Sign in to <https://portal.azure.com>, click the `>_` icon in the top bar, and choose **Bash**.
If it asks about storage, "No storage account required" is enough. If you have more than one subscription, select the
one to use:

```bash
az account set --subscription "<subscription name or id>"
```

**2. Fetch the package and put it together.**

```bash
git clone --depth 1 https://github.com/jlassetco/amt.git
cd amt/Activation_Azure
cat cg-activation-azure-325f2152.tar.gz.part-* > cg-activation-azure-325f2152.tar.gz
sha256sum -c SHA256SUMS
```

The last line must print `cg-activation-azure-325f2152.tar.gz: OK`.

**3. Unpack it.**

```bash
tar -xzf cg-activation-azure-325f2152.tar.gz
cd cg-activation-azure-325f2152
```

**4. Deploy.** Put in your own password, resource group and registry name:

```bash
DEMO_PASSWORD='<the password>' ./deploy.sh --group rg-cg-activation --registry <registry name> --location eastus
```

This creates the resource group and the registry, uploads about 1 GB, builds the container image inside Azure, and
creates the app. Allow 10 to 15 minutes. It ends with a line like:

```
deployed: https://cg-activation.<something>.eastus.azurecontainerapps.io/  (user demo)
```

**5. Check it.** Still in Cloud Shell, with the address from step 4:

```bash
TRUTHS=tree/_tools/activation/out/sources/truths.json PYTHON=python3 ./smoke.sh https://<the address>/ demo:'<the password>'
```

It should report `507396 figures checked, 0 differences` and finish with `== done`.

**6. Open it.** Go to the address in a browser and sign in as `demo` with your password. That address and password
are what you give to other people.

## Finding and managing it in the portal

- The app: **Container Apps > cg-activation**. The address is on its Overview page, logs under Monitoring > Log stream.
- The password: **Settings > Secrets > demo-password**. Edit it, save, then restart the app (Revisions and replicas >
  select the revision > Restart).
- To stop paying for it when idle: Application > Scale, set the minimum replicas to 0. The first visit after a quiet
  period then waits a minute or so while it starts.
- To remove everything: **Resource groups >** your group **> Delete resource group**.

## What visitors can and cannot do

- Everything in the console is there to browse: the catalog, mappings, pipeline, quality monitor, incidents, the proof,
  the demo questions and the SQL page (single SELECT statements only).
- It is read-only. Run pipeline and the mapping assistant are switched off.
- No AI model is attached. The demo questions answer as usual; free-text questions get the built-in answers only.
- Triage notes (acknowledge, assign, comments) work but are forgotten whenever the app restarts.

## Cost

One small container (1 vCPU, 2 GiB) running all month, a Basic container registry and a log workspace. Setting the
minimum replicas to 0 removes most of the container's cost while nobody is using it.

## If something goes wrong

| What you see | What to do |
|---|---|
| `sha256sum` does not say OK | The download was incomplete. Delete the `amt` folder and repeat step 2 |
| "The registry name is already in use" | Pick another registry name and rerun step 4 |
| An authorization error mentioning `roleAssignments` | Your account cannot grant roles. Ask a subscription administrator to give you Owner on the resource group, then rerun step 4 (it picks up where it stopped) |
| "MissingSubscriptionRegistration" or a provider not registered | Run `az provider register -n Microsoft.App --wait`, `az provider register -n Microsoft.ContainerRegistry --wait` and `az provider register -n Microsoft.OperationalInsights --wait`, then rerun step 4 |
| Cloud Shell times out during the build | Reopen it, `cd amt/Activation_Azure/cg-activation-azure-325f2152` and rerun step 4. If the folder is gone, start again from step 2 |
| The browser keeps asking for the password | The user name is `demo` (unless you passed `--user`); check the password under Settings > Secrets |
| The page does not load right after deploying | Give it two minutes: the app copies its database when it starts |

## What has and has not been tested

Tested on a Mac on 2026-11-20: this exact package, unpacked and run with its own entry point; the password gate, the
read-only refusals and `smoke.sh` (0 differences on 507,396 figures).

Not yet tested: the Azure steps themselves. The image build, the template and `deploy.sh` have not been run against an
Azure subscription, so the first deployment is also their first test.
