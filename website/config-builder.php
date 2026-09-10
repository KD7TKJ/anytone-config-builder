<?php
error_reporting( E_ALL );
ini_set('display_errors', 1);

if(!isset($_FILES["analog"])) {
    header("Location: ./");
    exit(0);
}


print_html_start();

$sort_order = validateSortOrder($_POST["sort"]);
$nickname_mode = validateNicknameMode($_POST["nicknames"]);
$hotspot_tx_permit = validateHotSpotTXPermit($_POST["hotspot"]);

// Read and validate the new options
$multi_zone = isset($_POST["multi_zone"]) && $_POST["multi_zone"] == "1";
$zone_channel_sort = validateChannelSortMode($_POST["zone_channel_sort"]);
$scanlist_channel_sort = validateChannelSortMode($_POST["scanlist_channel_sort"]);

// Startup options
$start_zone1 = $_POST["start_zone1"] ?? "";
$start_zone2 = $_POST["start_zone2"] ?? "";
$start_channel1 = $_POST["start_channel1"] ?? "";
$start_channel2 = $_POST["start_channel2"] ?? "";

// Validate required files
$analog  = fileValidation("Analog",            $_FILES["analog"]);
$dmr_oth = fileValidation("Digital-Others",    $_FILES["digitalothers"]);
$dmr_rep = fileValidation("Digital-Repeaters", $_FILES["digitalrepeaters"]);
$talkgrp = fileValidation("TalkGroups",        $_FILES["talkgroups"]);

// Optional Settings (if provided)
$optional_settings = "";
if (isset($_FILES["optional_settings"]) && $_FILES["optional_settings"]["size"] > 0) {
    $optional_settings = fileValidation("Optional Settings", $_FILES["optional_settings"]);
}

$outdir = tempdir("dmr-output-");
$script = __DIR__ . '/../anytone-config-builder.pl';
$config = __DIR__ . '/../config';

// Build the command with all options
$cmd = escapeshellarg($script) . " --analog-csv='" . escapeshellarg($analog) . "' "
     . "--digital-others-csv='" . escapeshellarg($dmr_oth) . "' --digital-repeaters-csv='" . escapeshellarg($dmr_rep) . "' --talkgroups-csv='" . escapeshellarg($talkgrp) . "' "
     . "--output-directory='" . escapeshellarg($outdir) . "' --sorting=$sort_order --hotspot-tx-permit=$hotspot_tx_permit "
     . "--nicknames=$nickname_mode --config='" . escapeshellarg($config) . "'";

// Add multi-zone flag if enabled
if ($multi_zone) {
    $cmd .= " --multi-zone";
}

// Add zone channel sort if not default
if ($zone_channel_sort != "processed") {
    $cmd .= " --zone-channel-sort=$zone_channel_sort";
}

// Add scanlist channel sort if not default
if ($scanlist_channel_sort != "processed") {
    $cmd .= " --scanlist-channel-sort=$scanlist_channel_sort";
}

// Add Optional Settings template if provided
if (!empty($optional_settings)) {
    $cmd .= " --optional-settings-csv='$optional_settings'";
}

// Add startup options if all four are provided
$start_provided = !empty($start_zone1) && !empty($start_zone2) && !empty($start_channel1) && !empty($start_channel2);
if ($start_provided) {
    $cmd .= " --start-zone1=" . escapeshellarg($start_zone1);
    $cmd .= " --start-zone2=" . escapeshellarg($start_zone2);
    $cmd .= " --start-channel1=" . escapeshellarg($start_channel1);
    $cmd .= " --start-channel2=" . escapeshellarg($start_channel2);
} elseif (!empty($start_zone1) || !empty($start_zone2) || !empty($start_channel1) || !empty($start_channel2)) {
    // Some but not all provided
    print_html_div("WARNING", "#FFFFBB", 
        "All four startup options are required together. They have been ignored.");
}

exec($cmd . " 2>&1", 
     $output, $return);


foreach($output as $line)
{
    if (preg_match('/^WARNING: (.*)/', $line, $matches))
    {
        print_html_div("WARNING", "#FFFFBB", $matches[1]);
    }
    elseif (preg_match('/^ERROR: (.*)/', $line, $matches))
    {
        print_html_div("ERROR", "#FFDDDD", $matches[1]);
    }
    elseif (preg_match('/^INFO: (.*)/', $line, $matches))
    {
        print_html_div("INFO", "#CCDDFF", $matches[1]);
    }
}


if ($return == 0)
{
    print_html_div("SUCCESS", "#DDFFDD", "It worked!  Your files should be downloading now.");
    print "<iframe style='display:none;' src='download.php?name=$outdir'></iframe>";
}


function fileValidation($description, $file_details)
{
    $file_type = $file_details["type"];
    $tmp_name  = $file_details["tmp_name"];
    $size      = $file_details["size"];

    if ($size == 0)
    {
        fatal("$description file is empty... did you forget to upload it?");
    }
    if ($size > (1024*1024))
    {
        fatal("$description file is > 1MB.  That's bigger than I'm cool with :D");
    }

    return $tmp_name;
}

function tempdir($prefix='') {
    $tempfile=tempnam(sys_get_temp_dir(), $prefix);
    // you might want to reconsider this line when using this snippet.
    // it "could" clash with an existing directory and this line will
    // try to delete the existing one. Handle with caution.
    if (file_exists($tempfile)) { unlink($tempfile); }
    mkdir($tempfile);
    if (is_dir($tempfile)) { return $tempfile; }
}


function validateSortOrder($sort_order)
{
    if ($sort_order == "alpha" ||
        $sort_order == "repeaters-first" || 
        $sort_order == "analog-first" )
    {
        return $sort_order;
    }
    else
    {
        return 'alpha';
    }
}

function validateHotSpotTXPermit($hotspot)
{
    if ($hotspot == "always" || $hotspot == "same-color-code")
    {
        return $hotspot;
    }
    else
    {
        return "same-color-code";
    }
}

function validateNicknameMode($nickname)
{
    if ($nickname == "prefix" || $nickname == "suffix" || $nickname == "prefix-forced" || $nickname == "suffix-forced")
    {
        return $nickname;
    }
    else
    {
        return "off";
    }
}

// Validation function for channel sort modes
function validateChannelSortMode($mode)
{
    $valid_modes = array("processed", "alpha", "id", "freq-asc", "freq-desc");
    if (in_array($mode, $valid_modes))
    {
        return $mode;
    }
    else
    {
        return "processed";  // default
    }
}

function fatal($message)
{
    print_html_div("ERROR", "#FFDDDD", $message);
    print_html_end();
}


function print_html_start()
{
?>
<html>
<head>
<title>Anytone Config Builder</title>
  <link rel="stylesheet" href="pandoc.css" type="text/css" />
</head>
<body>

<h1>K7ABD's Anytone Config Builder</h1>

<?php
}

function print_html_div($description, $color, $message)
{
    print "$description:<div style='background-color:$color; border: 1px solid #888888; padding: 5px; margin-top: 0px; margin-bottom: 5px;'>$message</div>";
}

function print_html_end()
{
    print "</body></html>";
    exit(0);
}
?>
