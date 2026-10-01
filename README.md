# CopyLibraryToGithubEnvironment

Copies all key/value pairs from an Azure DevOps Library variable group into a GitHub repository environment as environment variables (or secrets, for values marked secret in the variable group).

## How it works

1. The tool connects to Azure DevOps using `DefaultAzureCredential` (via `Azure.Identity`) and reads a variable group (a "Library") from the specified organization/project using the `Microsoft.TeamFoundation.DistributedTask.WebApi` client.
2. For each variable in the group:
   - Its name is sanitized so it is a valid GitHub variable/secret name: any character that isn't a letter, digit, or underscore is replaced with `_`, and a leading digit gets a `_` prefix.
   - If the variable is marked **secret** in Azure DevOps, its value cannot be read back via the API, so it is created as a GitHub **secret** with a blank value (it must be filled in manually afterward).
   - If the variable is **not secret** but its value happens to be empty, it is also created as a GitHub **secret** with a blank value, because GitHub's variables API rejects empty values.
   - Otherwise, it is created/updated as a GitHub **variable** with its value.
3. Variables/secrets are set in the target GitHub repository/environment by shelling out to the [GitHub CLI](https://cli.github.com/) (`gh variable set` / `gh secret set`).
4. At the end, a summary is printed showing how many succeeded/failed, plus a warning listing any names that were set with a blank value and need manual follow-up.

The core logic lives in [`CopyLibraryToGithubEnvironment/Program.cs`](CopyLibraryToGithubEnvironment/Program.cs).

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`), logged in (`az login`) with access to the Azure DevOps organization/project
- [GitHub CLI](https://cli.github.com/) (`gh`), logged in (`gh auth login`) with access to the target GitHub repository

## Running it

### Option 1: `run.ps1` wrapper script (recommended)

`run.ps1` handles verifying prerequisites, logging in if needed, resolving inputs, and invoking the tool with `dotnet run`. It also writes a timestamped log to `run.log`.

1. Copy `inputs.json.template` to `inputs.json` and fill in your values (this file is gitignored):

   ```json
   {
	 "Library": "MyLibrary",
	 "Repo": "owner/repo",
	 "Environment": "Production"
   }
   ```

2. Provide the Azure DevOps organization URL and project. This can be done in any of these ways (checked in this order: parameter > environment variable > config file):
   - Pass `-OrgUrl` / `-Project` parameters to the script, or
   - Set `$env:AZDO_ORG_URL` / `$env:AZDO_PROJECT`, or
   - Copy `run.config.json.template` to `run.config.json` and fill in `OrgUrl`/`Project` (this file is gitignored).

3. Run the script:

   ```powershell
   .\run.ps1
   ```

   Or with explicit parameters:

   ```powershell
   .\run.ps1 -InputsPath .\inputs.json -OrgUrl https://dev.azure.com/my-org -Project MyProject
   ```

The script will verify `az`/`gh` are installed and logged in (prompting to log in if not), then run the tool and stream its output to both the console and `run.log`.

### Option 2: Run the tool directly

Set the required environment variables and invoke the executable/`dotnet run` with three positional arguments:

```powershell
$env:AZDO_ORG_URL = "https://dev.azure.com/my-org"
$env:AZDO_PROJECT = "MyProject"

dotnet run --project .\CopyLibraryToGithubEnvironment\CopyLibraryToGithubEnvironment.csproj -- <azure-library> <github-repo> <environment>
```

Arguments:

| Argument         | Description                                             |
|------------------|----------------------------------------------------------|
| `azure-library`  | Name of the Azure DevOps Library variable group.         |
| `github-repo`    | GitHub repository in `owner/repo` format.                |
| `environment`    | GitHub environment name to copy the variables/secrets into. |

Run with `-h` or `--help` to see this usage information from the tool itself.

## Notes

- Secret values in Azure DevOps cannot be retrieved via the API, so they are always copied over as blank GitHub secrets and must be populated manually afterward.
- Non-secret variables with an empty value are copied over as blank GitHub secrets too, since GitHub's variables API rejects empty values.
- Any value copied over blank is reported in a warning at the end of the run.
