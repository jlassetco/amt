# The activation demo on Azure: start here

This folder holds everything needed to put the Data Platform Console on Azure as a password-protected, read-only web
app. You work entirely in the Azure web portal, uploading the package from your computer; nothing is installed on it.

What you end up with: an `https://...azurecontainerapps.io/` address that asks for a user name and password and then
shows the console. The data is synthetic. The build inside is commit 325f2152: 507,396 certified figures, each proven
against independent truths, as of 2026-09-30.

## What is in this folder

| File | What |
|---|---|
| `cg-activation-azure-325f2152.tar.gz.part-*` | The package, split into pieces under 50 MB (GitHub's file limit). Joined, it is one 240 MB tarball |
| `SHA256SUMS` | The checksum of the joined tarball |
| `signin/serve.py` | The entry point with a sign-in page, applied in step 4c |
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

**2. Upload the package from your computer and put it together.** You need this folder on your computer first (the
six `.part-` files and `SHA256SUMS`). In the Cloud Shell toolbar click **Manage files > Upload**, and select the six
`cg-activation-azure-325f2152.tar.gz.part-*` files and `SHA256SUMS`. If it takes only one file at a time, repeat until
all seven are up. Wait for each upload to report that it finished; they land in your Cloud Shell home folder. Then:

```bash
cd ~
ls -l cg-activation-azure-325f2152.tar.gz.part-* SHA256SUMS
cat cg-activation-azure-325f2152.tar.gz.part-* > cg-activation-azure-325f2152.tar.gz
sha256sum -c SHA256SUMS
```

`ls` must list six parts (`part-aa` to `part-af`: five of 47,185,920 bytes and one of 14,871,544) and `SHA256SUMS`.
The last line must print `cg-activation-azure-325f2152.tar.gz: OK`.

If Cloud Shell can reach GitHub, this does the same without uploading: `git clone --depth 1
https://github.com/jlassetco/amt.git && cd amt/Activation_Azure`, then the `cat` and `sha256sum` lines above.

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

**4b. Only if step 4 ended with an authorization error about `roleAssignments`.** The image is already built at that
point; only the last part failed, because your account may not assign roles. Finish with the commands below, which use
the registry's own login instead. Run them in the same Cloud Shell, one block at a time.

Set the names. `RG` and `ACR` are the resource group and registry you gave in step 4; `NAME` is what the app will be
called and becomes the first part of its address:

```bash
RG=<resource group>; ACR=<registry name>; NAME=data-console
```

Turn on the registry login and create the environment (a few minutes). If it asks to install the `containerapp`
extension, answer yes:

```bash
az acr update -n $ACR --admin-enabled true
az containerapp env create -g $RG -n $NAME-env --location $(az group show -n $RG --query location -o tsv)
```

Create the app. Put your password in the `--secrets` line:

```bash
az containerapp create -g $RG -n $NAME --environment $NAME-env \
  --image $ACR.azurecr.io/cg-activation:325f2152 \
  --registry-server $ACR.azurecr.io --registry-username $ACR \
  --registry-password "$(az acr credential show -n $ACR --query 'passwords[0].value' -o tsv)" \
  --secrets demo-password='<the password>' \
  --env-vars DEMO_USER=demo DEMO_PASSWORD=secretref:demo-password ACTIVATION_LLM=none PORT=8765 \
  --ingress external --target-port 8765 \
  --cpu 1.0 --memory 2.0Gi --min-replicas 1 --max-replicas 1 \
  --query properties.configuration.ingress.fqdn -o tsv
```

The last command prints the address, like `data-console.<something>.eastus.azurecontainerapps.io`. Put `https://` in
front of it. In the portal the app is then under Container Apps > `data-console` rather than `cg-activation`.

**4c. Switch to the sign-in page.** The package's tarball asks for the password with the browser's own pop-up, which
some managed work browsers never show: the page then says only "sign in to continue". This step replaces the pop-up
with an ordinary sign-in page. It adds one small file on top of the image you already built; nothing large is uploaded
again. Do it after step 4 or 4b.

Set the names again if this is a new Cloud Shell session (`NAME` is `cg-activation` after step 4, or what you chose in 4b):

```bash
RG=<resource group>; ACR=<registry name>; NAME=data-console
```

Get the new entry point into a folder of its own:

```bash
mkdir -p ~/signin && cd ~/signin
curl -fsSL -o serve.py https://raw.githubusercontent.com/jlassetco/amt/main/Activation_Azure/signin/serve.py
ls -l serve.py
```

If Cloud Shell cannot reach GitHub, download `signin/serve.py` from this folder to your computer, upload it with
**Manage files > Upload**, and run `mkdir -p ~/signin && mv ~/serve.py ~/signin/ && cd ~/signin` instead.

Build the small image and switch the app to it (about two minutes):

```bash
printf 'ARG BASE\nFROM ${BASE}\nCOPY serve.py /app/serve.py\n' > Dockerfile
az acr build -r $ACR -t data-console:signin-2 --build-arg BASE=$ACR.azurecr.io/cg-activation:325f2152 .
az containerapp update -g $RG -n $NAME --image $ACR.azurecr.io/data-console:signin-2 --query properties.latestRevisionName -o tsv
```

Wait a minute, then reload the app's address: it now shows a sign-in page. The user name and password are unchanged.
A sign-in ends when the browser is closed (all its windows, not just the tab), and after 12 hours at the latest. `smoke.sh` and `curl -u` work as before.

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
| `sha256sum` does not say OK, or `ls` shows a part missing or with a different size | An upload was incomplete. Upload that part again (compare sizes with the list in step 2), then repeat the `cat` and `sha256sum` lines |
| The browser renamed a file while downloading (for example added `.txt` or ` (1)`) | Rename it back in Cloud Shell with `mv 'wrong name' right-name` before the `cat` line |
| "The registry name is already in use" | Pick another registry name and rerun step 4 |
| An authorization error mentioning `roleAssignments` | Your account cannot grant roles. Follow step 4b, which needs no role assignment |
| "MissingSubscriptionRegistration" or a provider not registered | Run `az provider register -n Microsoft.App --wait`, `az provider register -n Microsoft.ContainerRegistry --wait` and `az provider register -n Microsoft.OperationalInsights --wait`, then rerun step 4 |
| Cloud Shell times out during the build | Reopen it, `cd ~/cg-activation-azure-325f2152` and rerun step 4. If the folder is gone, start again from step 2 |
| The page says only "sign in to continue" and never asks for a password | The browser blocks password pop-ups. Do step 4c |
| The browser keeps asking for the password | The user name is `demo` (unless you passed `--user`); check the password under Settings > Secrets |
| The page does not load right after deploying | Give it two minutes: the app copies its database when it starts |

## What has and has not been tested

Tested on a Mac on 2026-11-20: this exact package, unpacked and run with its own entry point; the password gate, the
read-only refusals and `smoke.sh` (0 differences on 507,396 figures).

Not yet tested: the Azure steps themselves. The image build, the template and `deploy.sh` have not been run against an
Azure subscription, so the first deployment is also their first test.
