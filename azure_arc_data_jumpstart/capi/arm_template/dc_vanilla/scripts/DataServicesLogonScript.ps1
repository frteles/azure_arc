Start-Transcript -Path C:\Temp\DataServicesLogonScript.log

Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

$azurePassword = ConvertTo-SecureString $env:spnClientSecret -AsPlainText -Force
$psCred = New-Object System.Management.Automation.PSCredential($env:spnClientID , $azurePassword)
Connect-AzAccount -Credential $psCred -TenantId $env:spnTenantId -ServicePrincipal

az login --service-principal --username $env:spnClientID --password $env:spnClientSecret --tenant $env:spnTenantId

Write-Host "Installing Azure Data Studio Extensions"
Write-Host "`n"

$env:argument1="--install-extension"
$env:argument2="Microsoft.arc"
$env:argument3="microsoft.azuredatastudio-postgresql"

& "C:\Program Files\Azure Data Studio\bin\azuredatastudio.cmd" $env:argument1 $env:argument2
& "C:\Program Files\Azure Data Studio\bin\azuredatastudio.cmd" $env:argument1 $env:argument3

Write-Host "Creating Azure Data Studio Desktop shortcut"
Write-Host "`n"
$TargetFile = "C:\Program Files\Azure Data Studio\azuredatastudio.exe"
$ShortcutFile = "C:\Users\$env:adminUsername\Desktop\Azure Data Studio.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetFile
$Shortcut.Save()

# Adding Azure Arc CLI extensions
Write-Host "Adding Azure Arc CLI extensions"
az extension add --name "connectedk8s" -y
az extension add --name "k8s-configuration" -y
az extension add --name "k8s-extension" -y
az extension add --name "customlocation" -y

Write-Host "`n"
az -v

# Downloading CAPI Kubernetes cluster kubeconfig file
Write-Host "Downloading CAPI Kubernetes cluster kubeconfig file"
$sourceFile = "https://$env:stagingStorageAccountName.blob.core.windows.net/staging-capi/config.arc-data-capi-k8s"
$context = (Get-AzStorageAccount -ResourceGroupName $env:resourceGroup).Context
$sas = New-AzStorageAccountSASToken -Context $context -Service Blob -ResourceType Object -Permission racwdlup
$sourceFile = $sourceFile + $sas
azcopy cp --check-md5 FailIfDifferentOrMissing $sourceFile  "C:\Users\$env:USERNAME\.kube\config"
kubectl config rename-context "arc-data-capi-k8s-admin@arc-data-capi-k8s" "arc-data-capi-k8s"

# Creating Storage Class with azure-managed-disk for the CAPI cluster
Write-Host "`n"
Write-Host "Creating Storage Class with azure-managed-disk for the CAPI cluster"
kubectl apply -f "C:\Temp\capiStorageClass.yaml"

kubectl label node --all failure-domain.beta.kubernetes.io/zone-
kubectl label node --all topology.kubernetes.io/zone-
kubectl label node --all failure-domain.beta.kubernetes.io/zone= --overwrite
kubectl label node --all topology.kubernetes.io/zone= --overwrite

Write-Host "Checking kubernetes nodes"
Write-Host "`n"
kubectl get nodes
azdata --version

# Onboarding the CAPI cluster as an Azure Arc enabled Kubernetes cluster
Write-Host "Onboarding the cluster as an Azure Arc enabled Kubernetes cluster"
Write-Host "`n"
az connectedk8s connect --name "Arc-Data-CAPI-K8s" --resource-group $env:resourceGroup --location $env:azureLocation --tags 'Project=jumpstart_azure_arc_data' --custom-locations-oid '51dfe1e8-70c6-4de5-a08e-e18aff23d815'
Start-Sleep -Seconds 10

az k8s-extension create --name arc-data-services --extension-type microsoft.arcdataservices --cluster-type connectedClusters --cluster-name 'Arc-Data-CAPI-K8s' --resource-group $env:resourceGroup --auto-upgrade false --scope cluster --release-namespace arc-data --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper

Do {
    Write-Host "Waiting for bootstrapper pod"
    Start-Sleep -Seconds 20
    $podStatus = $(if(kubectl get pods -n arc-data | Select-String "bootstrapper" | Select-String "Running" -Quiet){"Ready!"}Else{"Nope"})
    } while ($podStatus -eq "Nope")

$connectedClusterId = az connectedk8s show --name 'Arc-Data-CAPI-K8s' --resource-group $env:resourceGroup --query id -o tsv
$extensionId = az k8s-extension show --name arc-data-services --cluster-type connectedClusters --cluster-name 'Arc-Data-CAPI-K8s' --resource-group $env:resourceGroup --query id -o tsv
Start-Sleep -Seconds 20
az customlocation create --name 'jumpstart-cl' --resource-group $env:resourceGroup --namespace arc --host-resource-id $connectedClusterId --cluster-extension-ids $extensionId

Workflow ExtensionsDeploy
{
    Parallel {
        InlineScript {
            # Deploying Azure Monitor for containers Kubernetes extension instance
            Write-Host "Create Azure Monitor for containers Kubernetes extension instance"
            Write-Host "`n"
            az k8s-extension create --name "azuremonitor-containers" --cluster-name "Arc-Data-CAPI-K8s" --resource-group $env:resourceGroup --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers
        }
        InlineScript {
            # Deploying Azure Defender Kubernetes extension instance
            Write-Host "Create Azure Defender Kubernetes extension instance"
            Write-Host "`n"
            az k8s-extension create --name "azure-defender" --cluster-name "Arc-Data-CAPI-K8s" --resource-group $env:resourceGroup --cluster-type connectedClusters --extension-type Microsoft.AzureDefender.Kubernetes
        }
    }
}

$customLocationId = $(az customlocation show --name "jumpstart-cl" --resource-group $env:resourceGroup --query id -o tsv)
$workspaceId = $(az resource show --resource-group $env:resourceGroup --name $env:workspaceName --resource-type "Microsoft.OperationalInsights/workspaces" --query properties.customerId -o tsv)
$workspaceKey = $(az monitor log-analytics workspace get-shared-keys --resource-group $env:resourceGroup --workspace-name $env:workspaceName --query primarySharedKey -o tsv)

$dataControllerParams = "C:\Temp\dataController.parameters.json"

(Get-Content -Path $dataControllerParams) -replace 'resourceGroup-stage',$env:resourceGroup | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'azdataUsername-stage',$env:AZDATA_USERNAME | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'azdataPassword-stage',$env:AZDATA_PASSWORD | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'customLocation-stage',$customLocationId | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'subscriptionId-stage',$env:subscriptionId | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'spnClientId-stage',$env:spnClientID | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'spnTenantId-stage',$env:spnTenantId | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'spnClientSecret-stage',$env:spnClientSecret | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'logAnalyticsWorkspaceId-stage',$workspaceId | Set-Content -Path $dataControllerParams
(Get-Content -Path $dataControllerParams) -replace 'logAnalyticsPrimaryKey-stage',$workspaceKey | Set-Content -Path $dataControllerParams


# Deploying Azure Arc Data Controller
# Write-Host "Deploying Azure Arc Data Controller"
# Write-Host "`n"
# $kubectlMonShell = Start-Process -PassThru PowerShell {for (0 -lt 1) {kubectl get pod -n $env:arcDcName; Start-Sleep -Seconds 5; Clear-Host }}
# azdata arc dc config init --source azure-arc-kubeadm --path ./custom
# azdata arc dc config replace --path ./custom/control.json --json-values '$.spec.storage.data.className=managed-premium'
# azdata arc dc config replace --path ./custom/control.json --json-values '$.spec.storage.logs.className=managed-premium'
# azdata arc dc config replace --path ./custom/control.json --json-values "$.spec.services[*].serviceType=LoadBalancer"
# azdata arc dc create --namespace $env:arcDcName --name $env:arcDcName --subscription $env:subscriptionId --resource-group $env:resourceGroup --location $env:azureLocation --connectivity-mode indirect --path ./custom

# #Creating Azure Data Studio settings for database connections
# Write-Host "`n"
# Write-Host "Creating Azure Data Studio settings for database connections"
# New-Item -Path "C:\Users\$env:adminUsername\AppData\Roaming\azuredatastudio\" -Name "User" -ItemType "directory" -Force
# Copy-Item -Path "C:\Temp\settingsTemplate.json" -Destination "C:\Users\$env:adminUsername\AppData\Roaming\azuredatastudio\User\settings.json"
# $settingsFile = "C:\Users\$env:adminUsername\AppData\Roaming\azuredatastudio\User\settings.json"
# azdata arc sql mi list | Tee-Object "C:\Temp\sql_instance_list.txt"
# azdata arc postgres endpoint list --name $env:POSTGRES_NAME | Tee-Object "C:\Temp\postgres_instance_endpoint.txt"
# $sqlfile = "C:\Temp\sql_instance_list.txt"
# $postgresfile = "C:\Temp\postgres_instance_endpoint.txt"

# (Get-Content $sqlfile | Select-Object -Skip 2) | Set-Content $sqlfile
# $sqlstring = Get-Content $sqlfile
# $sqlstring.Substring(0, $sqlstring.IndexOf(',')) | Set-Content $sqlfile
# $sqlstring = Get-Content $sqlfile
# $sqlstring.Split(' ')[$($sqlstring.Split(' ').Count-1)] | Set-Content $sqlfile
# $sql = Get-Content $sqlfile

# (Get-Content $postgresfile | Select-Object -Index 8) | Set-Content $postgresfile
# $pgstring = Get-Content $postgresfile
# $pgstring.Substring($pgstring.IndexOf('@')+1, $pgstring.LastIndexOf(':')-$pgstring.IndexOf('@')-1) | Set-Content $postgresfile
# $pg = Get-Content $postgresfile

# (Get-Content -Path $settingsFile) -replace 'arc_sql_mi',$sql | Set-Content -Path $settingsFile
# (Get-Content -Path $settingsFile) -replace 'sa_username',$env:AZDATA_USERNAME | Set-Content -Path $settingsFile
# (Get-Content -Path $settingsFile) -replace 'sa_password',$env:AZDATA_PASSWORD | Set-Content -Path $settingsFile
# (Get-Content -Path $settingsFile) -replace 'false','true' | Set-Content -Path $settingsFile
# (Get-Content -Path $settingsFile) -replace 'arc_postgres',$pg | Set-Content -Path $settingsFile
# (Get-Content -Path $settingsFile) -replace 'ps_password',$env:AZDATA_PASSWORD | Set-Content -Path $settingsFile

# Cleaning garbage
# Remove-Item "C:\Temp\sql_instance_list.txt" -Force
# Remove-Item "C:\Temp\postgres_instance_endpoint.txt" -Force

# # Changing to Client VM wallpaper
# $imgPath="C:\Temp\wallpaper.png"
# $code = @' 
# using System.Runtime.InteropServices; 
# namespace Win32{ 
    
#      public class Wallpaper{ 
#         [DllImport("user32.dll", CharSet=CharSet.Auto)] 
#          static extern int SystemParametersInfo (int uAction , int uParam , string lpvParam , int fuWinIni) ; 
         
#          public static void SetWallpaper(string thePath){ 
#             SystemParametersInfo(20,0,thePath,3); 
#          }
#     }
#  } 
# '@

# add-type $code 
# [Win32.Wallpaper]::SetWallpaper($imgPath)

# Kill the open PowerShell monitoring kubectl get pods
Stop-Process -Id $kubectlMonShell.Id

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Unregister-ScheduledTask -TaskName "DataServicesLogonScript" -Confirm:$false
Start-Sleep -Seconds 5