# Script Purpose
# Convert JSON in data returned by Search-unifiedauditlog to a CSV format.  Only the top level JSON is converted.  If there is an embedded one
# for extended properties it is not converted.

# Base Script Creation date 2018/12/15
# Base Script Last Updated 2019/03/07
# Author Chris Pollitt
#    Script modified on every execution.
# Use at your own risk.
 

# Constants
$All_good = $true
$Nope = $false

# Starting variable Definitions
$final=@()
$record_number = 0

# Import the XML file that contains the audit data
$audit = import-clixml $args[0] | select CreationDate, Identity, Operations, RecordType, ResultCount, ResultIndex, UserIds,Auditdata,JSONConversionFailure
# The line above is modified during each execution.

foreach($a in $audit) {
  $record_number++
  $Converted = $All_good
  if(($record_number % 100) -eq 0) {  #Every 100 rows put a . on screen
    write-host "." -nonewline
	if($record_number % 5000 -eq 0) {       #After 50 . on the same line trigger a new line 
	  write-host "!"
	} # Endif check for 5000th record 
  } # Edif check for 100th record 
  
  try { $adata = $a.auditdata | convertfrom-json }
  catch {
    write-host "Cannot convert row $record_number from JSON"
	[string]$ConvertError = $error[0].exception
	$a.JSONConversionFailure = $ConvertError.substring(0,100)  #Copy first 100 chars of the error message. Don't needit all since it includes the failed json.
	$Converted = $Nope
  }

  if( $Converted ) {
  # with a successfully converted JSON we need to fill in all the fields.  The rows below are all filled in with every execution of the script.
  # lines with no applicable property will error out and we need to have them silently continue.
  
	
  } # END IF 
  
}

#$filename = $args[0].substring(0, $args[0].indexof(".xml"))+".csv"
$filename = $args[0]
$audit | export-csv $filename -notypeinformation
