﻿function New-TestRegistry {
    param(
        [Switch]
        $PassThru,

        [string]
        $Path
    )

    if ($Path -notmatch '\S') {
        $directory = New-RandomTempRegistry
    }
    else {
        if (-not (& $SafeCommands['Test-Path'] -Path $Path)) {
            # the pester registry root path HKCU:\Pester is created once
            # and then stays in place, in TestDrive we use system Temp folder,
            # but no such folder exists for registry so we create our own.
            # removing the folder after test run would be possible but we potentially
            # running into conflict with other instance of Pester that is running
            # so keeping it in place is a small price to pay for being able to run
            # parallel pester sessions easily.
            # Also don't use -Force parameter here
            # because that deletes the folder and creates a race condition see
            # https://github.com/pester/Pester/issues/1181
            $null = & $SafeCommands['New-Item'] -Path $Path
        }

        $directory = & $SafeCommands['Get-Item'] $Path
    }

    $DriveName = "TestRegistry"
    #setup the test drive
    if ( -not (& $SafeCommands['Test-Path'] "${DriveName}:\") ) {
        try {
            $null = & $SafeCommands['New-PSDrive'] -Name $DriveName -PSProvider Registry -Root $directory -Scope Global -Description "Pester test registry" -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'DriveAlreadyExists*') {
                # it can happen that Test-Path reports false even though the drive
                # exists. I don't know why but I see it in "Context Teardown fails"
                # it would be possible to use Get-PsDrive directly for the test but it
                # is about 10ms slower and we do it in every Describe and It so it would
                # quickly add up

                # so if that happens just ignore the error, the goal of this function is to
                # create the testdrive and the testdrive already exists, so all is good.
            }
            else {
                & $SafeCommands['Write-Error'] $_ -ErrorAction 'Stop'
            }
        }
    }

    if ( $PassThru ) {
        & $SafeCommands['Get-PSDrive'] -Name $DriveName
    }
}

function Get-TestRegistryPath () {
    "Microsoft.PowerShell.Core\Registry::" + (& $SafeCommands['Get-PSDrive'] -Name TestRegistry -ErrorAction Stop).Root
}

function Clear-TestRegistry {
    param(
        [String[]]
        $Exclude
    )

    # if the setup fails before we mark test registry added
    # we would be trying to teardown something that does not
    # exist and fail in Get-TestRegistryPath
    if (-not (& $SafeCommands['Test-Path'] "TestRegistry:\")) {
        return
    }

    $path = Get-TestRegistryPath

    if ($null -ne $path -and (& $SafeCommands['Test-Path'] -Path $Path)) {
        #Get-ChildItem -Exclude did not seem to work with full paths
        & $SafeCommands['Get-ChildItem'] -Recurse -Path $Path |
            & $SafeCommands['Sort-Object'] -Descending  -Property 'PSPath' |
            & $SafeCommands['Where-Object'] { $Exclude -NotContains $_.PSPath } |
            & $SafeCommands['Remove-Item'] -Force -Recurse
    }
}

function Get-TestRegistryChildItem {
    $path = Get-TestRegistryPath
    & $SafeCommands['Get-ChildItem'] -Recurse -Path $path
}

function New-RandomTempRegistry {
    do {
        $tempPath = Get-TempRegistry
        $Path = & $SafeCommands['Join-Path'] -Path $tempPath -ChildPath ([Guid]::NewGuid())
    } until (-not (& $SafeCommands['Test-Path'] -Path $Path ))

    try {
        & $SafeCommands['New-Item'] -Path $Path
    }
    catch [System.IO.IOException] {
        # when running in parallel this occasionally triggers
        # IOException: No more data is available
        # let's just retry the operation
        & $SafeCommands['New-Item'] -Path $Path
    }
}

function Remove-TestRegistry {
    $DriveName = "TestRegistry"
    $Drive = & $SafeCommands['Get-PSDrive'] -Name $DriveName -ErrorAction Ignore
    if ($null -eq $Drive) {
        # the drive does not exist, someone must have removed it instead of us,
        # most likely a test that tests pester itself, so we just hope that the
        # one who removed this removed also the contents of it correctly
        return
    }

    $path = Get-TestRegistryPath

    if ($pwd -like "$DriveName*" ) {
        #will staying in the test drive cause issues?
        #TODO: review this
        & $SafeCommands['Write-Warning'] -Message "Your current path is set to ${pwd}:. You should leave ${DriveName}:\ before leaving Describe."
    }

    if ( $Drive ) {
        $Drive | & $SafeCommands['Remove-PSDrive'] -Force #This should fail explicitly as it impacts future pester runs
    }

    if (& $SafeCommands['Test-Path'] -Path $path) {
        & $SafeCommands['Remove-Item'] -Path $path -Force -Recurse
    }

    if (& $SafeCommands['Get-Variable'] -Name $DriveName -Scope Global -ErrorAction Ignore) {
        & $SafeCommands['Remove-Variable'] -Scope Global -Name $DriveName -Force
    }
}


function Get-TestRegistryPlugin {

    # TODO: add OnStart block and put this in it

    if (& $script:SafeCommands['Test-Path'] TestRegistry:\) {
        & $SafeCommands['Remove-Item'] (& $SafeCommands['Get-PSDrive'] TestRegistry -ErrorAction Stop).Root -Force -Recurse -Confirm:$false -ErrorAction Ignore
        & $SafeCommands['Remove-PSDrive'] TestRegistry
    }
    New-PluginObject -Name "TestRegistry" -EachBlockSetupStart {
        param($Context)
        if (-not ($Context.Block.PluginData.ContainsKey('TestRegistry'))) {
            $Context.Block.PluginData.Add('TestRegistry', @{
                    TestRegistryAdded   = $false
                    TestRegistryContent = $null
                })
        }

        # TODO: Add option, but probably in a more generic way
        # if (-not $NoTestRegistry)
        # {
        if (-not (& $script:SafeCommands['Test-Path'] TestRegistry:\)) {
            New-TestRegistry
            $Context.Block.PluginData.TestRegistry.TestRegistryAdded = $true
        }
        else {
            $Context.Block.PluginData.TestRegistry.TestRegistryContent = Get-TestRegistryChildItem
        }
        # }

    } -EachBlockTearDownEnd {
        # if (-not $NoTestRegistry)
        # {
        if ($Context.Block.PluginData.TestRegistry.TestRegistryAdded) {
            Remove-TestRegistry
        }
        else {
            Clear-TestRegistry -Exclude ( $Context.Block.PluginData.TestRegistry.TestRegistryContent | & $SafeCommands['Select-Object'] -ExpandProperty PSPath)
        }
        # }
    }
}
