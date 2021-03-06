### v2019-09-19 - added support for replicated recoveries
### usage (Cohesity 5.x): ./restore-SQL.ps1 -vip bseltzve01 -username admin -domain local -sourceServer sql2012 -sourceDB proddb -targetServer w2012a -targetDB bseltz-test-restore -overWrite -mdfFolder c:\sqldata -ldfFolder c:\sqldata\logs -ndfFolder c:\sqldata\ndf

### usage (Cohesity 6.x): ./restore-SQL.ps1 -vip bseltzve01 -username admin -domain local -sourceServer sql2012 -sourceDB cohesitydb -targetDB cohesitydb-restore -overWrite -mdfFolder c:\SQLData -ldfFolder c:\SQLData\logs -ndfFolders @{'*1.ndf'='E:\sqlrestore\ndf1'; '*2.ndf'='E:\sqlrestore\ndf2'}
###                        ./restore-SQL.ps1 -vip bseltzve01 -username admin -domain local -sourceServer sql2012 -sourceDB cohesitydb -targetDB cohesitydb-restore -overWrite -mdfFolder c:\SQLData -ldfFolder c:\SQLData\logs -logTime '2019-01-18 03:01:15'

### process commandline arguments
[CmdletBinding()]
param (
    [Parameter(Mandatory = $True)][string]$vip,          #the cluster to connect to (DNS name or IP)
    [Parameter(Mandatory = $True)][string]$username,     #username (local or AD)
    [Parameter()][string]$domain = 'local',              #local or AD domain
    [Parameter(Mandatory = $True)][string]$sourceServer, #protection source where the DB was backed up
    [Parameter(Mandatory = $True)][string]$sourceDB,     #name of the source DB we want to restore
    [Parameter()][string]$targetServer = $sourceServer,  #where to restore the DB to
    [Parameter()][string]$targetDB = $sourceDB,          #desired restore DB name
    [Parameter()][switch]$overWrite,                     #overwrite existing DB
    [Parameter()][string]$mdfFolder,                     #path to restore the mdf
    [Parameter()][string]$ldfFolder = $mdfFolder,        #path to restore the ldf
    [Parameter()][hashtable]$ndfFolders,                 #paths to restore the ndfs (requires Cohesity 6.0x)
    [Parameter()][string]$ndfFolder,                     #single path to restore ndfs (Cohesity 5.0x)
    [Parameter()][string]$logTime,                       #date time to replay logs to e.g. '2019-01-20 02:01:47'
    [Parameter()][switch]$wait,                          #wait for completion
    [Parameter()][string]$targetInstance,                #SQL instance name on the targetServer
    [Parameter()][switch]$latest,
    [Parameter()][switch]$noRecovery,
    [Parameter()][switch]$progress
)

### handle 6.0x alternate secondary data file locations
if($ndfFolders){
    if($ndfFolders -is [hashtable]){
        $secondaryFileLocation = @()
        foreach ($key in $ndfFolders.Keys){
            $secondaryFileLocation += @{'filePattern' = $key; 'targetDirectory' = $ndfFolders[$key]}
        }
    }
}else{
    $secondaryFileLocation = @()
}

### source the cohesity-api helper code
. $(Join-Path -Path $PSScriptRoot -ChildPath cohesity-api.ps1)

### authenticate
apiauth -vip $vip -username $username -domain $domain

### handle source instance name e.g. instance/dbname
if($sourceDB.Contains('/')){
    if($targetDB -eq $sourceDB){
        $targetDB = $sourceDB.Split('/')[1]
    }
    $sourceInstance, $sourceDB = $sourceDB.Split('/')
}else{
    $sourceInstance = 'MSSQLSERVER'
}

### search for database to clone
$searchresults = api get /searchvms?environment=SQL`&entityTypes=kSQL`&entityTypes=kVMware`&vmName=$sourceInstance/$sourceDB

if($targetInstance -ne '' -and $targetInstance -ne $sourceInstance){
    $differentInstance = $True
}else{
    $differentInstance = $False
}

### narrow the search results to the correct source server
$dbresults = $searchresults.vms | Where-Object {$_.vmDocument.objectAliases -eq $sourceServer } | `
                                  Where-Object { $_.vmDocument.objectId.entity.sqlEntity.databaseName -eq $sourceDB }

if($null -eq $dbresults){
    write-host "Database $sourceInstance/$sourceDB on Server $sourceServer Not Found" -foregroundcolor yellow
    exit
}

### if there are multiple results (e.g. old/new jobs?) select the one with the newest snapshot 
$latestdb = ($dbresults | sort-object -property @{Expression={$_.vmDocument.versions[0].snapshotTimestampUsecs}; Ascending = $False})[0]

if($null -eq $latestdb){
    write-host "Database $sourceInstance/$sourceDB on Server $sourceServer Not Found" -foregroundcolor yellow
    exit 1
}

### identify physical or vm
$entityType = $latestdb.registeredSource.type

### search for source server
$entities = api get /appEntities?appEnvType=3`&envType=$entityType
$ownerId = $latestdb.vmDocument.objectId.entity.sqlEntity.ownerId
$dbId = $latestdb.vmDocument.objectId.entity.id

### handle log replay
$versionNum = 0
$validLogTime = $False
$useLogTime = $False
$latestUsecs = 0
$oldestUsecs = 0

if ($logTime -or $latest){
    if($logTime){
        $logUsecs = dateToUsecs $logTime
        $logUsecsDayStart = [int64] (dateToUsecs (get-date $logTime).Date) 
        $logUsecsDayEnd = [int64] (dateToUsecs (get-date $logTime).Date.AddDays(1).AddSeconds(-1))
    }elseif($latest){
        $logUsecsDayStart = [int64]( dateToUsecs (get-date).AddDays(-3))
        $logUsecsDayEnd = [int64]( dateToUsecs (get-date))
    }
    $dbVersions = $latestdb.vmDocument.versions

    foreach ($version in $dbVersions) {
        $snapshotTimestampUsecs = $version.snapshotTimestampUsecs
        $oldestUsecs = $snapshotTimestampUsecs
        $timeRangeQuery = @{
            "endTimeUsecs"       = $logUsecsDayEnd;
            "protectionSourceId" = $dbId;
            "environment"        = "kSQL";
            "jobUids"            = @(
                @{
                    "clusterId"            = $latestdb.vmDocument.objectId.jobUid.clusterId;
                    "clusterIncarnationId" = $latestdb.vmDocument.objectId.jobUid.clusterIncarnationId;
                    "id"                   = $latestdb.vmDocument.objectId.jobUid.objectId
                }
            );
            "startTimeUsecs"     = $logUsecsDayStart
        }
        $pointsForTimeRange = api post restore/pointsForTimeRange $timeRangeQuery
        if($pointsForTimeRange.PSobject.Properties['timeRanges']){
            # log backups available
            foreach($timeRange in $pointsForTimeRange.timeRanges){
                $logStart = $timeRange.startTimeUsecs
                $logEnd = $timeRange.endTimeUsecs
                if($latestUsecs -eq 0){
                    $latestUsecs = $logEnd - 1000000
                }
                if($latest){
                    $logUsecs = $logEnd - 1000000
                }
                if(($logUsecs - 1000000) -le $snapshotTimestampUsecs -or $snapshotTimestampUsecs -ge ($logUsecs + 1000000)){
                    $validLogTime = $True
                    $useLogTime = $False
                    break
                }elseif($logStart -le $logUsecs -and $logUsecs -le $logEnd -and $logUsecs -ge ($snapshotTimestampUsecs - 1000000)) {
                    $validLogTime = $True
                    $useLogTime = $True
                    break
                }
            }
        }else{
            # no log backups available
            foreach($snapshot in $pointsForTimeRange.fullSnapshotInfo){
                if($latestUsecs -eq 0){
                    $latestUsecs = $snapshotTimestampUsecs
                }
                if($logTime){
                    if($snapshotTimestampUsecs -le ($logUsecs + 60000000)){
                        $validLogTime = $True
                        $useLogTime = $False
                        break
                    }
                }elseif ($latest) {
                    $validLogTime = $True
                    $useLogTime = $False
                    break
                }
            }
        }
        if($latestUsecs -eq 0){
            $latestUsecs = $oldestUsecs
        }
        if(! $validLogTime){
            $versionNum += 1
        }else{
            break
        }
    }
    if(! $validLogTime){
        Write-Host "log time is out of range" -ForegroundColor Yellow        
        Write-Host "Valid range is $(usecsToDate $oldestUsecs) to $(usecsToDate $latestUsecs)"
        exit(1)
    }
}

### create new clone task (RestoreAppArg Object)
$restoreTask = @{
    "name" = "dbRestore-$(dateToUsecs (get-date))";
    'action' = 'kRecoverApp';
    'restoreAppParams' = @{
        'type' = 3;
        'ownerRestoreInfo' = @{
            "ownerObject" = @{
                "jobUid" = $latestdb.vmDocument.objectId.jobUid;
                "jobId" = $latestdb.vmDocument.objectId.jobId;
                "jobInstanceId" = $latestdb.vmDocument.versions[$versionNum].instanceId.jobInstanceId;
                "startTimeUsecs" = $latestdb.vmDocument.versions[$versionNum].instanceId.jobStartTimeUsecs;
                "entity" = @{
                    "id" = $ownerId
                }
            }
            'ownerRestoreParams' = @{
                'action' = 'kRecoverVMs';
                'powerStateConfig' = @{}
            };
            'performRestore' = $false
        };
        'restoreAppObjectVec' = @(
            @{
                "appEntity" = $latestdb.vmDocument.objectId.entity;
                'restoreParams' = @{
                    'sqlRestoreParams' = @{
                        'captureTailLogs' = $false;
                        'secondaryDataFileDestinationVec' = @();
                        'alternateLocationParams' = @{};
                    };
                }
            }
        )
    }
}

if($noRecovery){
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams.withNoRecovery = $True
}

### if not restoring to original server/DB
if($targetDB -ne $sourceDB -or $targetServer -ne $sourceServer -or $differentInstance){
    if('' -eq $mdfFolder){
        write-host "-mdfFolder must be specified when restoring to a new database name or different target server" -ForegroundColor Yellow
        exit
    }
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['dataFileDestination'] = $mdfFolder;
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['logFileDestination'] = $ldfFolder;
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['secondaryDataFileDestinationVec'] = $secondaryFileLocation;
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['newDatabaseName'] = $targetDB;    
}

### overwrite warning
if($targetDB -eq $sourceDB -and $targetServer -eq $sourceServer -and $differentInstance -eq $False){
    if(! $overWrite){
        write-host "Please use the -overWrite parameter to confirm overwrite of the source database!" -ForegroundColor Yellow
        exit
    }
}

### apply log replay time
if($useLogTime -eq $True){
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['restoreTimeSecs'] = $([int64]($logUsecs/1000000))
}

### search for target server
if($targetServer -ne $sourceServer -or $targetInstance){
    $targetEntity = $entities | where-object { $_.appEntity.entity.displayName -eq $targetServer }
    if($null -eq $targetEntity){
        Write-Host "Target Server Not Found" -ForegroundColor Yellow
        exit 1
    }
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams['targetHost'] = $targetEntity.appEntity.entity;
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams['targetHostParentSource'] = @{ 'id' = $targetEntity.appEntity.entity.parentId }
    if($targetInstance){
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['instanceName'] = $targetInstance
    }else{
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['instanceName'] = 'MSSQLSERVER'
    }
}else{
    $targetServer = $sourceServer
}

### handle 5.0x secondary file location
if($ndfFolder){
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['secondaryDataFileDestination'] = $ndfFolder
}

### overWrite existing DB
if($overWrite){
    $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['dbRestoreOverwritePolicy'] = 1
}

### execute the recovery task (post /recoverApplication api call)
$response = api post /recoverApplication $restoreTask

if($targetInstance -eq ''){
    $targetInstance = $sourceInstance
}

if($response){
    "Restoring $sourceInstance/$sourceDB to $targetServer/$targetInstance as $targetDB"
}

if($wait -or $progress){
    $lastProgress = -1
    $taskId = $response.restoreTask.performRestoreTaskState.base.taskId
    $finishedStates = @('kSuccess','kFailed','kCanceled', 'kFailure')
    while($True){
        $status = (api get /restoretasks/$taskId).restoreTask.performRestoreTaskState.base.publicStatus
        if($progress){
            $progressMonitor = api get "/progressMonitors?taskPathVec=restore_sql_$($taskId)&includeFinishedTasks=true&excludeSubTasks=false"
            $percentComplete = $progressMonitor.resultGroupVec[0].taskVec[0].progress.percentFinished
            if($percentComplete -gt $lastProgress){
                "{0} percent complete" -f [math]::Round($percentComplete, 0)
                $lastProgress = $percentComplete
            }
        }
        if ($status -in $finishedStates){
            break
        }
        sleep 5
    }
    "restore ended with $status"
    if($status -eq 'kSuccess'){
        exit 0
    }else{
        exit 1
    }
}

exit 0
