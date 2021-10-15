--iCX JNUC Edition
--Dave Siederer, developed 2019-2021

--Here you'll find my anonymized code used extensively and successsfully in production for thousands of devices.

--Made these values globally readable to keep more logic confined to the flipType subroutine.
global computerPrestageID, mobilePrestageID

--App identifier stored in the script (can be gathered programmatically, but static here as a precaution).
set appID to "com.shi.ds.icx.jnuc"

--Credentials are embedded in this version, but can be centrally administered using KeyMaster or the like.
set companyName to "Jamf"
set jamfServerAddress to "https://tryitout.jamfcloud.com/"
set SDKUser to "user"
set SDKPassword to "password"

--IDs for PreStage assignments, taken from Jamf Pro.
set computerPrestageID to 37
set mobilePrestageID to 42

--Device context set, using the department attribute.
set deptID to "Standard"
set deptIDBOH to "BOH"

--Some common error strings returned from the Jamf API, for logic around handling.
set errorStrings to {"INVALID_DEVICE_TYPE", "INVALID_FIELD", "DUPLICATE_FIELD", "ALREADY_SCOPED", "DEVICE_DOES_NOT_EXIST_ON_TOKEN", "OPTIMISTIC_LOCK_FAILED"}

--The modeSet flag is to remember the last mode the app was in: Computer or Mobile Device.
try
	set deviceType to (do shell script "defaults read " & appID & " modeSet")
on error
	set deviceType to "Computer"
end try

--Assembles the auth token for the Jamf Pro API.
on authCallToken(jamfServer, APIName, APIPass)
	set authCall to (do shell script "curl -X POST --header 'Content-Type: application/json' --header 'Accept: application/json' '" & jamfServer & "uapi/auth/tokens' -ksu \"" & APIName & "\":\"" & APIPass & "\" | awk {'print $3'}")
	set AppleScript's text item delimiters to ","
	set {authToken, authTime} to text items of authCall
	set AppleScript's text item delimiters to ""
	set authToken to (do shell script " echo " & authToken & " | sed -e 's/^M//g'")
	set authToken to (characters 2 through end of authToken) as string
	return authToken
end authCallToken

--flipType changes the active device type (typically due to a soft error from the Jamf side), so it'll work for the entire fleet.
on flipType(typeIn, appID)
	if typeIn is "Computer" then
		do shell script "defaults write " & appID & " modeSet \"Mobile Device\""
		set callType to "mobile-device"
		set jamfTargetPrestageID to mobilePrestageID
	else if typeIn is "Mobile Device" then
		do shell script "defaults write " & appID & " modeSet \"Computer\""
		set callType to "computer"
		set jamfTargetPrestageID to computerPrestageID
	end if
	return {callType, jamfTargetPrestageID}
end flipType


--Initial dialogs/interactive elements start here, with the serial number.
set validationFlag to 0
repeat until validationFlag is 1
	set inputAll to (display dialog "Please scan the serial number for the " & companyName & " device to be configured." default answer "" buttons {"Cancel", "OK"} default button "OK" with icon 1)
	set serialIn to text returned of inputAll
	--Basic validation and error handling for invalid length strings.
	if (count serialIn) is greater than 9 then
		if (count serialIn) is less than 16 then
			set serialIn to (do shell script "echo " & quoted form of serialIn & " | sed \"s/['\\/ ]*//g\" | tr \"[a-z]\" \"[A-Z]\"")
			if serialIn begins with "S" then
				set targetSerial to (characters 2 through end of serialIn)
				set targetSerial to serialIn as string
			else
				set targetSerial to serialIn
			end if
			set validationFlag to 1
		end if
	end if
end repeat


--Validation is assigned based on customer for asset tag and other attributes. Omitted here, but logic typically is similar to the above.
set targetAssetTag to text returned of (display dialog "Please enter or scan the asset tag." default answer "" buttons "OK" default button "OK" with icon 2)
if targetAssetTag contains "ATAG" then
	delay 0.01
else
	set targetAssetTag to "ATAG" & targetAssetTag
end if


set targetLocation to text returned of (display dialog "Please enter or scan the location code (beginning with L)." default answer "" buttons "OK" default button "OK" with icon 2)
if targetLocation does not contain "L" then
	set targetLocation to "L" & targetLocation
end if

set serialIn to targetSerial

--Final confirmation before transmission, and also the chance to add the switch the department name to this device. Other versions do have a configurable confirmationBit, but the multiple device roles in this case have it omitted.
set confirmDialog to button returned of (display dialog "Confirm " & serialIn & " for asset tag " & targetAssetTag & " and location ID " & targetLocation & "." buttons {"Confirm BOH", "Confirm", "Cancel"} default button "Confirm")

if confirmDialog contains "BOH" then
	set deptName to deptIDBOH
else
	set deptName to deptID
end if

if confirmDialog contains "Confirm" then
	
	--Retrieves authorization token from Jamf Pro API.
	set currentAuthToken to (authCallToken(jamfServerAddress, SDKUser, SDKPassword))
	
	--Sets device type for PreStage ID and correct URL in the API call.
	if deviceType is "Computer" then
		set deviceCall to "computer"
		set jamfTargetPrestageID to computerPrestageID
	else if deviceType is "Mobile Device" then
		set deviceCall to "mobile-device"
		set jamfTargetPrestageID to mobilePrestageID
	end if
	
	--versionLock value is required for the PreStage switch, gathered here.
	set versionLock to (do shell script "curl -sH \"Accept: application/json\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer " & currentAuthToken & "\" " & jamfServerAddress & "uapi/v2/" & deviceCall & "-prestages/" & jamfTargetPrestageID & "/scope -X GET | grep versionLock | awk {'print $3'}")
	
	--Assembling the JSON payload for the PreStage switch payload below.
	set prestageJSON to ("{\"serialNumbers\": [\"" & serialIn & "\"], \"versionLock\": " & versionLock & "}")
	
	--Attempts a set of the serial number to the target PreStage. (Thank you for changing this API call so we don't have to 
	set targetResponseCode to (do shell script "curl -sH \"Accept: application/json\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer " & currentAuthToken & "\" " & jamfServerAddress & "uapi/v2/" & deviceCall & "-prestages/" & jamfTargetPrestageID & "/scope -X POST -d '" & prestageJSON & "'")
	
	
	--In the event we're scanning an iPad and we'd scanned a Mac before that, targetResponseFlag is activated…
	if targetResponseCode contains "INVALID_DEVICE_TYPE" then
		set targetResponseFlag to 1
	else if targetResponseCode contains "DEVICE_DOES_NOT_EXIST_ON_TOKEN" then
		set targetResponseFlag to 1
	else
		set targetResponseFlag to 0
	end if
	
	--…and flips the device type, then silently reattempts the assignment.
	if targetResponseFlag is 1 then
		set {deviceCall, jamfTargetPrestageID} to flipType(deviceType, appID)
		set versionLock to (do shell script "curl -sH \"Accept: application/json\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer " & currentAuthToken & "\" " & jamfServerAddress & "uapi/v2/" & deviceCall & "-prestages/" & jamfTargetPrestageID & "/scope -X GET | grep versionLock | awk {'print $3'}")
		set prestageJSON to ("{\"serialNumbers\": [\"" & serialIn & "\"], \"versionLock\": " & versionLock & "}")
		set targetResponseCode to (do shell script "curl -sH \"Accept: application/json\" -H \"Content-Type: application/json\" -H \"Authorization: Bearer " & currentAuthToken & "\" " & jamfServerAddress & "uapi/v2/" & deviceCall & "-prestages/" & jamfTargetPrestageID & "/scope -X POST -d '" & prestageJSON & "'")
	end if
	--Assembling a custom device name, using the variables gathered.
	set deviceName to targetLocation & "-DEMO-" & ((characters 7 through end of targetAssetTag) as string)
	
	--Assembles the JSON payload as a whole for the Inventory Preload.
	set preloadJSON to ("{\"serialNumber\": \"" & targetSerial & "\",\"deviceType\": \"" & deviceType & "\",\"fullName\": \"" & deviceName & "\",\"department\": \"" & deptName & "\",\"assetTag\": \"" & targetAssetTag & "\", \"building\":\"" & targetLocation & "\"}")
	
	set preloadReturn to (do shell script "curl -X POST " & jamfServerAddress & "uapi/v2/inventory-preload/records -H 'accept: application/json' -H 'Content-Type: application/json' -H 'Authorization: Bearer " & currentAuthToken & "'  -d '" & preloadJSON & "'")
	
	set preloadReturn to ""
	
	if preloadReturn contains "DUPLICATE_FIELD" then
		set preloadRecordID to (do shell script "curl -X GET '" & jamfServerAddress & "uapi/v2/inventory-preload/records?page-size=100&sort=id%3Adesc' -H 'accept: application/json' -H 'Content-Type: application/json' -H 'Authorization: Bearer " & currentAuthToken & "' | grep -B 1 " & targetSerial & " | awk {'print $3'} | head -n 1 | sed \"s/['/\\\",\\ ]*//g\"")
		
		set preloadReturn to (do shell script "curl -X PUT " & jamfServerAddress & "uapi/v2/inventory-preload/records/" & preloadRecordID & " -H 'accept: application/json' -H 'Content-Type: application/json' -H 'Authorization: Bearer " & currentAuthToken & "'  -d '" & preloadJSON & "'")
	end if
	
	
	--Error handling and routines begin here. Using known error strings to deliver more plain-language errors to the technicians, and give them an option to send anything unusual.
	set errorFlag to 0
	if preloadReturn contains "ERROR" then
		set errorFlag to 1
		set errorReport to 0
	end if
	if targetResponseCode contains "ERROR" then
		set errorFlag to 1
		set errorReport to 0
	end if
	
	--Built in logic for additional error strings, though somewhat underutilized in this particular version.
	if errorFlag is 0 then
		display notification serialIn & " was added to " & companyName & "'s primary PreStage and is ready for configuration."
	else
		repeat with errorField from 1 to (count errorStrings)
			if preloadReturn contains (item errorField of errorStrings) then
				if preloadReturn contains "DUPLICATE_FIELD" then
					display dialog "Alert: " & serialIn & " already has an inventory preload record, but has been successfully added to the PreStage."
				else
					display dialog "Error on inventory preload: " & item errorField of errorStrings
				end if
				set errorReport to 1
			end if
			
			if targetResponseCode contains (item errorField of errorStrings) then
				display dialog "Error on PreStage assignment: " & item errorField of errorStrings
				set errorReport to 1
			end if
		end repeat
		if errorReport is 0 then
			set errorButton to (display dialog "Error on communication: Unknown error" buttons {"Copy output to clipboard", "OK"} default button "Copy output to clipboard")
			if (button returned of errorButton) is not "OK" then
				set the clipboard to preloadReturn & return & targetResponseCode
			end if
		end if
	end if
end if
