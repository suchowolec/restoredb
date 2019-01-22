<#
	.SYNOPSIS
		Restoring the database on the SQL Server.
	.DESCRIPTION
        Restoring the database on the SQL server.
	.PARAMETER backup
        The name of the database backup file.
	.PARAMETER serverInstance
        SQL Server instance.
	.PARAMETER backupDir
		The directory of the backup files.        
	.PARAMETER databaseName
        The name of the target database.
    .PARAMETER dryRun
        Specifies whether to run the script in dry mode.
    .EXAMPLE
        PS C:\>.\RestoreDb.ps1 -backup XYZ.bak # enter a random name to display all available backup files
        PS C:\>.\RestoreDb.ps1 -backup Hub_20181010.bak
        PS C:\>.\RestoreDb.ps1 -backup Hub_20181025.bak -serverInstance '.\SQLEXPRESS' -backupDir 'C:\Dev\Database\Backups\Hub'
#>
[CmdletBinding()]
Param(
    [parameter(Mandatory = $True, Position = 1, HelpMessage="The name of the database backup file")]
    [string] $backup,
    [parameter(HelpMessage="SQL Server instance")]
    [string] $serverInstance = "waw-cds-ui-db2017",
    [parameter(HelpMessage="The directory of the backup files")]
    [string] $backupDir,    
    [parameter(HelpMessage="The name of the target database")]
    [string] $databaseName = "Hub_$env:USERNAME",
    [parameter(HelpMessage="Specifies whether to run the script in dry mode")]
    [switch] $dryRun
)

# Generate horizontal rule
$psHost = Get-Host
$psWindow = $psHost.UI.RawUI
$width = $psWindow.WindowSize.Width
$newline = "`r`n"
$hr = "$newline$("-" * ($width - 1))"

# Getting information about the SqlServer module.
$sqlServerModule = Get-InstalledModule -Name SqlServer
if (-not $sqlServerModule) {
    Write-Warning "SqlServer module not found! To install the SqlServer module, please run the following command:"
    Write-Host "Install-Module -Name SqlServer -AllowClobber" -ForegroundColor Blue
    exit 1
}

try {
    $serverTime = Invoke-Sqlcmd -ServerInstance $serverInstance -Query "SELECT GETDATE() AS TimeOfQuery" -ErrorAction Stop
    Write-Host "Connected to '$serverInstance': $($serverTime.TimeOfQuery.ToString("hh\:mm\:ss"))" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

try {
    # Getting information about the backup configuration of the SqlServer.
    $sqlServerSetupQuery =
        "DECLARE @dataDir NVARCHAR(4000), @backupDir NVARCHAR(4000)" + $newline +
        "EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\Setup', N'SQLDataRoot', @dataDir output;" + $newline +
        "EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @backupDir output;" + $newline +
        "SELECT @datadir + N'\DATA' AS [DataDir], @backupdir AS [BackupDir]"

    Write-Verbose "Backup configuration of the SqlServer: $hr$sqlServerSetupQuery$hr"

    $sqlServerSetup = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $sqlServerSetupQuery

    $log = "Result" + $hr + 
        "DataDir: " + $sqlServerSetup.DataDir + $newline +
        "BackupDir: " + $sqlServerSetup.BackupDir + $hr
    Write-Verbose $log

    if (-not $backupDir) {
        $backupDir = $sqlServerSetup.BackupDir;
    } else {
        Write-Verbose "Using custom backup directory: '$backupDir'"
    }
    
    $dataDir = $sqlServerSetup.DataDir;
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

if (-not $dryRun) {
    # Getting information about existing connections to the database
    $existingConnectionsQuery = 
        "SELECT Count(*) AS [Count] FROM master.dbo.sysprocesses WHERE dbid = DB_ID('$databaseName')"
    
    Write-Verbose "Existing database connections: $hr$existingConnectionsQuery$hr"

    $existingConnections = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $existingConnectionsQuery

    Write-Host "Existing database connections: $($existingConnections.Count)" -ForegroundColor Green

    $killConnectionsQuery =
        "DECLARE @dbname NVARCHAR(128), @processid INT`r`n" +
        "SET @dbname = '$databaseName'`r`n" +
        "SELECT @processid = MIN(spid) FROM master.dbo.sysprocesses WHERE dbid = DB_ID(@dbname)" + $newline +
        "WHILE @processid IS NOT NULL`r`n" +
        "BEGIN`r`n" +
        "    EXEC('KILL ' + @processid)`r`n" +
        "    SELECT  @processid = MIN(spid) FROM master.dbo.sysprocesses WHERE dbid = DB_ID(@dbname)" + $newline +
        "END"

    Write-Verbose "Kill existing database connections: $hr$killConnectionsQuery$hr"

    Invoke-Sqlcmd -ServerInstance $serverInstance -Query $killConnectionsQuery

    Write-Host "Restoring database '$databaseName' on '$serverInstance'" -ForegroundColor Green

    try {
        $backupPath = (Join-Path -Path $backupDir -ChildPath $backup)

        # Getting information about logical files of the database backup.
        $backupFilesQuery =
            "DECLARE @logicalFiles TABLE (`r`n" +
            "    [LogicalName] NVARCHAR(1000), [PhysicalName] NVARCHAR(1000), [Type] NVARCHAR, [FileGroupName] NVARCHAR(1000),`r`n" +
            "    [Size] NVARCHAR(1000), [MaxSize] NVARCHAR(1000), [FileId] NVARCHAR(1000), [CreateLSN] NVARCHAR(1000),`r`n" +
            "    [DropLSN] NVARCHAR(1000), [UniqueId] NVARCHAR(1000), [ReadOnlyLSN] NVARCHAR(1000), [ReadWriteLSN] NVARCHAR(1000),`r`n" +
            "    [BackupSizeInBytes] NVARCHAR(1000), [SourceBlockSize] NVARCHAR(1000), [FileGroupId] NVARCHAR(1000), [LogGroupGUID] NVARCHAR(1000),`r`n" +
            "    [DifferentialBaseLSN] NVARCHAR(1000), [DifferentialBaseGUID] NVARCHAR(1000), [IsReadOnly] NVARCHAR(1000),`r`n" +
            "    [IsPresent] NVARCHAR(1000), [TDEThumbprint] NVARCHAR(1000), [SnapshotUrl] NVARCHAR(1000)`r`n" +
            ")`r`n" +
            "DECLARE @dataFileName NVARCHAR(1000), @dataFilePath NVARCHAR(1000), @logFileName NVARCHAR(1000), @logFilePath NVARCHAR(1000)`r`n" +
            "INSERT INTO @logicalFiles`r`n" +
            "EXEC('RESTORE FILELISTONLY FROM DISK=''$backupPath''')`r`n" +
            "SELECT @dataFileName=[LogicalName], @dataFilePath=[PhysicalName] FROM @logicalFiles WHERE [Type]=N'D'`r`n" +
            "SELECT @logFileName=[LogicalName], @logFilePath=[PhysicalName] FROM @logicalFiles WHERE [Type]=N'L'`r`n" +
            "SELECT @dataFileName AS [DataFileName], @dataFilePath AS [DataFilePath], @logFileName AS [LogFileName], @logFilePath AS [LogFilePath]"

        Write-Verbose "Logical files of the database backup: $hr$backupFilesQuery$hr"

        $backupFileConfig = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $backupFilesQuery -ErrorAction Stop

        $log = "Result" + $hr +
            "DataFileName: " + $backupFileConfig.DataFileName + "`r`n" +
            "DataFilePath: " + $backupFileConfig.DataFilePath + "`r`n" +
            "LogFileName: " + $backupFileConfig.LogFileName + "`r`n" +
            "LogFilePath: " + $backupFileConfig.LogFilePath + $hr
        Write-Verbose $log

		# Getting information about logical files of the database instance.
        $destinationDatabaseSetupQuery =
            "DECLARE @databaseName NVARCHAR(4000) = N'$databaseName', @dataFileName NVARCHAR(4000), @dataFilePath NVARCHAR(4000), @logFileName NVARCHAR(4000), @logFilePath NVARCHAR(4000)`r`n" +
            "SELECT @dataFileName = [name], @dataFilePath = [physical_name] FROM sys.master_files WHERE [type] = 0 AND [database_id] = DB_ID(@databaseName)`r`n" +
            "SELECT @logFileName = [name], @logFilePath = [physical_name] FROM sys.master_files WHERE [type] = 1 AND [database_id] = DB_ID(@databaseName)`r`n" +
            "SELECT`r`n" +
            "    @databaseName AS [DatabaseName],`r`n" +
            "    @dataFileName AS [DataFileName],`r`n" +
            "    @logFileName AS [LogFileName],`r`n" +
            "    @dataFilePath AS [DataFilePath],`r`n" +
            "    @logFilePath AS [LogFilePath]`r`n" +
            "WHERE @dataFileName IS NOT NULL"

        Write-Verbose "Logical files of the database instance: $hr$destinationDatabaseSetupQuery$hr"

        $destinationDatabaseSetup = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $destinationDatabaseSetupQuery -ErrorAction Stop

		# If the target database instance does not exist, set the default values.
        if (-not $destinationDatabaseSetup) {
            $destinationDatabaseSetup = @{DataFilePath=(Join-Path -Path $dataDir -ChildPath "$($databaseName).mdf");LogFilePath = (Join-Path -Path $dataDir -ChildPath "$($databaseName)_log.ldf")}
        }

        $restoreDatabaseQuery =
            "RESTORE DATABASE [$databaseName] FROM DISK = '$backupPath'`r`n" +
            "WITH`r`n" +
            "MOVE '" + $backupFileConfig.DataFileName + "' TO '" + $destinationDatabaseSetup.DataFilePath + "',`r`n" +
            "MOVE '" + $backupFileConfig.LogFileName + "' TO '" + $destinationDatabaseSetup.LogFilePath + "',`r`n" +
            "REPLACE"

        Write-Verbose "Restore database: $hr$restoreDatabaseQuery$hr"

        Invoke-Sqlcmd -ServerInstance $serverInstance -Query $restoreDatabaseQuery -ErrorAction Stop

        Write-Host "Database: '$databaseName' restored on '$serverInstance'" -ForegroundColor Green

        # Getting information about product version.
        $productInfoQuery = 
            "SELECT TOP (1) [ProductVersion] AS [Version]`r`n" +
            "FROM [dbo].[__MigrationHistory]`r`n" +
            "ORDER BY [ProductVersion]"

        Write-Verbose "Product version: $hr$productInfoQuery$hr"

        $productInfo = Invoke-Sqlcmd -ServerInstance $serverInstance -Database "$databaseName" -Query $productInfoQuery

        # Getting information database size and servicve version.
        $serverInfoQuery = 
            "SELECT`r`n" + 
            "   CAST(SUM(size) * 8. / 1024 AS DECIMAL(8,2)) AS [Size],`r`n" + 
            "   @@SERVICENAME AS [ServiceName],`r`n" +
            "   CAST(@@CONNECTIONS AS VARCHAR(10)) + ' / ' + CAST(@@MAX_CONNECTIONS AS VARCHAR(10)) AS [Connections]`r`n" +
            "FROM sys.master_files WITH(NOWAIT) WHERE [database_id] = DB_ID() GROUP BY [database_id]"

        Write-Verbose "Database size and servicve version: $hr$serverInfoQuery$hr"

        $serverInfo = Invoke-Sqlcmd -ServerInstance $serverInstance -Database "$databaseName" -Query $serverInfoQuery

        $log = "Result" + $hr +
            "ProductVersion: " + $productInfo.Version + "`r`n" + 
            "Size: " + $serverInfo.Size + "`r`n" +
            "ServiceName: " + $serverInfo.ServiceName + "`r`n" +
            "Connections: " + $serverInfo.Connections + $hr
        Write-Verbose $log

        Write-Host "Database version: $($productInfo.Version), size: $($serverInfo.Size)MB, connections: ($($serverInfo.Connections))" -ForegroundColor Blue
    }
    catch {
        Write-Warning $_.Exception.Message
        $availableBackupsQuery =
            "DECLARE @backups AS TABLE([Name] NVARCHAR(4000), [Depth] INT, [File] INT)`r`n" +
            "INSERT INTO @backups`r`n" +
            "EXECUTE xp_dirtree '$backupDir',1,1`r`n" +
            "SELECT [Name] AS [Available backup files] FROM @backups WHERE [file] = 1 AND [Name] LIKE '%.bak' ORDER BY [Name] DESC"
        
        Write-Verbose "Database size and servicve version: $hr$availableBackupsQuery$hr"

        $availableBackups = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $availableBackupsQuery
        $availableBackups | Format-Table "Available backup files"
    }
}