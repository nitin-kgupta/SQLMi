# SQLMi Backup automation
Automation to make Azure SQL Managed Instance handle adhoc requirments such as Azure SQL Managed Instance Database backup.

This Script will help to pull all the databases residing inside the managed instance and will perform Copy-only full backup which will store into Azure Storage account container. Based on the custom requirment we're moving the backup files to Destination location i.e. file share.

All the credentials are stored the Azure Keyvault both for SQL Managed Instance and Storage account SAS key.
