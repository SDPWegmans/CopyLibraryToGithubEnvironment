using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Microsoft.TeamFoundation.DistributedTask.WebApi;
using Microsoft.VisualStudio.Services.Common;
using Microsoft.VisualStudio.Services.WebApi;
return await Run(args);

static async Task<int> Run(string[] args)
{
    if (args.Length != 3 || args.Any(a => a is "-h" or "--help"))
    {
        PrintUsage();
        return args.Length == 3 ? 1 : 0;
    }

    var libraryName = args[0];
    var repository = args[1];
    var environment = args[2];

    var orgUrl = System.Environment.GetEnvironmentVariable("AZDO_ORG_URL");
    var project = System.Environment.GetEnvironmentVariable("AZDO_PROJECT");

    if (string.IsNullOrWhiteSpace(orgUrl) || string.IsNullOrWhiteSpace(project))
    {
        Console.Error.WriteLine("Error: environment variables AZDO_ORG_URL and AZDO_PROJECT must be set.");
        return 1;
    }

    Console.WriteLine($"Reading variable group '{libraryName}' from {orgUrl} (project: {project})...");

    IDictionary<string, VariableValue>? variables;
    try
    {
        variables = await GetVariableGroupValues(orgUrl, project, libraryName);
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Error reading Azure DevOps variable group: {ex.Message}");
        return 1;
    }

    if (variables is null)
    {
        Console.Error.WriteLine($"Error: variable group '{libraryName}' was not found in project '{project}'.");
        return 1;
    }

    Console.WriteLine($"Found {variables.Count} variable(s). Applying to repository '{repository}' environment '{environment}'...");

    var successCount = 0;
    var failureCount = 0;
    var emptyValueNames = new List<string>();

    foreach (var (rawName, variable) in variables)
    {
        var name = SanitizeName(rawName);
        var isSecret = variable.IsSecret;
        var value = isSecret ? string.Empty : (variable.Value ?? string.Empty);

        if (string.IsNullOrEmpty(value))
        {
            emptyValueNames.Add(name);

            if (isSecret)
            {
                Console.WriteLine($"  '{rawName}' -> secret '{name}': value cannot be read via API, setting blank value.");
            }
            else
            {
                // GitHub's variables API rejects an empty value (HTTP 422). Fall back to creating it
                // as a secret with a blank value so the copy doesn't fail; it will need to be
                // populated manually.
                Console.WriteLine($"  '{rawName}' -> variable '{name}': value is empty, creating as a secret with a blank value instead.");
                isSecret = true;
            }
        }

        var ok = isSecret
            ? SetGitHubSecret(repository, environment, name, value)
            : SetGitHubVariable(repository, environment, name, value);

        if (ok)
        {
            successCount++;
            Console.WriteLine($"  [ok] {(isSecret ? "secret" : "variable")} '{name}' set.");
        }
        else
        {
            failureCount++;
            Console.Error.WriteLine($"  [fail] could not set {(isSecret ? "secret" : "variable")} '{name}'.");
        }
    }

    Console.WriteLine($"Done. Succeeded: {successCount}, Failed: {failureCount}.");

    if (emptyValueNames.Count > 0)
    {
        Console.WriteLine();
        Console.WriteLine($"WARNING: {emptyValueNames.Count} value(s) were set blank and need to be populated manually:");
        foreach (var name in emptyValueNames)
        {
            Console.WriteLine($"  - {name}");
        }
    }

    return failureCount == 0 ? 0 : 1;
}

static void PrintUsage()
{
    Console.WriteLine("""
        CopyLibraryToGithubEnvironment

        Copies all key/value pairs from an Azure DevOps Library variable group into a
        GitHub repository environment as environment variables (or secrets, for values
        marked secret in the variable group).

        Usage:
          CopyLibraryToGithubEnvironment <azure-library> <github-repo> <environment>

        Arguments:
          azure-library   Name of the Azure DevOps Library variable group.
          github-repo     GitHub repository in "owner/repo" format.
          environment     GitHub environment name to copy the variables/secrets into.

        Required environment variables:
          AZDO_ORG_URL    Azure DevOps organization URL, e.g. https://dev.azure.com/my-org
          AZDO_PROJECT    Azure DevOps project name.

        Prerequisites:
          - Signed in via 'az login' (uses DefaultAzureCredential to reach Azure DevOps).
          - GitHub CLI ('gh') installed and authenticated ('gh auth login') with access
            to the target repository.

        Notes:
          - Variable/secret names are sanitized: any character that is not a letter,
            digit, or underscore is replaced with '_'. Names starting with a digit are
            prefixed with '_'.
          - Values for secret variables cannot be retrieved from the Azure DevOps API;
            they will be created as GitHub secrets with a blank value.
          - Non-secret variables with an empty value are created as GitHub secrets with
            a blank value instead, since GitHub's variables API rejects empty values.
          - Any value copied over blank is reported in a warning at the end of the run
            and must be populated manually.
        """);
}

static async Task<IDictionary<string, VariableValue>?> GetVariableGroupValues(string orgUrl, string project, string libraryName)
{
    var credential = new DefaultAzureCredential();
    var tokenRequestContext = new TokenRequestContext(["499b84ac-1321-427f-aa17-267ca6975798/.default"]);
    var token = await credential.GetTokenAsync(tokenRequestContext);

    var vssCredentials = new Microsoft.VisualStudio.Services.OAuth.VssOAuthAccessTokenCredential(token.Token);
    using var connection = new VssConnection(new Uri(orgUrl), vssCredentials);
    using var client = await connection.GetClientAsync<TaskAgentHttpClient>();

    var groups = await client.GetVariableGroupsAsync(project, groupName: libraryName);
    var group = groups.FirstOrDefault(g => string.Equals(g.Name, libraryName, StringComparison.OrdinalIgnoreCase));

    return group?.Variables;
}

static string SanitizeName(string name)
{
    var sanitized = Regex.Replace(name, "[^A-Za-z0-9_]", "_");
    if (sanitized.Length == 0 || char.IsDigit(sanitized[0]))
    {
        sanitized = "_" + sanitized;
    }

    return sanitized;
}

static bool SetGitHubVariable(string repository, string environment, string name, string value)
    => RunGhCommand(["variable", "set", name, "--env", environment, "--repo", repository], value);

static bool SetGitHubSecret(string repository, string environment, string name, string value)
    => RunGhCommand(["secret", "set", name, "--env", environment, "--repo", repository], value);

static bool RunGhCommand(string[] arguments, string stdInput)
{
    var startInfo = new ProcessStartInfo
    {
        FileName = "gh",
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8,
    };

    foreach (var arg in arguments)
    {
        startInfo.ArgumentList.Add(arg);
    }

    using var process = Process.Start(startInfo);
    if (process is null)
    {
        Console.Error.WriteLine("Error: failed to start 'gh' process. Is the GitHub CLI installed?");
        return false;
    }

    // Passing the value via "--body -" and writing it to stdin (instead of passing it directly as a
    // CLI argument) avoids gh hanging when the value is empty, and avoids issues with special
    // characters/newlines in argument values.
    process.StandardInput.Write(stdInput);
    process.StandardInput.Close();

    var stdErr = process.StandardError.ReadToEnd();
    process.WaitForExit();

    if (process.ExitCode != 0)
    {
        Console.Error.WriteLine(stdErr.Trim());
        return false;
    }

    return true;
}
