# Introduction

Anytone Config Builder is a script which creates channels, zones, scanlist and talkgroup CSV files that you can import into the Anytone CPS.  The goal of this software is to simplify the creating of codeplugs that are consistent and correct; hand-managed channel lists are just too easy to mess up.

This program takes in 4 files as inputs (described below), examples are provided in the input-csv directory.  The example input CSV files come directly from the PNW Digital's code plug (as of 2019-04-29) - in fact, if you run this script on those input files, you'll get a set of channels and zones that are identical to what comes in that code plug.

So, why bother?   Well, code plug files aren't transparent.  It's difficult to track the differences between different versions of them; it's difficult to audit/bug-check; it's difficult to manipulate/prune; it's difficult to add new repeaters ;etc.  Basically: code plug files kinda suck from a maintainability perspective.

The goal of this package is to bring a bit of sanity to codeplug building.

# Input files
There are 4 files that you'll need.  These are ASCII CSV files (you should be able to open these in MS Excel or similar spreadsheet program).  Here's a description of these files:

### Analog.csv
This file is a list of analog channels that you'd like in the repeater.  If you've used CHIRP, this should be fairly familiar; it's all the basic stuff that you need for analog channels:   RX/TX Frequencies, CTCSS tones, Power level, Bandwidth (for FM or NFM).  It also include a "TX Prohibit" field which is useful if you want to include things like NWS Weather channels that you want to be able to listen to, but not accidently transmit onto.

Channel Names can be up to 16 characters.  You can group your channels into different zones which helps keep them organized.  The example input file has a few such zones: VHF repeaters, UHF repeaters, simplex, etc.

> **Note:** If you enable `--multi-zone` (see Usage below), you can specify multiple zones (or scanlists) by separating them with a pipe (`|`), e.g. `"North|South"`. This will add the channel to each listed zone/scanlist.

##### Details
- **Zone** - Up to 16 characters
- **Channel Name** - Up to 16 characters
- **Bandwidth** - "25K" for FM or "12.5K" for NFM
- **Power** - "Turbo", "High", "Mid", "Low"
- **RX/TX Freq** - the frequency, in MHz
- **CTCSS Decode/Encode** - the CTCSS code, in Hz or "Off"
- **TX Prohibit** - "Off" or "On"

### Digital-Others.csv
This is a similar file to the Analog file above, but these are one-off DMR channels.  In the example file, it has the DMR Simplex channels as well as some Brandmeister digital APRS stations.

> **Note:** The `--multi-zone` feature applies to the "Zone" column as well – separate multiple zones with a pipe (`|`).

- **Zone** - Up to 16 characters
- **Channel Name** - Up to 16 characters
- **Power** - "Turbo", "High", "Mid", "Low"
- **RX/TX Freq** - the frequency, in MHz
- **Color Code** - the DMR Color Code
- **Talk Group** - the name of the talk group
- **Time Slot** - the DMR Timeslot (either 1 or 2)
- **Call Type** - either "Call Group" or "Private Call"
- **TX Permit** - the DMR TX Permit setting.  You probably want "Always" for Simplex and "Same Color Code" for everything else.


## Digital-Repeaters.csv
This is kinda where a lot of the awesome happens.  Unlike the files above, this is a matrix of repeater frequencies and the talkgroups that are supported on that talkgroup.  The first 5 columns are specific to each repeater:

- **Zone Name** - Up to 16 characters (also supports `--multi-zone` separation with `|`)
- **Comment** - This is just for your notes, it's totally ignored by the program
- **Power** - "Turbo", "High", "Mid", "Low"
- **RX/TX Freq** - the frequency, in MHz
- **Color Code** - the DMR Color Code of the repeater

The rest of the columns headers are the names of talk groups.  The value in each of those columns it the timeslot, either 1, 2 or "-" (where "-") means it's not configured on the talkgroup.

What this means for you is that adding a repeater is as simple as adding another row to this file, marking off which talkgroups are supported on which timeslot and running the script.


## Talkgroups.csv
A simple file listing talk group names (these must match what's in the DMR files above) and their talk group IDs. 

# Output
This produces 4 files as outputs that can be directly imported into the Anytone CPS:
- channels.csv
- scanlists.csv
- talkgroups.csv
- zones.csv

What you'll wind up with is the following:
   - A Zone for every zone you specified in the Analog and Digital-Others files
   - A Zone for every repeater in the Digital-Repeaters file
   - A scanlist for every every zone in the Analog and Digital-Others files
   - A scanlist for every *talkgroup* in the Digital-Repeaters file.  This means that if you're listening to a talkgroup, say "Wash 1" and hit scan, you'll scan all of the other repeaters that have "Wash 1" as a configured talk group
   - A channel for every line in the Analog and Digital-Others files
   - A channel for every repeater on each talkgroup that's configured (that matrix described above gets multiplied out).  These channels are named for the talkgroup

**Optional Settings CSV**: When you provide the four `--start-*` options (see Usage), the tool generates two extra files:
- `OptionalSettings_STUB.csv` – a minimal CSV with only the five startup columns.
- `OptionalSettings_Full.csv` – if a template is given with `--optional-settings-csv`, this file contains all columns from the template, with the startup values overridden.

These files can be imported into the CPS to set the radio’s power‑on zone and channel.

# CPS Stuff
#### Duplicate Channel Names
This creates channels with duplicate names.  Before importing these files, you need to allow the CPS software to use duplicate names by going to Tools > Mode and checking the box for "Contact name is not unique / Channel name is not unique"

#### Radio ID
This spits out a file with a Radio Id of "DMR ID".  Before you import these files, you need to go into the "Digital" tab, and in the "Radio ID List" insure that your Radio ID (your DMR ID) is set and that the name is "DMR ID".  You can change this later if you prefer something else.

#### Contact List
You're on your own for contacts.  I pulled mine in by starting with the PNWDigital code plug (which has the contacts), then importing the files created by this tool


# Web UI and command-line usage

This project now supports two ways to generate your CSV outputs:

- the original command-line tool, built around `anytone-config-builder.pl`
- a browser-based workflow in the `website/` directory for file upload and guided generation

## Web interface

The browser workflow is served from the files in `website/`:

- `website/index.html` – main landing page and upload form
- `website/config-builder.php` – PHP wrapper that invokes the script safely
- `website/json_endpoint.php` – AJAX/JSON endpoint used by the JavaScript frontend
- `website/config-builder.js` – client-side validation and guided setup flow

The web form supports the same advanced features as the script, including:

- multi-zone and multi-scanlist generation via `|` separators
- channel sorting options across zones and scanlists
- hotspot TX permit settings
- repeater nickname handling
- startup zone/channel settings and optional settings CSV templates

## Command-line usage

Run the script directly from the project root:

```bash
perl anytone-config-builder.pl \
  --analog input-csv/Analog.csv \
  --digital-others input-csv/Digital-Others.csv \
  --digital-repeaters input-csv/Digital-Repeaters.csv \
  --talkgroups input-csv/TalkGroups.csv
```

Additional options include:

```bash
  [--multi-zone]
  [--hotspot-tx-permit=(always|same-color-code)]
  [--nicknames=(off|prefix|suffix|prefix-forced|suffix-forced)]
  [--zone-channel-sort=(processed|alpha|id|freq-asc|freq-desc)]
  [--scanlist-channel-sort=(processed|alpha|id|freq-asc|freq-desc)]
  [--start-zone1=<Zone>] [--start-channel1=<Channel>]
  [--start-zone2=<Zone>] [--start-channel2=<Channel>]
  [--optional-settings-csv=<optional.csv>]
  [--json-mode]
```

The startup zone/channel pair and optional settings CSV are especially useful for setting the radio's default startup state in the CPS.

## Notes on the advanced options

The advanced options are documented in more detail in `documentation/advanced-options.md` and are also surfaced in the browser UI. In particular, the current project supports:

- multi-zone channel placement using `North|South`-style values
- optional power-on startup configuration for Receiver A and Receiver B
- optional settings templates that override generated startup values
- flexible channel ordering for both zones and scanlists

# Usage
