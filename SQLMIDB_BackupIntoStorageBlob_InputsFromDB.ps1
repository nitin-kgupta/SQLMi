param ($smtpPassword = '*******')

Import-Module AzureRM

Function ExecuteSqlQuery ($Query, $Server) { 
    Try
    {
        $Datatable = New-Object System.Data.DataTable 
        $conn = New-Object System.Data.SqlClient.SqlConnection("Data Source="+$($server)+";Integrated Security=SSPI;Initial Catalog=master")
        $conn.Open()
    
        $Command = New-Object System.Data.SQLClient.SQLCommand 
        $Command.Connection = $conn 
        $Command.CommandText = $Query

        $DataAdapter = new-object System.Data.SqlClient.SqlDataAdapter $Command 
        $Dataset = new-object System.Data.Dataset 
        $DataAdapter.Fill($Dataset) 
        $conn.Close() 
    }
    catch
    {
        write-host  "SQL Exception: Connection Failure on $($Server)."
        write-host  "Details: $($Error[0].Exception.Message)."
        $conn.Close()
        $flag=1
    }

    return $Dataset.Tables[0] 
}
Function Move-BackupCopy ($SourceBackup, $Destination, $StorageAccount, $keyVaultName) {
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

$subscriptions = ExecuteSqlQuery -Query 'Select distinct Subscription from demo..sqlmibackupproperties' -Server 'myserver.contosa.microsoft.com'
$BackupProperties = ExecuteSqlQuery -Query "select * from demo..sqlmibackupproperties where subscription = '$($_)'" -Server 'MININT-K2V8LMS.fareast.corp.microsoft.com'

$subscriptions.subscription | ForEach-Object `
{
    $context = Set-AzureRmContext -Name "$($_)" -Tenant '72f988bf-86f1-41af-91ab-2d7cd011db47' -Force 
    Write-Verbose -Message "Connected subscription $($context.Subscription.Name) [$($context.Name)]." -Verbose

    $BackupProperties = ExecuteSqlQuery -Query "select * from demo..sqlmibackupproperties where subscription = '$($_)'" -Server 'MININT-K2V8LMS.fareast.corp.microsoft.com'

    $StorageKey   =  (Get-AzureKeyVaultSecret -VaultName $BackupProperties.keyVaultName -Name 'StorageKey').SecretValueText
    $SQLMiCred    =  (Get-AzureKeyVaultSecret -VaultName $BackupProperties.keyVaultName -Name 'SQLMiCred').SecretValueText
    $Databases    =  Get-AzureRmSqlInstanceDatabase -InstanceName $BackupProperties.InstanceName -ResourceGroupName $BackupProperties.ResourceGroup |select Name

    $Pass = $smtpPassword | ConvertTo-SecureString -AsPlainText -Force; 
    $Cred = [System.Management.Automation.PSCredential]::new($BackupProperties.smtpAccount, $Pass)

    foreach ($DB in $Databases.Name)
    {
        Write-Verbose -Message "$($_) - Initiating the Backup operation - $(Get-Date)" -Verbose
        $BackupDBName = $DB + "-Backup-$((Get-Date -format "yyyyMMdd-hhmmss.bak"))"

        $Query = "
        BACKUP DATABASE [$($DB)] TO  URL = N'https://$($BackupProperties.StorageAccount).blob.core.windows.net/$($BackupProperties.BlobContainer)/$($BackupDBName)' 
        WITH  BLOCKSIZE = 65536,  MAXTRANSFERSIZE = 4194304,  COPY_ONLY, NOFORMAT, NOINIT,  NAME = N'$($DB)-Full Database Backup', NOSKIP, 
        NOREWIND, NOUNLOAD,  STATS = 10
        GO"

        Try
        {
            #Taking Copy-Only backup into Storage Blob Container
            $Status = SQLCMD -S $BackupProperties.SQLMIInstanceNameFQDN -U superadmin -P $SQLMiCred -Q $Query
            If (($status | Select-String "successfully") -and ($Status | Select-String "100 percent" ))
            {
                Write-Host "Database [$($DB)] Backup Completed Successfully"
                $Body = "$($_) : Copy-Only Baclup completed for Server [$($BackupProperties.InstanceName)] to URL = N'https://$($BackupProperties.StorageAccount).blob.core.windows.net/$($BackupProperties.BlobContainer)/$($BackupDBName)'"             
                
                Write-Host "Moving [$($_)] Backup files to $($BackupProperties.destination)."
                $Status = Move-BackupCopy -SourceBackup $BackupDBName -Destination $BackupProperties.destination -StorageAccount $BackupProperties.StorageAccount -keyVaultName $BackupProperties.keyVaultName
                if($status -eq $true)
                {
                    $Body += "<BR> $($BackupDBName) file successfully moved to $($BackupProperties.Destination)"
                }
                else
                {
                    $Body += "<BR> $($BackupDBName) file Failed to moved to $($BackupProperties.Destination)."                
                }
            }
            else
            {
                $Body = "$($_) : Copy-Only Backup failed to completed for Server [$($BackupProperties.InstanceName)] to URL = N'https://$($BackupProperties.StorageAccount).blob.core.windows.net/$($BackupProperties.BlobContainer)/$($BackupDBName)'"

            }
        
            $subject = "$BackupProperties.subject - $(Get-date)"
            Send-MailMessage -To "$($BackupProperties.smtpaccount)" -From "alertmon@microsoft.com" -SmtpServer "smtp.office365.com" -Port "587" -Body $Body -BodyAsHtml -Subject $subject -Credential $Cred -UseSsl
            Write-Verbose -Message "$($DB) - Completed the Backup operation - $(Get-Date)" -Verbose
        }
        catch
        {
            Write-Verbose -Message "Error : $Error[0].Exception.Message" -Verbose
        }

    } 
}

