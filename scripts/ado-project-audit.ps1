
## Organization Variables
$pat = 'token'
$organization = '<orgName>'
$organizationUrl = "https://dev.azure.com/${organization}"

## Check PAT
if(-not ($env:AZURE_DEVOPS_PAT)){
    Write-Error "Please set the environment variable for AZURE_DEVOPS_PAT."
    exit 1
}

## Create header with PAT
$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($pat)"))
$header = @{authorization = "Basic $token"; 'content-type' = 'application/json'; charset='utf-8'; 'api-version' = '7.0'}

######
## Project Variables
$adoOrganizationSummary = @()
$projectQuery = Invoke-WebRequest "${organizationUrl}/_apis/projects?api-version=2.0" -Headers $header
$projects = $projectQuery.Content | convertfrom-json
$publicProjectCount = 0
$tfvsProjectCount = 0
$serviceConnectionCount = 0
$totalRepos = 0
$secretVariableCount = 0
$selfHostedAgents = 0
$totalSecretVariables = 0
$aadConfig = @{
    enabled = $false
} 


function Invoke-AdoProjectRestAPI {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [String]$operation,

        [Parameter(Mandatory = $False)]
        [String]$project,

        [Parameter(Mandatory = $False)]
        [String]$uri = 'https://dev.azure.com'

    )

        $request = Invoke-WebRequest -UseBasicParsing -Uri "$uri/${organization}/${project}/_apis/$operation" -Headers $header
        if ($request.StatusCode -ne 200){
            $response = "Error calling the operation ${operation} for the project ${project}. The error response is: $($request.StatusCode)"
        } else {
            $response = $request.Content | ConvertFrom-Json
        }
        
        return $response
    
}
##### 
## Organization level 

## Audit Streams`
$auditQuery = Invoke-WebRequest -UseBasicParsing -Uri "https://auditservice.dev.azure.com/$organization/_apis/audit/streams" `
    -Headers $header

$auditRequest = $auditQuery.content | ConvertFrom-Json

if ($auditRequest){
    $auditStreams =  $true;
} else {
    $auditStreams = $false
}

## Users
$request = Invoke-WebRequest -UseBasicParsing -Uri "https://vsaex.dev.azure.com/$organization/_apis/UserEntitlements" `
    -Headers $header
$users = $request.Content | ConvertFrom-Json
$userList = @()
$guestUsers = 0
## Check AAD Integration
if ($($users.members[0].user.origin) -eq 'aad'){
    $aadConfig = @{
        enabled = $true;
        tenantId = $($users.members[0].user.domain)
    } 
}

## Add in user counts by types
foreach ($user in $users.members){
    $domain = $user.user.principalName.split('@')
    
    $userProfile = @{
        name = $user.user.principalName;
        origin = $user.user.origin;
        emailDomain = $domain[0];
        userType = $user.user.metaType;
        subjectKind = $user.user.subjectKind;
        lastAccessedDate = $user.lastAccessedDate.Date;
        dateCreated = $user.dateCreated.Date;
    }
    if ($user.user.metaType -eq 'guest'){
        $guestUsers++
    }
    $userList += $userProfile
}


## Agent Pools
$request = Invoke-WebRequest -UseBasicParsing -Uri "https://dev.azure.com/$organization/_apis/distributedtask/pools" `
    -Headers $header
$pools = $request.Content | ConvertFrom-Json
foreach ($pool in $pools.value){
    if($pool.owner.displayName -ne "Microsoft.VisualStudio.Services.TFS"){
        $selfHostedAgents++
    }
}

######
## Loop through Projects and inspect each service
foreach ( $project in $projects.value ){

    ######
    ## Project Summary - Collect details
    $projectName = $project.name
    $projectSummary = [ordered]@{
        name = $projectName;
        lastUpdateTime = $project.lastUpdateTime.Date;
        visibility = $project.visibility
    }
    
    if ($project.visibility -eq "public") {
        $publicProjectCount++
    }

    ## Project Policies 
    $policies = Invoke-AdoProjectRestAPI -operation 'policy/configurations' -project $projectName

    if($policies.count -gt 0 ){
        $projectPolicyList = @()
        foreach ($policy in $policies.value ){
            $projectPolicies = @{
                enabled = $policy.isEnabled;
                blocking = $policy.isBlocking;
                name = ($policy.settings.displayName) ? $policy.settings.displayName : $policy.type.displayName
            }
            $projectPolicyList += $projectPolicies
        }
        $projectSummary += @{ projectPolicies = $projectPolicyList }
    }


    #####
    ## Review Service Connections
    $serviceConnections = Invoke-AdoProjectRestAPI -operation 'serviceendpoint/endpoints?includeDetails=true' -project $projectName
    if($serviceConnections.count -gt 0){
        $serviceConnectionCount = $serviceConnectionCount + $serviceConnections.count
        $serviceConnectionsOverview += @()
        foreach ($serviceConnection in $serviceConnections.value ){
            $serviceConnectionDetails = @{
                name = $serviceConnection.name;
                type = $serviceConnection.type;
                url = $serviceConnection.url;
                creator = $serviceConnection.createdBy.uniqueName;
            }
            if ($serviceConnection.type -eq 'azurerm'){
                $serviceConnectionDetails += @{
                    tenantId = $serviceConnection.authorization.parameters.tenantId;
                    schema = $serviceConnection.authorization.scheme;
                    scope = $serviceConnection.authorization.parameters.scope;
                    servicePrincipalid = $serviceConnection.authorization.parameters.servicePrincipalid;
                    subscriptionId = $serviceConnection.data.subscriptionId;
                }
            }
            $serviceConnectionsOverview += $serviceConnectionDetails
            $projectSummary += @{serviceConnectionsOverview = $serviceConnectionsOverview }
        }
        $serviceConnectionsTotal = $serviceConnectionsTotal + $serviceConnections.count
        $projectSummary += @{ serviceConnections = $serviceConnections.count }
    }

    #####
    ## Review TFVS Config
    $tfvsProjects = Invoke-AdoProjectRestAPI -operation 'tfvc/items' -project $projectName
    if($tfvsProjects.count -gt 0){
        $tfvsProjectCount++
        $projectSummary += @{ tfvsEnabled = $True }
    }

    ######
    ## Review the Wiki configuration
    $wikis = Invoke-AdoProjectRestAPI -operation 'wiki/wikis' -project $projectName
    $projectWikiCount = 0
    $codeWikiCount = 0
    foreach ($wiki in $wikis.value ){
        if($wiki.type -eq "projectWiki" ){
            $projectWikiCount++
        } elseif ($wiki.type -eq "codeWiki") {
            $codeWikiCount++
        }
    }
    $totalProjectWikis = $totalProjectWikis + $projectWikiCount
    $totalCodeWikis = $totalCodeWikis + $codeWikiCount
    $projectSummary += @{ projectWikis = $projectWikiCount; codeWikis= $codeWikiCount}

    ######
    ## Pipeline Configuration
    $pipelines = Invoke-AdoProjectRestAPI -operation 'pipelines' -project $projectName
    $totalPipelines = $totalPipelines + $pipelines.count
    $projectSummary += @{ pipelines = $pipelines.count }

    ######
    ## Release Configuration
    $releases = Invoke-AdoProjectRestAPI -operation 'release/releases' -project $projectName -Uri 'https://vsrm.dev.azure.com'
    $totalReleases = $totalReleases + $releases.count
    $projectSummary += @{ releases = $releases.count }

    #######
    ## Repository Configuration
    $repositories = Invoke-AdoProjectRestAPI -operation 'git/Repositories' -project $projectName
    $totalRepos = $totalRepos + $repositories.value.count
    $projectSummary += @{ repositories = $repositories.count }

    #######
    ## Variable Groups
    $variableGroups = Invoke-AdoProjectRestAPI -operation 'distributedtask/variablegroups' -project $projectName
    $totalVariableGroups = $totalVariableGroups + $variableGroups.count
    $secretVariables = 0
    foreach ($variableGroup in $variableGroups.value){
        if ($variableGroup.variables.type -eq "AzureKeyVault"){
            $secretVariables++
        }   
    }
    $totalSecretVariables = $totalSecretVariables + $secretVariables
    $projectSummary += @{ variableGroups = $variableGroups.count; secretVariables = $secretVariables }
    
    ######
    ## Project process details

    $queryProjectProcess = Invoke-WebRequest "${organizationUrl}/_apis/projects/$($project.id)/properties" -Headers $header
    $processes = $queryProjectProcess.content | convertFrom-Json
    $projectProcessId = $processes.value[2].value
    
    $queryOrgProcessTypes = Invoke-WebRequest "${organizationUrl}/_apis/work/processes" -Headers $header 
    $allProcesses = $queryOrgProcessTypes.content | convertFrom-Json
    
    $counter = 0 
    $allProcessesId = $allProcesses.value[$counter].typeId

    $processType = ''

    while ($projectProcessId -ne $allProcessesId)
    {
        $counter = $counter + 1
        $allProcessesId = $allProcesses.value[$counter].typeId
    }
        $processType = $allProcesses.value[$counter].name
    
    $projectSummary += @{ processType = $processType;}

    #######
    ## Append to ADO Summary
    $adoOrganizationSummary += $projectSummary
}

#######
## Extension Counter 
$extensionQuery = Invoke-WebRequest "https://extmgmt.dev.azure.com/${organization}/_apis/extensionmanagement/installedextensions?api-version=6.0-preview.1" -Headers $header
$extensions = $extensionQuery.Content | ConvertFrom-Json


#############
## Results ##
$overview = @{
    name = $organization;
    totalProjects = $projects.count;
    publicProjects = $publicProjectCount;
    totalRepositories = $totalRepos;
    totalProjectWikis = $totalProjectWikis;
    totalCodeWikis = $totalCodeWikis;
    totalPipelines = $totalPipelines;
    totalReleases = $totalReleases;
    tfvsProjects = $tfvsProjectCount;
    auditStreams = $auditStreams;
    serviceConnections = $serviceConnectionCount;
    guestUsers = $guestUsers;
    aadConfig = $aadConfig;
    variableGroups = $totalVariableGroups;
    secretVariables = $secretVariableCount;
    selfHostedAgents = $selfHostedAgents;
    $totalExtensions = $extensions.count
}

$results = @{
    overview = $overview;
    projectSummary = $adoOrganizationSummary;
    userList = $userList;
}

Write-Host "Results:"
Write-Host $($results | ConvertTo-Json -depth 10)
