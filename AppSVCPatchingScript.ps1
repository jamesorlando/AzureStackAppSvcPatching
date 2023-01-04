<#
.SYNOPSIS
    App Service Patching Script - Based on QuickStart GitHub Template deployment with default values
    QuickStart Template Location: https://github.com/Azure/AzureStack-QuickStart-Templates/tree/master/appservice-fileserver-sqlserver-ha
.NOTES
    Author: James Orlando
    Contact: James.Orlando@microsoft.com
    Date Create: 12/7/2022

#>

Function Set-Failover ($ServerName,$mode){
    $global:sqlcommand = "ALTER AVAILABILITY GROUP [alwayson-ag] MODIFY REPLICA ON '$($ServerName)' WITH(FAILOVER_MODE = $($mode));"
    
    $log = "Failover command was created: " + $global:sqlcommand
    
    Write-Log -log $log
    }
    
    Function Write-Log ($log){
        $log + " " + (Get-Date) | Out-File "C:\temp\UpdateDeployment.log" -Append
        if((Get-Item "C:\temp\UpdateDeployment.log").length -gt "5mb")
            {
            Remove-Item "C:\temp\UpdateDeployment.lo_"
            Rename-Item "C:\temp\UpdateDeployment.log" -NewName "UpdateDeployment.lo_" 
            }
    }
    Write-log -log "App Service Script Started"
    #region Connect to ASH Admin 
    # Register an Azure Resource Manager environment that targets your Azure Stack Hub instance. Get your Azure Resource Manager endpoint value from your service provider.
        Add-AzEnvironment -Name "AzureStackAdmin" -ArmEndpoint "https://adminmanagement.local.azurestack.external" `
          -AzureKeyVaultDnsSuffix adminvault.local.azurestack.external `
          -AzureKeyVaultServiceEndpointResourceId https://adminvault.local.azurestack.external
    
        # Set your tenant name.
        $AuthEndpoint = (Get-AzEnvironment -Name "AzureStackAdmin").ActiveDirectoryAuthority.TrimEnd('/')
        $AADTenantName = "jpolab.onmicrosoft.com"
        $TenantId = (invoke-restmethod "$($AuthEndpoint)/$($AADTenantName)/.well-known/openid-configuration").issuer.TrimEnd('/').Split('/')[-1]
    
        # After signing in to your environment, Azure Stack Hub cmdlets
        # can be easily targeted at your Azure Stack Hub instance.
        Connect-AzAccount -EnvironmentName "AzureStackAdmin" -TenantId $TenantId
        $log = Get-AzContext
        $log = "Connected to $($log.name) with account $($log.Account). Environment: $($log.Environment) TenantID: $($log.TenantId)"
        Write-Log -log $log
    #endregion 
    
    #Must be in cab format for dism command to work
    $UpdateSAS = "https://patching.blob.local.azurestack.external/updates/Windows10.0-KB5021654-x64.cab?sp=racwd&st=2022-12-07T17:53:02Z&se=2023-01-06T01:53:02Z&spr=https&sv=2019-02-02&sr=b&sig=SZpMNRT5w2bXVM4q%2F4S7Q14xGeYxfopgqwieCzalT2M%3D"
    Write-Log -log ("URI Provided: " + $($UpdateSAS))
    
    #####Variables
    $Creds = Get-Credential -Message "appsvc.local\appsvcadmin credentials" -UserName "appsvc.local\appsvcadmin"
    Write-Log -log "Credentials Provided for appsvc.local\appsvcadmin"
    $patchname = "Windows10.0-KB5021654-x64.cab"
    Write-Log -log ("Patch Name Provided: " + $($patchname))
    $KB = $patchname.Split('-')[1]
    if($KB -notlike "KB*"){
    Write-Log -log "KB Number not identified. Prompting User"
    $KB = Read-Host -Prompt "KB Number not extracted. Provide the KB number begining with KB..."
    }
    Write-Log -log ("KB Number: " + $($KB))
    $sqlpatch = $false
    
    #build dns alias fqdn
    $AzEnv = Get-AzEnvironment -Name AzureStackAdmin
    $dnsfqdn = ($AzEnv.ResourceManagerUrl).Split('.')
    $dnsfqdn = "." + $dnsfqdn[1] + ".cloudapp." + $dnsfqdn[2] + "." + $dnsfqdn[3]
    Write-Log -log ("Public IP DNS Alias FQDN is: " + $($dnsfqdn))
    
    #Server Core Machine Variable (Script Aassumes two SQL Servers named aps-sql-0 & aps-sql-1)
    $ServerCoreMachines = "aps-ad-0","aps-ad-1","aps-s2d-0","aps-s2d-1"
    Write-Log -log ("Server Core Machine List: " + $($ServerCoreMachines) + " *This script assumes two SQL Servers named aps-sql-0 & aps-sql-1")
    
    #Begin SQL Only Section
    Write-Log -log "Begining SQL Server Patching Section"
    
    $Session = New-PSSession -ComputerName ("aps-sql-0" + $dnsfqdn) -Credential $Creds
    Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
    $Primary = (Invoke-Command -Session $Session -ScriptBlock { Get-ClusterGroup -Name alwayson-ag }).OwnerNode
    if($primary -eq 'aps-sql-0'){$Secondary = "aps-sql-1"}
    else{$Secondary = "aps-sql-0"}
    Write-Log -log ("Primary Availability Group Server identified as: " + $($Primary) + " & Secondary identified as: " + $($Secondary))
    
    #Patch Sql secondary first
    Write-Log -log "Begining patching of secondary sql server"
    
    $Session = New-PSSession -ComputerName ($Secondary + $dnsfqdn) -Credential $Creds
    Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
    #Current Patch State
    $Hotfix = Invoke-Command -Session $session -ScriptBlock {
    Get-HotFix
    }
    Write-Log -log "Current Installed Hotfix information:"
    Write-Log -log ($Hotfix | Select HotfixID,InstalledOn,PSComputerName)
    
    #Patch if KB not found installed
    if($kb -notin $Hotfix.HotfixID){
        Write-Log -log "KB Not Installed. Begining install procedure. "
        Set-Failover -ServerName $Secondary -mode "Manual"
        Write-Log -log "Setting Failover to Manual"
        Invoke-Command -Session $Session -ScriptBlock { Invoke-Sqlcmd -Query $using:sqlcommand }
        
        Invoke-Command -Session $Session -ScriptBlock {
            $TLS12Protocol = [System.Net.SecurityProtocolType] 'Ssl3 , Tls12'
            [System.Net.ServicePointManager]::SecurityProtocol = $TLS12Protocol
        
            $path = Test-Path 'c:\patching'
            if($path -eq $false){ new-item -ItemType Directory -Path c:\patching }
    
            Invoke-RestMethod -uri $using:UpdateSAS -OutFile "c:\Patching\$($using:patchname)" 
            dism /Online /Add-Package /PackagePath:"c:\Patching\$($using:patchname)" /norestart
            restart-computer -force
            }
        
        Write-Log -log "Update Installed. Sleeping 90 Seconds for reboot."
        
        start-sleep -Seconds 90
    
        $Session = New-PSSession -ComputerName ($Secondary + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
        Write-Log -log "Monitoring SQL for secondary to come online and healthy"
    
        Invoke-Command -Session $session -ScriptBlock {
        $upyet = @"
    select replica_id, role_desc, connected_state, connected_state_desc, synchronization_health_desc 
    from sys.dm_hadr_availability_replica_states
"@
    
            do
            {
                start-sleep -Seconds 60
                $Health = Invoke-Sqlcmd -Query $upyet | ? {$_.role_desc -eq "SECONDARY"}
                write-host "Waiting for database to come online.State is $($health).connected_state_desc and health is $($health).synchronization_health_desc"
            }
            until ($health.connected_state_desc -eq "CONNECTED" -and $health.synchronization_health_desc -eq "HEALTHY" )
        }
    Write-Log -log "Dabase back online and healthy"
    Write-Log -log "Removing Patch from C:\Patching"
    Invoke-Command -Session $session -ScriptBlock {Remove-Item "c:\Patching\$($using:patchname)" -Force}
    $sqlpatch = $true
    
    }
    else{Write-Log -log "$($KB) already installed. Skipping."}
    
    #Swith to Patching Primary SQL Server
    Write-Log -log "Begining updates for Primary SQL Server"
    $Session = New-PSSession -ComputerName ($Primary + $dnsfqdn) -Credential $Creds
    Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
    $Hotfix = Invoke-Command -Session $session -ScriptBlock {
    Get-HotFix
    }
    Write-Log -log "Current Installed Hotfix information:"
    Write-Log -log ($Hotfix | Select HotfixID,InstalledOn,PSComputerName)
    
    if($kb -notin $Hotfix.HotfixID){
    
        Set-Failover -ServerName $Primary -mode 'Manual'
    
        Write-Log -log "Setting failover to manual"
        Invoke-Command -Session $session -ScriptBlock { Invoke-Sqlcmd -Query $using:sqlcommand}
        
        Write-Log -log "Moving to secondary node"
        Invoke-Command -Session $session -ScriptBlock {Move-ClusterGroup 'alwayson-ag' -Node $using:secondary}
    
        Invoke-Command -Session $Session -ScriptBlock {
            $TLS12Protocol = [System.Net.SecurityProtocolType] 'Ssl3 , Tls12'
            [System.Net.ServicePointManager]::SecurityProtocol = $TLS12Protocol
        
            $path = Test-Path 'c:\patching'
            if($path -eq $false){ new-item -ItemType Directory -Path c:\patching }
    
            Invoke-RestMethod -uri $using:UpdateSAS -OutFile "c:\Patching\$($using:patchname)" 
            dism /Online /Add-Package /PackagePath:"c:\Patching\$($using:patchname)" /norestart
            restart-computer -force
            }
        Write-Log -log "Update Installed. Sleeping 90 Seconds for reboot."
        
        start-sleep -Seconds 90
    
        $Session = New-PSSession -ComputerName ($Primary + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
        Write-Log -log "Monitoring SQL for secondary (Former Primary) to come online and healthy"
        
        Invoke-Command -Session $session -ScriptBlock {
        $upyet = @"
    select replica_id, role_desc, connected_state, connected_state_desc, synchronization_health_desc 
    from sys.dm_hadr_availability_replica_states
    "@
    
            do
            {
                start-sleep -Seconds 60
                $Health = Invoke-Sqlcmd -Query $upyet | ? {$_.role_desc -eq "SECONDARY"}
                write-host "Waiting for database to come online.State is $($health).connected_state_desc and health is $($health).synchronization_health_desc"
            }
            until ($health.connected_state_desc -eq "CONNECTED" -and $health.synchronization_health_desc -eq "HEALTHY" )
    
        #Move Primary Back to this SQL Server
        Move-ClusterGroup 'alwayson-ag' -Node $using:primary
        }
    Write-Log -log "Dabase back online and healthy"
    Write-Log -log "Removing Patch from C:\Patching"
    Invoke-Command -Session $session -ScriptBlock {Remove-Item "c:\Patching\$($using:patchname)" -Force}
    $sqlpatch = $true
    }
    Else{Write-Log -log "$($KB) already installed. Skipping."}
    
    #Set failover back to automatic - if needed
    if($sqlpatch -eq $true){
        Write-Log -log "Setting failover back to automatic on seconday"
        Set-Failover -ServerName $Secondary -mode 'Automatic'
        $Session = New-PSSession -ComputerName ($Secondary + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
        Invoke-Command -Session $session -ScriptBlock { Invoke-Sqlcmd -Query $using:sqlcommand}
    
        Write-Log -log "Setting failover back to automatic on primary"
        Set-Failover -ServerName $Primary -mode 'Automatic'
    
        $Session = New-PSSession -ComputerName ($Primary + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
        Invoke-Command -Session $session -ScriptBlock { Invoke-Sqlcmd -Query $using:sqlcommand}
        }
    
    #################Server Core OS Patching##########
    Write-Log -log "Begining to patch Server Core OS machines"
    ForEach($ServerCoreMachine in $ServerCoreMachines){
        $Session = New-PSSession -ComputerName ($ServerCoreMachine + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
        $Hotfix = Invoke-Command -Session $session -ScriptBlock {
        Get-HotFix
        }
        Write-Log -log "Current Installed Hotfix information:"
        Write-Log -log ($Hotfix | Select HotfixID,InstalledOn,PSComputerName)
    
        if($kb -notin $Hotfix.HotfixID){
        Write-Log -log ("Begining patching for " + $($serverCoreMachine))
        Invoke-Command -Session $session -ScriptBlock {
        
        $TLS12Protocol = [System.Net.SecurityProtocolType] 'Ssl3 , Tls12'
        [System.Net.ServicePointManager]::SecurityProtocol = $TLS12Protocol
        
        $path = Test-Path 'c:\patching'
        if($path -eq $false){ new-item -ItemType Directory -Path c:\patching }
        
        invoke-RestMethod -uri $using:UpdateSAS -OutFile "c:\Patching\$($using:patchname)" 
        #dism /Online /Add-Package /PackagePath:"c:\Patching\$($using:patchname)" /norestart
        #restart-computer -force
        }
    
        Write-Log -log "Update Installed. Sleeping 90 Seconds for reboot."
        
        start-sleep -Seconds 90
    
        $Session = New-PSSession -ComputerName ($ServerCoreMachine + $dnsfqdn) -Credential $Creds
        Write-Log -log ("Session created for: " + $($session.ComputerName) + " State: " + $($Session.State))
    
        Write-Log -log "Monitoring NetLogon Service for reboot complete"
        
        Invoke-Command -Session $session -ScriptBlock {
    
            do
            {
                start-sleep -Seconds 60
            }
            until ((Get-Service -Name Netlogon).Status -eq "Running")
        }
        Write-Log -log "Service up"
        Write-Log -log "Removing Patch from C:\Patching"
        Invoke-Command -Session $session -ScriptBlock {Remove-Item "c:\Patching\$($using:patchname)" -Force}
        Write-Log -log ("Patching completed for: " + $($ServerCoreMachine))
        }
        Else{Write-Log -log "$($KB) already installed. Skipping."}
    }
    Write-Log -log "End patching script."
