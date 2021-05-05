# Convert Unified Audit Log to comma delimited file

# Purpose
#  This script parses an XML or CSV version of the Unified Audit Log.  It converts that file to a Comma delimited file
# that preserves all the data originally produced by the search-unifiedauditlog cmdlet.  The file also contains one 
# column for every field found in the JSONs.
#
#
# Functionality
#  UALToCSVExpander.ps1 -inputfilename Your_UAL_XML/CSV_file.[XML|CSV] -exportfilename Your_UAL_XML_file.csv [-thorough]
#  Creates two files.  TempConversionScript and Your_UAL_XML_file.csv.  Both in the current folder
#  It is recommended script and files being converted be in the same folder
#
#  The -thorough switch, if included, force all rows in the source file to be explored as part of field discovery.  This is
# very slow on large source files.
#
#
# Algorithm With -thorough switch.
#  Loads source file into RAM
#  Expands the JSON in every row.  Isolates the field names and adds them to an array.  As it does this it notes fields that 
#  cannot be stored in a simple string such as system.object fields.
#  Discards all field names that are duplicated.  It is left with a unique field list from the source file.
#  Once all field names are located script loads AuditConvertTemplate.ps1 and inserts lines for dealing with each field name.
#  Saves the result to TempConversionScript.ps1 and executes it.
#  TempConversionScript.ps1 executes to carry out the actual conversion.
#
#  PLEASE NOTE:  Thorough mode can take hours when presented with many rows.  Longest test was about 10 hours for a few
#                hundred thousand rows.  Leaving out the Thorough switch converts the file in a small fraction of the time.
#

# Algorithm Without -thorough switch.
#  Loads source file into RAM
#  Lists all unique operations in the UAL.  Converts the first occurrence of each operation to a list of fields.
# If that conversion fails it cycles through other copies of the same operation.  As soon as one copy of the operation works
# or it runs out of instances of the operation it moves on to the next one.
#  Sorts the list and discards duplicate names.  Looks for fields that cannot be stored in a simple string
# such as system.object fields.
#  Once all field names are located script loads AuditConvertTemplate.ps1 and inserts lines for dealing with each field name.
#  Saves the result to TempConversionScript.ps1 and executes it.
#  TempConversionScript.ps1 executes to carry out the actual conversion.
#
#
#  Additional notes
#  Script is provided as is without warranty or support.  Use at your own risk.  
#  Since one script writes the other, and runs it, I don't think signing is possible.  Therefore I doubt it will work in 
# environments that require script signing.
#
#  Script was written with PowerShell 5 on Windows 10 and has not been tested on older versions of PowerShell
#  If the script finds a system.object property in the XML it goes back to the original text of the JSON and copies it
# into the field.  It does not try to assess the properties inside the system.object and break them out into separate
# columns in the file CSV file.
#
#  Without Thorough mode It is assumed all operations of the same name will have the same field list.
#
#  Written by:  Chris Pollitt
#  Created 2019-02-10
#  Last Modified 2021-05-04


Param(
        [Parameter(Mandatory = $true)]
        [string]$InputFileName,           # source file.  Recommend files be in same folder as the script.
        [Parameter(Mandatory = $true)]
        [string]$ExportFileName,          # file final conversion will be written to.
        [switch]$Thorough                 # Controls whether ALL records are explored to create the field list, or just the first record of each type.
    )


# Constants
$All_good = $true
$Nope = $false
$MiddleEndString = "],"
$EndofAuditEndString = "]}"


# Starting variable Definitions
$record_number = 0
$PropsList=@()            # Contains the names of all properties 
$ObjectPropertyList=@()   # Contains the names of all properties that are classified as system.object[] type.
$NonObjList = @()


$ext = $InputFilename.substring(($InputFilename.length - 4))  #get the file extension

switch( $ext )
{
  ".xml" {
    write-host "Importing XML file" $InputFilename
    $SelectLine = "$"+"audit = import-clixml """+$InputFilename+""" | select CreationDate, Identity, Operations, RecordType, ResultCount, ResultIndex, UserIds,Auditdata,JSONConversionFailure"
    $AuditLogData = import-clixml $InputFilename
    break 	
  }
  ".csv" {
    write-host "Importing CSV file" $InputFilename
    $SelectLine = "$"+"audit = import-csv """+$InputFilename+""" | select CreationDate, Identity, Operations, RecordType, ResultCount, ResultIndex, UserIds,Auditdata,JSONConversionFailure"
    $AuditLogData = import-csv $InputFilename 
 break 	
  }
  default {
    write-host $InputFilename " does not end with .csv, or .xml"
    exit
  }
 }

if ($Thorough) {  #initiate the process of examining every line to get the full field list

  foreach( $a in $AuditLogData) {  # Loop through the audit log
    $JSON_Converted = $All_good         # Reset error status to default 

    $record_number++                    #used for deciding whether to add another . onscreen
    if(($record_number % 100) -eq 0) {  #Every 100 rows put a . on screen
      write-host "." -nonewline
	  if($record_number % 5000 -eq 0) {       #After 50 . on the same line trigger a new line 
	    write-host "!"
      } # Endif check for 5000th record 
    } # Edif check for 100th record 
  
    try { $adata = $a.auditdata | convertfrom-json }             # Some JSONs in the Audit data are truncated and cause conversion failures.  
    catch {                                                      # Catch failures and signal subsequent code that a failure took place.
      write-host "Cannot convert row $record_number from JSON"   # Tell the user about the failure on screen.
      $JSON_Converted = $Nope
    }

    if( $JSON_Converted ) {
      $property_list = $adata | get-member | ?{$_.membertype -like "*property"} # Get full data on properties in the current converted JSON 

      #for finding unique names we just need the one property from get-member 
      $props = $property_list | select name  
      $PropsList += $props.name  # Add the current names to the overalll list of names 

      $ObjectPropertyList += ($property_list | ?{$_.definition -like "*system.object*"}).name
      $NonObjList += ($property_list | ?{$_.definition -notlike "*system.object*"}).name
   

    }  #EndIF $JSON_Converted=true
  } # NEXT $a 

}  # EndIF User selected the Thorough option

else { # User DID NOT select the Thorough option.  Initiate the faster process of just assessing the first operation of each type
  
  write-host "Listing unique operations.  Beginning discovery of fields in those operations."

  $operations = $AuditLogData.operations | sort-object -unique

  foreach( $op in $operations ) {  # Loop through the unique operations found in the audit log

    write-host "Listing all fields for $op"

    #attempt to find all instances of the same operation we might be able to convert.  If we can convert any instance of the operation
    #then reverse the failure status.  This process will slow the script down if there are many instances of an operation that cannot be converted.

    [array]$single_op_list = @()
    [array]$single_op_list += $AuditLogData | ?{$_.operations -eq $op}
    $single_op_list_index = 0

    DO 
    {
      $JSON_Converted = $All_good                              # Reset error status to default 
      try { $adata = $single_op_list[$single_op_list_index].auditdata | convertfrom-json }             
	                                                           # Some JSONs in the Audit data are truncated and cause conversion failures.  

      catch {                                                  # Catch failures and signal subsequent code that a failure took place.
        write-host "Cannot get fields of operation $op at Resultindex " $single_op_list[$single_op_list_index].ResultIndex        
		                                                       # Tell the user about the failure on screen.  

        $JSON_Converted = $Nope                                # Set Error state 
      }
      $single_op_list_index++
    } until (($single_op_list_index -ge $single_op_list.count) -or ($JSON_Converted -eq $All_good))
 
    $single_op_list=$Null
    [gc]::collect()   #clean up what we just deallocated.  Hopefully doesn't slow script too much
	 
	
    if( $JSON_Converted ) {
      write-host "Success"
	  
      $property_list = $adata | get-member | ?{$_.membertype -like "*property"} # Get full data on properties in the current converted JSON 

      #for finding unique names we just need the one property from get-member 
      $props = $property_list | select name  
      $PropsList += $props.name  # Add the current names to the overalll list of names 

     $ObjectPropertyList += ($property_list | ?{$_.definition -like "*system.object*"}).name
     $NonObjList += ($property_list | ?{$_.definition -notlike "*system.object*"}).name
   

    }  #EndIF $JSON_Converted=true
  } # NEXT $a 

}

 
$PropsList = $PropsList | sort-object -unique  # NOTE that if the JSON has duplicates for legitimate reasons (hope it never does) 
                                               # this line will suppress them.
$PropsList > props.txt  # Output the list of properties from the JSON for interest/debugging

$ObjectPropertyList = $ObjectPropertyList | sort-object | get-unique
$ObjectPropertyList > objects.txt
$NonObjList = $NonObjList | sort-object | get-unique
$NonObjList > NonObjects.txt

$AssignmentLines=@()

foreach($p in $PropsList) {
  switch( $p) {  # Fields within $p are checked for duplicates and dups eliminated. Need this to distinguish JSON fields from 
                 # default Unified Audit Log fields.
    "RunspaceId" {$p = "JSON"+$p}
    "RecordType" {$p = "JSON"+$p}
    "CreationDate" {$p = "JSON"+$p}
    "UserIds" {$p = "JSON"+$p}
    "Operations" {$p = "JSON"+$p}
    "AuditData" {$p = "JSON"+$p}
    "ResultIndex" {$p = "JSON"+$p}
    "ResultCount" {$p = "JSON"+$p}
    "Identity" {$p = "JSON"+$p}
    "IsValid" {$p = "JSON"+$p}
    "ObjectState" {$p = "JSON"+$p}
	
  }
  $SelectLine += ", "+$p 

  if($ObjectPropertyList -contains $p){
  # IF $p is listed in $ObjectPropertyList it was previously found to be of type System.Object[] and that needs to be handled differently.
  #   A system.object cannot be assigned to a string directly.
  #   This branch goes back to the original JSON to pull out the text of the System.Object and save it in the CSV
  #   Since there are several possibilities for the content of the system.object this was deemed the safest approach.
  
    $AssignmentLines += "    #   Object Start"
    $AssignmentLines += "    $"+"startstr = """+$p+""""":["""                                                      # Create the string to find in $startstr 
    $AssignmentLines += "    $"+"start = $"+"a.auditdata.indexof($"+"startstr)"                                    # Find it 
    $AssignmentLines += "    if($"+"start -gt 0) {"                                                                # If it is found
    $AssignmentLines += "      $"+"finish = $"+"a.auditdata.indexof(""$MiddleEndString"", ($"+"start + 1))"        #   Find the other end of the array property 
    $AssignmentLines += "      if($"+"finish -lt $"+"start) {"        #   Find the other end of the array property 
    $AssignmentLines += "        $"+"finish = $"+"a.auditdata.indexof(""$EndofAuditEndString"", ($"+"start + 1))"        #   Find the other end of the array property 
    $AssignmentLines += "      }"        #   Find the other end of the array property 

    $AssignmentLines += "      $"+"a."+$p+" = $"+"a.auditdata.substring($"+"start, ($"+"finish - $"+"start + 1))"  #   Assign it to the new field 	
    $AssignmentLines += "    }"                                                                                    # } Steps if it is found 
#    $AssignmentLines += "    else {"                                                                               # else {
#    $AssignmentLines += "      $"+"a."+$p+" = ""Cannot convert $p"""                                               #    Return Error
#    $AssignmentLines += "    }"                                                                                    # } endif 
	$AssignmentLines += "    #   Object End"
   
  }
  else {
    $AssignmentLines += "    $"+"a."+$p+" = $"+"adata."+$p
  }  # Endif for whether the property is an array 
} # NEXT $p 

write-host "Field discovery complete.  Starting actual conversion.  One dot per 100 items.  5000 per row."

$SecondScript = get-content AuditConvertTemplate.ps1
$SecondScript[20] = $SelectLine

$FinalScript=@()
$FinalScript += $SecondScript[0..45]
$FinalScript += $AssignmentLines
$FinalScript += $SecondScript[46..54]

$FinalScript > TempConversionScript.ps1
#.\TempConversionScript.ps1 $InputFilename, $ExportFilename
.\TempConversionScript.ps1 $ExportFilename