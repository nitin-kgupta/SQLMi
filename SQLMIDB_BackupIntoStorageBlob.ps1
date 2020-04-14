
#Read Storage sharedaccess key from AKV
#Read all the databases from SQL MI
#copy-only sql mi db backup into azure blob container as landing zone
#later moved bck files to azure storage account file share.
#notification needs to send once back completed


Param (
    [string]$InstanceName  = 'sqlmidemo12',
    [string]$ResourceGroup = 'NetworkWatcherRG',
    [string]$keyVaultName  = 'StoredCred',
    [string]$Subscription  = '4a4d72d0-3bef-4af1-aafa-691a15ace26c',
    [string]$StorageAccount= 'sampledataload',
    [string]$BlobContainer = 'employeedata',
    [String]$FileShareName = 'backupdump',
    [string]$Subject       = "SQL Managed Instance Backup Report - $(Get-Date)",
    [string]$smtpAccount   = "nitinkg@microsoft.com",
    [string]$smtpPassword  = "**********************",  # Update with actual password or store into AKV
    [string]$Destination   = "\\MININT-K2V8LMS\Users\nitinkg\Desktop"
 )

#Getting credentials from keyVault
Set-AzureRmContext -Subscription $Subscription
$StorageKey   =  (Get-AzureKeyVaultSecret -VaultName $keyVaultName -Name 'StorageKey').SecretValueText
$SQLMiCred    =  (Get-AzureKeyVaultSecret -VaultName $keyVaultName -Name 'SQLMiCred').SecretValueText
$Databases    =  Get-AzureRmSqlInstanceDatabase -InstanceName $InstanceName -ResourceGroupName $ResourceGroup |select Name

$Pass = $smtpPassword | ConvertTo-SecureString -AsPlainText -Force; 
$Cred = [System.Management.Automation.PSCredential]::new($smtpAccount, $Pass)

#Function for moving the backup files from Storage account Blob to mentioned destination
Function Move-BackupCopy ($SourceBackup, $Destination, $StorageAccount, $keyVaultName)
{
    $flag = $false

    Try
    {
        $StorageAccKey = (Get-AzureKeyVaultSecret -VaultName $keyVaultName -Name 'StorageAccKey').SecretValueText
        $Context = New-AzureStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageAccKey
        $Status = $c = Get-AzureStorageBlobContent -Container employeedata -Destination $Destination  -Blob $SourceBackup -Context $Context    
        if ($Status.Name -eq $SourceBackup)
        {
            Write-Host "$($SourceBackup) successfully moved to $($Destination))"
            $flag = $true
        }
        else
        {
            Write-Verbose -Message  "$($SourceBackup) failed to move to $($Destination))" -Verbose
            Write-Host "Error : $($Error[0].Exception.Message)"
            $flag = $false
        }
    }
    catch
    {
        Write-Host "Error : $($Error[0].Exception.Message)"
        $flag = $false
    }
return $flag
}


#Pulling Databased from SQL Managed Instance
$Databases.Name | ForEach-Object {
    
    Write-Verbose -Message "$($_) - Initiating the Backup operation - $(Get-Date)" -Verbose
    $BackupDBName = $_ + "-Backup-$((Get-Date -format "yyyyMMdd-hhmmss.bak"))"
    
    $Query = "
    BACKUP DATABASE [$($_)] TO  URL = N'https://$($StorageAccount).blob.core.windows.net/$($BlobContainer)/$($BackupDBName)' 
    WITH  BLOCKSIZE = 65536,  MAXTRANSFERSIZE = 4194304,  COPY_ONLY, NOFORMAT, NOINIT,  NAME = N'$($_)-Full Database Backup', NOSKIP, 
    NOREWIND, NOUNLOAD,  STATS = 10
    GO"

    Try
    {
        #Taking Copy-Only backup into Storage Blob Container
        $Status = SQLCMD -S tcp:sqlmidemo12.public.ec8d90149606.database.windows.net,3342 -U superadmin -P $SQLMiCred -Q $Query
        If (($status | Select-String "successfully") -and ($Status | Select-String "100 percent" ))
        {
                Write-Host "Database [$($_)] Backup Completed Successfully"
                $Body = "$($_) : Copy-Only Baclup completed for Server [$($InstanceName)] to URL = N'https://$($StorageAccount).blob.core.windows.net/employeedata/$($BackupDBName)'"             
                
                Write-Host "Moving [$($_)] Backup files to $($destination)."
                $Status = Move-BackupCopy -SourceBackup $BackupDBName -Destination $destination -StorageAccount $StorageAccount -keyVaultName $keyVaultName
                if($status -eq $true)
                {
                    $Body += "<BR> $($BackupDBName) file successfully moved to $($Destination)"
                }
                else
                {
                    $Body += "<BR> $($BackupDBName) file Failed to moved to $($Destination)."                
                }
        }
        else
        {
            $Body = "$($_) : Copy-Only Backup failed to completed for Server [$($InstanceName)] to URL = N'https://$($StorageAccount).blob.core.windows.net/employeedata/$($BackupDBName)'"

        }

        Send-MailMessage -To "nitinkg@microsoft.com" -From "alertmon@microsoft.com" -SmtpServer "smtp.office365.com" -Port "587" -Body $Body -BodyAsHtml -Subject $subject -Credential $Cred -UseSsl
        Write-Verbose -Message "$($_) - Completed the Backup operation - $(Get-Date)" -Verbose
    }
    catch
    {
       Write-Verbose -Message "Error : $Error[0].Exception.Message" -Verbose
    }

}

