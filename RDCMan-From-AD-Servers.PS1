# Create an RDG (XML formatted) file for RDCMan to import so that all workstations are in relevant groups.

# Add (via AppendChild method) a single Server object to a Group object
function Add-ServerToGroup($group, $serverName, $serverDescription) {
   $serverElement = $serverTemplateElement.clone()
   $serverElement.properties.name = $serverName
   $serverElement.properties.displayName = $serverDescription

   [void]$group.AppendChild($serverElement)
}

# Return the requested Group object.  If a Group object by the defined name does not already exist,
# a new Group object will be created.

# A Group object matching the defined name will still be returned, even if the other properties do not match
# the arguments passed to this function.
function Get-Group($element, $groupName, $userName, $password, $domain){
   $group = $Template.RDCMan.file.group | Where-Object { $_.properties.name -eq $groupName} | Select-Object -First 1
   if ($group -eq $null){
      $group = $groupTemplateElement.Clone()
      $group.properties.name = $groupName
      $group.logonCredentials.userName = $userName
      #$group.logonCredentials.password = $password
      $group.logonCredentials.domain = $domain

      $group.RemoveChild($group.server)
      $element.AppendChild($group) | out-null
   }
   return $group
}

# Convert the provided SecureString password to encrypted text usable by the RDCMan executable.
function Get-SecurePassword ([string]$RDCManFile,[string]$password) {
   if (-not(test-path "$($env:temp)\RDCMan.dll")) {
      copy-item "$RDCManFile" "$($env:temp)\RDCMan.dll"
   }
   Import-Module "$($env:temp)\RDCMan.dll"
   $EncryptionSettings = New-Object -TypeName RdcMan.EncryptionSettings
   [RdcMan.Encryption]::EncryptString($password, $EncryptionSettings)
}

function Get-RDCManFile {
   [CmdletBinding()]
   Param(
      [Parameter(Mandatory=$True,
         Position=1)]
      [PSObject[]]$Computers
   )
   begin {
      # Store the location of the Remote Desktop Connection Manager file
      $RDCMan = "C:\rdc\RDCMan.exe"

      # Store the XML template into a variable for more sensible parsing / operating
      [xml]$Template = Get-Content -Path .\rdc-template.rdc

      # Root XML element that objects will append to
      $fileElement = $template.RDCMan.file
      # Group template, for cloning
      $groupTemplateElement = $fileElement.group
      # Server template, for cloning
      $serverTemplateElement = $groupTemplateElement.server
      # Name your root element in the RDCMan connection window. Everybody needs a Name!
      $fileElement.properties.name = 'Servers'

	  # Currently all these groups are set to use the current domain (useful for a jumpbox)
      $hostGroup = Get-Group $fileElement 'Hosts' $env:USERNAME 'empty-password' $env:USERDOMAIN
      $otherGroup = Get-Group $fileElement 'App / Other Servers' $env:USERNAME 'empty-password' $env:USERDOMAIN
      $dcGroup = Get-Group $fileElement 'Domain Controllers' $env:USERNAME 'empty-password' $env:USERDOMAIN
      $witnessGroup = Get-Group $fileElement 'Cluster Witnesses' $env:USERNAME 'empty-password' $env:USERDOMAIN
      $rdgGroup = Get-Group $fileElement 'RD Gateway Servers' $env:USERNAME 'empty-password' $env:USERDOMAIN
      $oobGroup = Get-Group $fileElement 'Out of Band' 'administrator' '' 'ycl-br1-oob1' # empty creds
   }

   process {
      $computers | Where-Object {$_.group -match "Hosts"} | Foreach-Object {Add-ServerToGroup $hostGroup "$($_.name)" "$($_.description)"}
      $computers | Where-Object {$_.group -match "App / Other Servers"} | Foreach-Object {Add-ServerToGroup $otherGroup "$($_.name)" "$($_.description)"}
      $computers | Where-Object {$_.group -match "Domain Controllers"} | Foreach-Object {Add-ServerToGroup $dcGroup "$($_.name)" "$($_.description)"}
      $computers | Where-Object {$_.group -match "Cluster Witnesses"} | Foreach-Object {Add-ServerToGroup $witnessGroup "$($_.name)" "$($_.description)"}
      $computers | Where-Object {$_.group -match "RD Gateway Servers"} | Foreach-Object {Add-ServerToGroup $rdgGroup "$($_.name)" "$($_.description)"}
      $computers | Where-Object {$_.group -match "Out of Band"} | Foreach-Object {Add-ServerToGroup $oobGroup "$($_.name)" "$($_.description)"}
   }

   end {
      # Remove the Group template object, as it is just a blank stub at this point.
      [void]$fileElement.RemoveChild($groupTemplateElement)

      # Create a temporary file to hold the XML
      # This is our RDG file for launching RDCMan, although it is not required that it be provided a .RDG extension
      $TempFile = New-TemporaryFile
      $Template.save($TempFile)

      # Launch RDCMan.exe using our temporary RDG file
     & $RDCMan $TempFile
   }

}

# Collect the SecureString password from the user:
# Not using this as it could be run on untrusted environments
$credentialHash = @{}
#$credentialHash['ExampleUser1'] = Read-Host "What is the password for ExampleUser1?" -AsSecureString
#$credentialHash[$env:username] = Read-Host "What is the password for $($env:username)?" -AsSecureString


# Get all servers from AD
$servers = Get-ADComputer -Filter {OperatingSystem -like "*windows*server*"} -Properties * | sort Name

$ServerList = @()

foreach ($server in $servers) {

    # Ignore certain servers (clusters, and disabled computer accounts in AD)
    if ($server.Description -like "Failover cluster virtual network name account" -or -not $server.Enabled) {
        continue;
    }

    # Group Servers by their hostnames
    if ($server.Name -like "*-HV*") {
        $servergroup = 'Hosts'
    } elseif ($server.Name -like "*-DC*") {
        $servergroup = 'Domain Controllers'
    } elseif ($server.Name -like "*-WI*") {
        $servergroup = 'Cluster Witnesses'
    } elseif ($server.Name -like "*RDG*") {
        $servergroup = 'RD Gateway Servers'
    } else {
        $servergroup = 'App / Other Servers'
    }

    # Empty Desciption
    if ($server.Description -like "") {
        $server.Description = '[No Description in AD]'
    }

    $ServerList += @{"Name"=$server.Name; "Description"=$server.Name + " - " + $server.Description; "OS" = $server.OperatingSystem; "Group"=$servergroup}
}


# Add any extras
$ServerList += @{
    "Name"="Server1"; 
    "Description"="Server1 - Example"; 
    "OS" = "Windows Server 2019"; 
    "Group"="Out of Band"
	}


Get-RDCManFile $ServerList