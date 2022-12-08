#### Helper Script for Patching App Services – Quick Start Template Based Deployment

# NSG Requirements:
# •	Required on aps-ad-Nsg, aps-fs-Nsg, and aps-sql-Nsg
# •	Inbound Rule
## o	Priority: 800
## o	Name: PSRemoting
## o	Port: 5985,5986
## o	Protocol: TCP
## o	Source: Any (or best practice your vnet)
## o	Destination: Any (or your Public IP Addresses)
## o	Action: Allow
# Public IP Requirement:
# •	All 6 VM’s will need public IP Addresses
# •	All Public IP’s will need a DNS name label (Configuration blade of the Public IP) – Must be the machine name
## o	Example: aps-sql-0.local.cloudapp.azurestack.external
# Update Requirements
# •	Downloaded from https://www.catalog.update.microsoft.com 
# •	.msu must be extracted as a cab file
## o	Dism cannot install from a msu
## o	Wusa.exe does not work remotely
## o	Can be done with cmd
### 	Expand -F:* c:\temp\thismonthspatch.msu c:\temp
## •	Add to a storage account and generate a SAS URI for the file (not the container)
# Script Variables
# •	*Ideally I will add parameters in a later version, but wanted to get this working as is first
# •	Configure Azure Environment
## o	Line 31: Change ArmEndpoint from ASDK endpoint
## o	Line 32: Change Azure Key Vault DNS Suffix from ASDK 
## o	Line 33: Change Service Endpoint from ASDK
# •	AAD Tenant Name needs to be set
## o	Line 37: $AADTenantName -ex: contoso.onmicrosoft.com
# •	Provide the URI to download the cab file
## o	Line 49: $UpdateSAS – URI for the cab file uploaded to a storage account
# •	Provide Credentials for appsvc.local\appsvcadmin
## o	You will be prompted for this and does not need to be set now
# •	Provide cab file name
## o	Line 55: $patchname -ex: Windows10.0-KB5021654-x64.cab
# Additional Information
# •	Log file is created at c:\temp\UpdateDeployment.log
# •	AD FS is something I will work on next
# •	Only patches “Customer Infrastructure” – So controller nodes (managed by Microsoft) are not patched with this script
